# vibeee, top-level build.
#
# Produces build/vibeee.img: a raw, dd-able SD-card image.
#
# Toolchain: zig, nasm, qemu (for `make qemu`). Nothing else, no cross-GCC, no
# autotools, no root privileges, no loopback mounts. See design/00-vibeee.md §14.

ZIG      ?= zig
# Extra flags for `zig build`, e.g. ZIG_FLAGS=-Dsymbols=eeewm to keep one
# program's symbol table for matching a fault address reported on the target.
ZIG_FLAGS ?=
NASM     ?= nasm

# Target architecture, x86 by default. `arm` selects the ARM926 HAL, the
# second-architecture proof of design/12-arm-port.md. It boots the kernel
# directly in QEMU; the SD image pipeline below is x86-only today.
ARCH     ?= x86
ifeq ($(filter $(ARCH),x86 arm),)
$(error ARCH must be "x86" or "arm", not "$(ARCH)")
endif

# What goes into the image: the processor, the services, the programs, the
# manual, the sizes and the boot line. Set in .config by `make menuconfig` or
# `make <preset>_defconfig`; without a .config the image is the default, the Eee
# PC 701 with everything but the extra applications. CONFIG names another file.
#
# The configuration tool turns it into build/config.mk, the variables below,
# and build/etc/, the generated /etc files. It runs every time and rewrites a
# file only when it changes, so a configuration change rebuilds what it affects
# and nothing else. A variable given on the command line still wins.
.DEFAULT_GOAL := all

CONFIG      ?= .config
CONFIG_TOOL := build/imageconfig
CONFIG_MK   := build/config.mk

$(CONFIG_TOOL): tools/imageconfig.zig $(wildcard src/config/*.zig) $(wildcard src/lib/*.zig)
	@mkdir -p build
	@$(ZIG) build-exe -O ReleaseSafe --dep config -Mroot=tools/imageconfig.zig \
		-O ReleaseSafe --dep lib -Mconfig=src/config/config.zig \
		-O ReleaseSafe -Mlib=src/lib/lib.zig \
		--name imageconfig -femit-bin=$@

.PHONY: FORCE
FORCE:

$(CONFIG_MK): $(CONFIG_TOOL) FORCE
	@$(CONFIG_TOOL) plan $(CONFIG) build

ifneq ($(filter-out clean help,$(or $(MAKECMDGOALS),all)),)
include $(CONFIG_MK)
endif

# The processor, for the programs `zig build` compiles and the C ones eeecc does.
ZIG_TARGET := -Dcpu=$(CONFIG_PROCESSOR)
export EEECC_MCPU := $(CONFIG_MCPU)

ifeq ($(ARCH),x86)
QEMU     ?= qemu-system-i386

# Sound, on by default because the machine has it. The 701's southbridge is
# an ICH6, and QEMU's `intel-hda` is a model of that same controller down to
# the PCI id, so the driver that binds here is the one that binds there.
#
# Output only, because capture is not implemented and a codec with a
# recording end asks the host for a microphone in order to attach at all.
#
# Where the samples go afterwards is the one part that belongs to the host
# rather than to the emulated machine, so it is a variable: `none` keeps the
# controller present and silent, which is all a build machine needs.
QEMU_AUDIODEV ?= $(if $(filter Darwin,$(shell uname -s)),coreaudio,none)
QEMU_SOUND := -audiodev $(QEMU_AUDIODEV),id=snd0 \
              -device intel-hda -device hda-output,audiodev=snd0

# The display advertises a netbook-sized panel over EDID, so the loader's
# ask-the-panel path is the one QEMU exercises, exactly as on hardware.
QEMU_FLAGS := -machine pc -cpu $(QEMU_CPU) -m 512M -no-reboot -vga none \
	-device VGA,edid=on,xres=800,yres=600 $(QEMU_SOUND)
else
# The QEMU stand-in for the VT8500-class Windows CE netbooks of design
# design/12-arm-port.md: same ARM926EJ-S core, same RAM budget, but a serial
# port the 701 never had, so the console is stdio rather than a panel.
QEMU     ?= qemu-system-arm
QEMU_CPU  := arm926
QEMU_FLAGS := -machine versatilepb -cpu $(QEMU_CPU) -m 256M -no-reboot -display none -serial stdio
endif
MFORMAT  ?= mformat
MCOPY    ?= mcopy
MMD      ?= mmd

BUILD    := build
IMAGE    := $(BUILD)/vibeee.img

# What the medium is cut into. One place says it; `mkimage` is told, and the
# offsets below are worked out from the same numbers, so the table in the MBR
# and the filesystems written into it cannot disagree.
#
# Everything below RESERVED_MB is read by sector number alone, because at that
# point in the boot there is no filesystem driver: the loader, the kernel and
# the root filesystem live there. The partitions follow, and `mkimage` is told
# where they begin rather than assuming: the table it writes and the offsets
# below are then the same number, whatever that number is.
RESERVED_MB   ?= 16
IMAGE_MB      ?= $(shell expr $(RESERVED_MB) + $(PART1_MB) + $(CFG_MB) + $(HOME_MB))

# The x86 emulated machine is as close to the Eee PC 701 as QEMU gets: 512 MB
# and the PIIX3 chipset. It is NOT an ICH6 and has no GMA900, no AR2425, no
# Attansic NIC and no EC, those are real-hardware-only. QEMU proves the boot
# chain, memory, interrupts, storage and PCI enumeration; nothing more.
#
# The CPU model matters more than it looks. The target is a Celeron M 353
# (Dothan): SSE2 yes, SSE3 no, no long mode. Emulating something *less* capable
# means user code compiled for the real target faults in emulation on
# instructions the hardware would have run, so the model is pinned to match
# the feature set rather than to a convenient preset.

# Partition 1 layout, mirrored from tools/mkimage.zig. mtools addresses an
# image at a byte offset with the @@ syntax, which is how the filesystem gets
# created inside the partition without loopback mounts or root.
ROOTFS_IMG    := $(BUILD)/rootfs.img
# What goes into it that is built rather than committed. Named here, above
# the rule that lists them: make expands a rule's prerequisites as it reads
# it, so a name defined further down expands to nothing and the image is
# built without ever depending on the file it copies in.
FONT_PACK     := $(BUILD)/fonts.pack
CA_STORE      := $(BUILD)/ca.store
# A megabyte, as a block size `dd` will take wherever this runs. The two
# dd's disagree about the suffix: the BSD one wants `1m` and the GNU one
# `1M`, and both take a plain count of bytes.
MEGABYTE      := 1048576

# Whether the manual is in decides what the image holds and what the
# programs were compiled against, and neither is a file whose timestamp
# make can watch. The setting is written to a stamp only when it changes,
# so switching it rebuilds and repeating it does not.
MANUAL_STAMP  := $(BUILD)/manual.stamp

PART1_LBA      = $(shell expr $(RESERVED_MB) \* 2048)
PART1_OFFSET   = $(shell expr $(PART1_LBA) \* 512)
PART1_SECTORS  = $(shell expr $(PART1_MB) \* 2048)
CFG_LBA        = $(shell expr $(PART1_LBA) + $(PART1_SECTORS))
CFG_OFFSET     = $(shell expr $(CFG_LBA) \* 512)
CFG_SECTORS    = $(shell expr $(CFG_MB) \* 2048)
HOME_LBA       = $(shell expr $(CFG_LBA) + $(CFG_SECTORS))
HOME_OFFSET    = $(shell expr $(HOME_LBA) \* 512)
HOME_SECTORS   = $(shell expr $(HOME_MB) \* 2048)

KERNEL_ELF := zig-out/bin/vibeee.elf
KERNEL_BIN := $(BUILD)/kernel.bin
STAGE1_BIN := $(BUILD)/stage1.bin
STAGE2_BIN := $(BUILD)/stage2.bin
MKIMAGE    := $(BUILD)/mkimage

.PHONY: all clean image qemu qemu-sd run test fuzz tools sd update-sd help apps app hero echat roll fmt check check-all \
	menuconfig defconfig savedefconfig olddefconfig list-defconfigs

all: image

# ---------------------------------------------------------------------------
# Configuration, with Linux's and Buildroot's target names
# ---------------------------------------------------------------------------
menuconfig: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) menu $(CONFIG)

# The default: the Eee PC 701 with everything but the extra applications.
defconfig: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) defconfig eeepc_701 $(CONFIG)

%_defconfig: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) defconfig $* $(CONFIG)

savedefconfig: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) savedefconfig $(CONFIG) defconfig

olddefconfig: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) olddefconfig $(CONFIG)

list-defconfigs: $(CONFIG_TOOL)
	@$(CONFIG_TOOL) list

help:
	@echo "vibeee build targets (ARCH=$(ARCH)):"
	@echo "  make menuconfig       choose what goes in the image, into .config"
	@echo "  make <name>_defconfig start .config from a preset; list-defconfigs names them"
	@echo "  make savedefconfig    write what .config changes from the defaults to defconfig"
	@echo "  make image            build $(IMAGE) (x86 only)"
	@echo "  make qemu             boot the kernel in QEMU"
	@echo "  make ARCH=arm qemu    boot the ARM kernel via -kernel + serial stdio"
	@echo "  make qemu-sd          boot the SD image the way real hardware does (x86)"
	@echo "  make vnc              boot over VNC instead of a local window"
	@echo "  make apps             build the programs in apps/ into home/"
	@echo "  make hero             build the Hero character journal into home/"
	@echo "  make echat            build the echat IRC client into home/"
	@echo "  make eeemod           build the eeemod tracker player into home/"
	@echo "  make roll             build the Roll contact sheet into home/"
	@echo "  make web              build the experimental web browser into home/"
	@echo "  make app APP=doom     build one of them"
	@echo "  make test             host-side unit tests + QR verification"
	@echo "  make check            module layering and import rules"
	@echo "  make check-all        format, layering, tests, images, a headless boot and a reboot"
	@echo "  make qemu-panic       boot into the panic screen (x86)"
	@echo "  make sd DEV=/dev/rdiskN   flash the whole image to a card (x86), wiping it"
	@echo "  make update-sd DEV=/dev/rdiskN  overwrite a card's system partition only"
	@echo "  make clean"

# ---------------------------------------------------------------------------
# Kernel
# ---------------------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: kernel
kernel:
	$(ZIG) build $(ZIG_FLAGS) $(ZIG_TARGET) -Darch=$(ARCH) $(if $(filter yes,$(MANUAL)),,-Dmanual=false)

# The SD path loads a flat binary, not ELF: stage2 jumps to its first byte,
# which is the entry stub placed there by the linker script.
$(KERNEL_BIN): kernel | $(BUILD)
	$(ZIG) objcopy -O binary $(KERNEL_ELF) $@

# ---------------------------------------------------------------------------
# Bootloader
# ---------------------------------------------------------------------------
$(STAGE1_BIN): boot/stage1.asm | $(BUILD)
	$(NASM) -f bin $< -o $@

$(STAGE2_BIN): boot/stage2.asm | $(BUILD)
	$(NASM) -f bin $< -o $@

# ---------------------------------------------------------------------------
# Image assembly
# ---------------------------------------------------------------------------
$(MKIMAGE): tools/mkimage.zig | $(BUILD)
	$(ZIG) build-exe $< -O ReleaseSafe --name mkimage -femit-bin=$@

# C programs, built against eeelibc with the wrapper rather than with the Zig
# build graph: a port arrives as a Makefile expecting a compiler, and `eeecc`
# is what it should find.
#
# Every one of them, because an example that is not built is an example
# that has stopped compiling and nobody has been told.
EXAMPLES := $(patsubst examples/%.c,$(BUILD)/%,$(wildcard examples/*.c))

$(BUILD)/%: examples/%.c | $(BUILD)
	@tools/eeecc -o $@ $<

.PHONY: examples
examples: kernel $(EXAMPLES)
	@echo "examples: $(words $(EXAMPLES)) built"

# Things that are not part of the system, built separately and installed
# into `home/bin/`. See apps/README.md.
apps: hero echat eeemod roll web qjs
	@$(MAKE) --no-print-directory -C apps

# Hero, the character journal: a first-party program that is not part of the
# system, built into home/ beside a person's files rather than into the image.
# Its model is host-tested first, since the whole of a character is what its
# lines add up to and none of it needs a screen to be checked.
.PHONY: hero
hero:
	@$(ZIG) build test-hero
	@$(ZIG) build hero $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/hero home/bin/hero
	@echo "  ready   home/bin/hero, on the machine at the next image build"

# The IRC client. Its engine and model are host-tested first: a protocol is
# bytes in and bytes out, and none of it needs a screen to be checked.
.PHONY: echat
echat:
	@$(ZIG) build test-echat
	@$(ZIG) build echat $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/echat home/bin/echat
	@echo "  ready   home/bin/echat, on the machine at the next image build"

# The tracker player. Its format and sequencer are host-tested first: a
# module is bytes in and notes out, and neither needs a sound card.
.PHONY: eeemod
eeemod:
	@$(ZIG) build test-eeemod
	@$(ZIG) build eeemod $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/eeemod home/bin/eeemod
	@echo "  ready   home/bin/eeemod, on the machine at the next image build"

# The contact sheet. Its model is host-tested first: which picture is current,
# what a page holds and what a filter leaves is arithmetic over a list, and
# none of it needs a card in the reader.
.PHONY: roll
roll:
	@$(ZIG) build test-roll
	@$(ZIG) build roll $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/roll home/bin/roll
	@echo "  ready   home/bin/roll, on the machine at the next image build"

# The web browser, which is an experiment rather than part of the system: it
# is built into home/ like the rest of apps/. Its host side is tested first:
# addresses, the protocol, encodings, a page and where its words go are
# arithmetic over text, and none of it needs a network or a screen.
.PHONY: web
web:
	@$(ZIG) build test-web
	@$(ZIG) build web $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/web home/bin/web
	@echo "  ready   home/bin/web, on the machine at the next image build"

# The script runner: QuickJS, vendored and built into a program of this
# system's. Not host-tested, being C that is not ours: what is tested here is
# that it builds for the machine, and the rest is a script run on the machine.
.PHONY: qjs
qjs:
	@$(ZIG) build qjs $(ZIG_TARGET)
	@mkdir -p home/bin
	@cp zig-out/bin/qjs home/bin/qjs
	@echo "  ready   home/bin/qjs, on the machine at the next image build"

# The document a script sees, checked on this machine: QuickJS, lexbor and the
# browser's own DOM over them, built for the host rather than the target, so a
# page can be parsed, a script run in it and the tree read back. It is C
# reaching into two vendored trees, which is the part the browser's Zig tests
# cannot see.
.PHONY: dom-test
dom-test:
	@$(ZIG) build test-dom

.PHONY: doom
doom:
	@$(MAKE) --no-print-directory -C apps APP=doom build

app:
	@if [ -z "$(APP)" ]; then echo "usage: make app APP=<name>"; exit 1; fi
	@$(MAKE) --no-print-directory -C apps APP=$(APP) build

image: $(IMAGE)

# The root filesystem: a plain FAT image, loaded into RAM by stage2.
#
# FAT rather than a bespoke container because the driver already exists, and
# because it can then be inspected and edited from any other machine.
.PHONY: manual-stamp
manual-stamp: | $(BUILD)
	@printf '%s' "$(MANUAL)" | cmp -s - $(MANUAL_STAMP) 2>/dev/null || printf '%s' "$(MANUAL)" > $(MANUAL_STAMP)

$(MANUAL_STAMP): manual-stamp

# `wildcard` is evaluated when the makefile is read, so a C example built
# after that would not be seen. Listed explicitly for the ones that exist,
# which is what makes rebuilding one of them rebuild the image it goes in:
# without this the old binary ships and the new one is never run.
$(ROOTFS_IMG): kernel examples $(FONT_PACK) $(CA_STORE) $(MANUAL_STAMP) $(CONFIG_MK) $(wildcard manual/*) $(wildcard etc/*) $(wildcard $(BUILD)/etc/*) $(wildcard drivers/*) | $(BUILD)
	@rm -f $@
	@dd if=/dev/zero of=$@ bs=$(MEGABYTE) count=$(ROOTFS_MB) status=none
	@$(MFORMAT) -i $@ -F -T $(shell expr $(ROOTFS_MB) \* 2048) -v VIBEEEROOT ::
	@for d in bin etc lib lib/drivers share tmp home media cfg; do $(MMD) -i $@ ::/$$d; done
	@if [ "$(MANUAL)" = "yes" ]; then $(MMD) -i $@ ::/doc; fi
	@for f in $(ROOTFS_SHARE); do $(MCOPY) -i $@ -o $(BUILD)/$$f ::/share/$$f; done
	@for p in $(ROOTFS_PROGRAMS); do $(MCOPY) -i $@ -o zig-out/bin/$$p ::/bin/$$p; done
	@for p in $(ROOTFS_EXAMPLES); do $(MCOPY) -i $@ -o $(BUILD)/$$p ::/bin/$$p; done
	@for f in services disabled openers; do $(MCOPY) -i $@ -o $(BUILD)/etc/$$f ::/etc/$$f; done
	@for f in input.cfg wm.cfg net.cfg time.cfg hosts open.cfg power.cfg; do $(MCOPY) -i $@ -o etc/$$f ::/etc/$$f; done
	@for f in $(ROOTFS_DRIVERS); do $(MCOPY) -i $@ -o drivers/$$f ::/lib/drivers/$$f; done
	@if [ "$(MANUAL)" = "yes" ]; then \
		for f in manual/*; do $(MCOPY) -i $@ -o $$f ::/doc/$$(basename $$f); done; \
	fi

$(IMAGE): $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG) $(HOME_APPS)
ifeq ($(ARCH),arm)
	$(error $(IMAGE) is x86-only today; for arm use: make qemu)
else
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $@ $(IMAGE_MB) "$(CMDLINE)" $(ROOTFS_IMG) \
		$(PART1_MB) $(CFG_MB) $(HOME_MB) $(RESERVED_MB)
	@$(MAKE) --no-print-directory populate IMG=$@
endif

# Create the filesystem in partition 1 and fill it. Separate from mkimage
# because formatting FAT is exactly the kind of thing not worth reimplementing:
# mtools is proven, and it needs neither root nor a loopback mount.
.PHONY: populate
# Nothing from the build graph: this formats the volumes in an image that
# already exists and copies files into them. Both callers have built the
# kernel by the time they ask.
populate: | $(BUILD)
	@$(MFORMAT) -i $(IMG)@@$(PART1_OFFSET) -F -T $(PART1_SECTORS) -v VIBEEE ::
	@echo "vibeee $(shell date -u +%Y-%m-%dT%H:%M:%SZ)" > $(BUILD)/version.txt
	@$(MCOPY) -i $(IMG)@@$(PART1_OFFSET) -o $(BUILD)/version.txt ::/version.txt
	@# The two that outlive a boot: what the machine was told, and what was
	@# left in it. The settings volume starts empty, because everything in it
	@# is a choice somebody made. Home gets the one file a new card should
	@# have in it.
	@$(MFORMAT) -i $(IMG)@@$(CFG_OFFSET) -F -T $(CFG_SECTORS) -v VIBEEECFG ::
	@$(MFORMAT) -i $(IMG)@@$(HOME_OFFSET) -F -T $(HOME_SECTORS) -v VIBEEEHOME ::
	@# Where the extra applications go, made whether or not any were built:
	@# it is on the path, and a path naming a directory that is not there
	@# is one more thing to explain.
	@$(MMD) -i $(IMG)@@$(HOME_OFFSET) ::/bin
	@printf "vibeee\nbuilt %s\n" "$(shell date -u +%Y-%m-%dT%H:%M:%SZ)" > $(BUILD)/readme.txt
	@$(MCOPY) -i $(IMG)@@$(HOME_OFFSET) -o $(BUILD)/readme.txt ::/readme.txt
	@# And what is staged for it: all of home/ when the configuration says
	@# so, otherwise only the extra applications it selects.
	@if [ "$(HOME_STAGED)" = "yes" ]; then \
		for f in home/*; do \
			[ -e "$$f" ] || continue; \
			$(MCOPY) -s -i $(IMG)@@$(HOME_OFFSET) -o "$$f" ::/ ; \
		done; \
	else \
		for a in $(HOME_APPS); do $(MCOPY) -i $(IMG)@@$(HOME_OFFSET) -o home/bin/$$a ::/bin/$$a; done; \
	fi

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

# Default dev loop: boot the real image off an emulated IDE disk. Fast enough
# that a separate Multiboot shortcut is not worth maintaining, and it exercises
# the bootloader every time.
#
# Note `-kernel` is deliberately not used: QEMU's Multiboot ELF loader places
# segments at their virtual addresses, which cannot work for a higher-half
# kernel. The Multiboot header is kept for GRUB, which loads by physical
# address correctly.
# The development loop boots verbose, so the self-test results are visible.
# A plain `make image` is quiet: a working system should boot without narrating.
DEV_IMAGE := $(BUILD)/vibeee-dev.img

# The development loop boots verbose and in the framebuffer console, so the
# self-test output is visible and it is rendered in the same font the real
# machine will use. `fb` is opt-in rather than the default because switching to
# graphics silences the text console: on a machine whose only output is the
# screen, the default has to be the mode already known to work.
DEV_CMDLINE ?= verbose

# What the emulator's display reports when asked. QEMU's BIOS answers DDC, so
# this is only the ceiling for a machine that does not; it is set here because
# a desktop judged at 640x480 is judged at a size no netbook in this class has.
DEV_PANEL ?= 800x600

.PHONY: dev-image
dev-image: $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG) $(HOME_APPS)
ifeq ($(ARCH),arm)
	$(error $(DEV_IMAGE) is x86-only today; for arm use: make qemu)
else
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(DEV_IMAGE) $(IMAGE_MB) "$(DEV_CMDLINE)" $(ROOTFS_IMG) \
		$(PART1_MB) $(CFG_MB) $(HOME_MB) $(RESERVED_MB) $(DEV_PANEL)
	@$(MAKE) --no-print-directory populate IMG=$(DEV_IMAGE)
endif

ifeq ($(ARCH),arm)
# No BIOS, no MBR, no VGA text on a CE-era ARM machine: the kernel is passed
# straight to QEMU's firmware-less loader, and the console is the serial port
# the 701 never had. Design/12-arm-port.md is the bring-up plan this serves.
qemu: kernel
	$(QEMU) $(QEMU_FLAGS) -kernel $(KERNEL_ELF)
else
qemu: dev-image
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(DEV_IMAGE)
endif

# Boot the verbose image headless and photograph the screen. `TYPE` is typed at
# the shell first, one key at a time through the QEMU monitor, which is the only
# way to drive a machine whose only input is a PS/2 keyboard.
#
# The console is mirrored to the serial port, so a run also leaves a text
# transcript beside the PNG. Reading that beats reading a screenshot for
# everything except what the screen itself looks like: a `fail` line scrolled
# off the top of a 30-row display is invisible in an image and obvious here.
#
#   make shot OUT=/tmp/x.png TYPE="date"
#
# `MONITOR` sends raw QEMU monitor commands after the typing, one per line,
# which is how a chord and the pointer are exercised: `sendkey meta_l-p`,
# `mouse_move dx dy`, `mouse_button 1`. `SETTLE` is how long to leave the
# machine alone before the shot.
#
# `EXTRA` appends QEMU arguments, which is how a test boots hardware the
# default machine lacks: a second NIC, another disk.
.PHONY: shot
shot: dev-image
	@QEMU_CPU="$(QEMU_CPU)" tools/qemu-shot.sh $(OUT) $(if $(TYPE),-t "$(TYPE)") \
		$(if $(MONITOR),-m "$(MONITOR)") $(if $(SETTLE),-s $(SETTLE)) $(if $(PAUSE),-p $(PAUSE)) -w $(or $(WAIT),5) \
		-- -drive if=ide,format=raw,file=$(DEV_IMAGE) $(EXTRA)

run: qemu

# Boot with a VNC server instead of a local window, so the machine can be
# driven from anywhere, including from a phone, and including while a
# screenshot run is using the local display.
#
# macOS has a VNC client built in: `open vnc://localhost:5901`.
VNC_DISPLAY ?= 1

.PHONY: vnc
vnc: dev-image
	@echo "vnc://localhost:$$(( 5900 + $(VNC_DISPLAY) ))  (macOS: open vnc://localhost:$$(( 5900 + $(VNC_DISPLAY) )))"
	$(QEMU) $(QEMU_FLAGS) -vnc :$(VNC_DISPLAY) \
		-drive if=ide,format=raw,file=$(DEV_IMAGE)

# The same, for the real image on the SD path the 701 actually boots.
.PHONY: vnc-sd
vnc-sd: $(IMAGE)
	@echo "vnc://localhost:$$(( 5900 + $(VNC_DISPLAY) ))"
	$(QEMU) $(QEMU_FLAGS) -vnc :$(VNC_DISPLAY) $(QEMU_SD)

# Boot the real image. `-drive if=none,format=raw` + `usb-storage` mirrors the
# 701's actual path: the SD card sits behind a USB mass-storage reader, and the
# BIOS boots it through USB-HDD emulation. The machine needs a USB host
# controller for the reader to hang off, which `-usb` gives it.
QEMU_SD := -usb -drive if=none,id=sd,format=raw,file=$(IMAGE) \
	-device usb-storage,drive=sd,bootindex=0

qemu-sd: $(IMAGE)
	$(QEMU) $(QEMU_FLAGS) $(QEMU_SD)

# Same image on an emulated IDE disk, the internal SSD install path.
.PHONY: qemu-ide
qemu-ide: $(IMAGE)
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(IMAGE)

# The system's host tests, and the extra applications' own alongside them.
# Their models are pure Zig and cost no emulator, so leaving them out only
# meant a broken one could sit in the tree unnoticed. Building the apps for
# the target is still on demand: that is the expensive half.
test: qr-verify
	$(ZIG) build test
	$(ZIG) build test-hero test-echat test-eeemod test-roll

# Drive the fuzz targets. Not in `test` or `check-all`: a fuzzer runs until
# stopped.
#
# Does not work on Zig 0.16.0: the compiler's test runner fails to build in
# fuzz mode, passing the wrong `StackTrace` to `writeStackTrace`. A four-line
# project with one fuzz test fails the same way. The targets still compile
# under `test`, and each has a seeded counterpart that runs there.
#
# LIMIT bounds the run in iterations, K/M/G suffix allowed.
#
#   make fuzz
#   make fuzz LIMIT=200K
.PHONY: fuzz
fuzz:
	$(ZIG) build test --fuzz$(if $(LIMIT),=$(LIMIT),)

# The tree is formatted, as `zig fmt` formats it. Checked rather than
# assumed: the one file a hand-aligned table exempts is the one that drifts.
fmt:
	$(ZIG) fmt --check src tools apps build.zig

check:
	$(ZIG) build check

# Everything a change passes before it is done, in the order the cheap ones
# come first. The last steps boot the development image headless and read the
# serial transcript: the boot reports ready, the probe's refusals all hold, no
# service failed, nothing panicked or tripped the watchdog, a setting written
# on the first boot is read back on the second, and each network adapter the
# emulator has comes up, takes a lease and answers an echo.
#
# The partition offsets are passed in so that the script has no copy of the
# image layout to fall out of step with.
#
# The configuration checked is the default one, whatever .config says: an
# empty file is the defaults.
check-all:
	@$(MAKE) --no-print-directory CONFIG=/dev/null check-default

.PHONY: check-default
check-default: fmt check test dom-test dev-image image
	@BUILD=$(BUILD) ROOTFS_IMG=$(ROOTFS_IMG) DEV_IMAGE=$(DEV_IMAGE) IMAGE=$(IMAGE) \
		CFG_OFFSET=$(CFG_OFFSET) HOME_OFFSET=$(HOME_OFFSET) QEMU_CPU="$(QEMU_CPU)" \
		tools/check-all.sh

# The AR5212 family's register tables, transcribed from the pinned reference
# by a generator so no number in them is ever typed by hand. Regenerated
# only when the reference's pin moves; the output is committed.
$(BUILD)/mkathtables: tools/mkathtables.zig | $(BUILD)
	$(ZIG) build-exe $< -O ReleaseSafe --name mkathtables -femit-bin=$@

.PHONY: athtables
athtables: $(BUILD)/mkathtables
	$(BUILD)/mkathtables third_party/ath_hal/ar5212/ar5212.ini src/user/netd/ar5212/tables.zig
	$(ZIG) fmt src/user/netd/ar5212/tables.zig

# The interface faces, packed into the one file every window draws from. Built
# rather than committed: it is the same glyphs as `src/lib/fonts/`, in the shape
# a program maps. Its name is above, with the rest of what the image holds.
$(BUILD)/mkfontpack: tools/mkfontpack.zig $(wildcard src/lib/fonts/*.zig) src/lib/font.zig | $(BUILD)
	$(ZIG) build-exe -O ReleaseSafe --name mkfontpack -femit-bin=$@ \
		--dep lib -Mroot=tools/mkfontpack.zig -Mlib=src/lib/lib.zig

$(FONT_PACK): $(BUILD)/mkfontpack
	@$(BUILD)/mkfontpack $@

# The certificate authorities a TLS connection is checked against, decoded
# from the vendored bundle once here rather than at every connection.
$(BUILD)/mkcastore: tools/mkcastore.zig src/lib/castore.zig | $(BUILD)
	$(ZIG) build-exe -O ReleaseSafe --name mkcastore -femit-bin=$@ \
		--dep lib -Mroot=tools/mkcastore.zig -Mlib=src/lib/lib.zig

$(CA_STORE): $(BUILD)/mkcastore third_party/cacert/cacert.pem
	@$(BUILD)/mkcastore third_party/cacert/cacert.pem $@

# The IRC parser vectors, transcribed from the pinned reference by a generator
# so no case in the table is typed by hand. Regenerate when the reference's pin
# moves; the output is committed.
$(BUILD)/mkirctests: tools/mkirctests.zig | $(BUILD)
	$(ZIG) build-exe $< -O ReleaseSafe --name mkirctests -femit-bin=$@

.PHONY: irctests
irctests: $(BUILD)/mkirctests
	$(BUILD)/mkirctests third_party/irc-parser-tests apps/echat/irc/vectors.zig
	$(ZIG) fmt apps/echat/irc/vectors.zig

# Differential-test the QR encoder against libqrencode. A QR that merely looks
# right is worthless: the failure mode is a panic screen nobody can scan.
$(BUILD)/qrdump: src/qrdump.zig src/kernel/qr.zig | $(BUILD)
	$(ZIG) build-exe $< -O ReleaseSafe --name qrdump -femit-bin=$@

.PHONY: qr-verify
qr-verify: $(BUILD)/qrdump
	@QRDUMP=$(BUILD)/qrdump ./tools/qr-verify.sh

# Boot straight into the panic screen, to check its layout and that the QR
# still scans after a change.
.PHONY: qemu-panic
qemu-panic: $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG)
ifeq ($(ARCH),arm)
	$(error qemu-panic is x86-only today)
else
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(BUILD)/vibeee-panic.img $(IMAGE_MB) panictest $(ROOTFS_IMG) \
		$(PART1_MB) $(CFG_MB) $(HOME_MB) $(RESERVED_MB)
	@$(MAKE) --no-print-directory populate IMG=$(BUILD)/vibeee-panic.img
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(BUILD)/vibeee-panic.img
endif

# ---------------------------------------------------------------------------
# Flashing
# ---------------------------------------------------------------------------
# Guarded: refuses anything that is not a character device, and always asks.
# Getting this wrong overwrites a disk, so the check is not optional.
sd: $(IMAGE)
	@if [ -z "$(DEV)" ]; then echo "usage: make sd DEV=/dev/rdiskN"; exit 1; fi
	@if [ ! -e "$(DEV)" ]; then echo "$(DEV) does not exist"; exit 1; fi
	@echo "About to overwrite $(DEV) with $(IMAGE):"
	@diskutil info $(DEV) 2>/dev/null | grep -E "Device / Media Name|Disk Size|Removable Media|Virtual" || true
	@printf "Type ERASE to continue: "; read ans; [ "$$ans" = "ERASE" ] || { echo aborted; exit 1; }
	diskutil unmountDisk $(DEV) || true
	@echo "Writing to a raw device needs root; the build itself does not."
	sudo dd if=$(IMAGE) of=$(DEV) bs=$(MEGABYTE) status=progress
	sync
	diskutil eject $(DEV) || true

# The same guard as `sd`, but stopped short of `/cfg`: only the bytes before
# it, the boot sectors and the system partition, are written. A card's
# settings and its home files are past that point and never touched, which
# is what makes this the one to reach for on a card already carrying
# somebody's own files rather than the one built to throw away.
update-sd: $(IMAGE)
	@if [ -z "$(DEV)" ]; then echo "usage: make update-sd DEV=/dev/rdiskN"; exit 1; fi
	@if [ ! -e "$(DEV)" ]; then echo "$(DEV) does not exist"; exit 1; fi
	@echo "About to overwrite the system partition of $(DEV) with $(IMAGE)"
	@echo "(the first $(CFG_LBA) sectors; /cfg and /home are left alone):"
	@diskutil info $(DEV) 2>/dev/null | grep -E "Device / Media Name|Disk Size|Removable Media|Virtual" || true
	@printf "Type ERASE to continue: "; read ans; [ "$$ans" = "ERASE" ] || { echo aborted; exit 1; }
	diskutil unmountDisk $(DEV) || true
	@echo "Writing to a raw device needs root; the build itself does not."
	sudo dd if=$(IMAGE) of=$(DEV) bs=512 count=$(CFG_LBA) status=progress
	sync
	diskutil eject $(DEV) || true

clean:
	rm -rf $(BUILD) zig-out .zig-cache
