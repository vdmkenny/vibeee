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

ifeq ($(ARCH),x86)
QEMU     ?= qemu-system-i386
QEMU_CPU  := pentium3,+sse2,+pae,+nx,-sse3
QEMU_FLAGS := -machine pc -cpu $(QEMU_CPU) -m 512M -no-reboot
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

# Whether the image carries the manual. Twenty kilobytes of text, read
# over the BIOS's own USB path at boot like everything else in the root
# filesystem, so a build that wants the smallest possible image can
# decline it: the command listings then print names alone and `man` says
# there is no manual on this filesystem.
MANUAL   ?= yes

BUILD    := build
IMAGE    := $(BUILD)/vibeee.img
IMAGE_MB ?= 48
# Boot parameters baked into the image; the SD path has no equivalent of
# QEMU's -append, so they travel in the stage2 header.
CMDLINE  ?=

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
# Small on purpose: it is read over the BIOS's slow USB path at boot, so every
# kilobyte is time on the target machine.
ROOTFS_MB     ?= 2

# Whether the manual is in decides what the image holds and what the
# programs were compiled against, and neither is a file whose timestamp
# make can watch. The setting is written to a stamp only when it changes,
# so switching it rebuilds and repeating it does not.
MANUAL_STAMP  := $(BUILD)/manual.stamp

PART1_LBA     := 32768
PART1_OFFSET  := $(shell expr $(PART1_LBA) \* 512)
PART1_SECTORS := $(shell expr $(IMAGE_MB) \* 2048 - $(PART1_LBA))

KERNEL_ELF := zig-out/bin/vibeee.elf
USER_INIT  := zig-out/bin/init
USER_WM    := zig-out/bin/eeewm
USER_SETTINGS := zig-out/bin/settings
USER_MONITOR := zig-out/bin/monitor
USER_ETERM := zig-out/bin/eterm
USER_PAD := zig-out/bin/pad
USER_DEVMGD := zig-out/bin/devmgd
USER_NETD    := zig-out/bin/netd
USER_SNDD    := zig-out/bin/sndd
USER_USBD    := zig-out/bin/usbd
USER_CFGD := zig-out/bin/cfgd
USER_PLATD := zig-out/bin/platd
USER_TOOLS := zig-out/bin/tools
USER_VSH   := zig-out/bin/vsh
KERNEL_BIN := $(BUILD)/kernel.bin
STAGE1_BIN := $(BUILD)/stage1.bin
STAGE2_BIN := $(BUILD)/stage2.bin
MKIMAGE    := $(BUILD)/mkimage

.PHONY: all clean image qemu qemu-sd run test tools sd help

all: image

help:
	@echo "vibeee build targets (ARCH=$(ARCH)):"
	@echo "  make image            build $(IMAGE) (x86 only)"
	@echo "  make qemu             boot the kernel in QEMU"
	@echo "  make ARCH=arm qemu    boot the ARM kernel via -kernel + serial stdio"
	@echo "  make qemu-sd          boot the SD image the way real hardware does (x86)"
	@echo "  make test             host-side unit tests + QR verification"
	@echo "  make qemu-panic       boot into the panic screen (x86)"
	@echo "  make sd DEV=/dev/rdiskN   flash the image to a card (x86)"
	@echo "  make MANUAL=no image   build without the manual"
	@echo "  make clean"

# ---------------------------------------------------------------------------
# Kernel
# ---------------------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: kernel
kernel:
	$(ZIG) build $(ZIG_FLAGS) -Darch=$(ARCH) $(if $(filter yes,$(MANUAL)),,-Dmanual=false)

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
# A ported program keeps the name it came with. `kilo` is somebody else's
# editor and calling it anything else would hide where it came from, and take
# the name our own editor is going to want.
.PHONY: examples
examples: kernel
	@tools/eeecc -o $(BUILD)/greet examples/greet.c
	@tools/eeecc -o $(BUILD)/kilo -Dmain=kilo_main third_party/kilo/kilo.c src/user/ports/kilo.c

image: $(IMAGE)

# The root filesystem: a plain FAT image, loaded into RAM by stage2.
#
# FAT rather than a bespoke container because the driver already exists, and
# because it can then be inspected and edited from any other machine.
.PHONY: manual-stamp
manual-stamp: | $(BUILD)
	@printf '%s' "$(MANUAL)" | cmp -s - $(MANUAL_STAMP) 2>/dev/null || printf '%s' "$(MANUAL)" > $(MANUAL_STAMP)

$(MANUAL_STAMP): manual-stamp

$(ROOTFS_IMG): kernel examples $(MANUAL_STAMP) $(wildcard manual/*) $(wildcard etc/*) $(wildcard drivers/*) | $(BUILD)
	@rm -f $@
	@dd if=/dev/zero of=$@ bs=1m count=$(ROOTFS_MB) status=none
	@$(MFORMAT) -i $@ -F -T $(shell expr $(ROOTFS_MB) \* 2048) -v VIBEEEROOT ::
	@for d in bin etc lib lib/drivers tmp home media; do $(MMD) -i $@ ::/$$d; done
	@if [ "$(MANUAL)" = "yes" ]; then $(MMD) -i $@ ::/doc; fi
	@$(MCOPY) -i $@ -o $(USER_INIT) ::/bin/init
	@$(MCOPY) -i $@ -o $(USER_VSH) ::/bin/vsh
	@$(MCOPY) -i $@ -o $(BUILD)/greet ::/bin/greet
	@$(MCOPY) -i $@ -o $(BUILD)/kilo ::/bin/kilo
	@$(MCOPY) -i $@ -o $(USER_TOOLS) ::/bin/tools
	@$(MCOPY) -i $@ -o $(USER_DEVMGD) ::/bin/devmgd
	@$(MCOPY) -i $@ -o $(USER_NETD) ::/bin/netd
	@$(MCOPY) -i $@ -o $(USER_SNDD) ::/bin/sndd
	@$(MCOPY) -i $@ -o $(USER_USBD) ::/bin/usbd
	@$(MCOPY) -i $@ -o $(USER_CFGD) ::/bin/cfgd
	@$(MCOPY) -i $@ -o $(USER_PLATD) ::/bin/platd
	@$(MCOPY) -i $@ -o $(USER_WM) ::/bin/eeewm
	@$(MCOPY) -i $@ -o $(USER_ETERM) ::/bin/eterm
	@$(MCOPY) -i $@ -o $(USER_PAD) ::/bin/pad
	@$(MCOPY) -i $@ -o $(USER_MONITOR) ::/bin/monitor
	@$(MCOPY) -i $@ -o $(USER_SETTINGS) ::/bin/settings
	@$(MCOPY) -i $@ -o etc/services ::/etc/services
	@$(MCOPY) -i $@ -o etc/input.cfg ::/etc/input.cfg
	@$(MCOPY) -i $@ -o etc/wm.cfg ::/etc/wm.cfg
	@$(MCOPY) -i $@ -o etc/hosts ::/etc/hosts
	@for f in drivers/*.man; do $(MCOPY) -i $@ -o $$f ::/lib/drivers/$$(basename $$f); done
	@if [ "$(MANUAL)" = "yes" ]; then \
		for f in manual/*; do $(MCOPY) -i $@ -o $$f ::/doc/$$(basename $$f); done; \
	fi
	@printf "vibeee\nbuilt %s\n" "$(shell date -u +%Y-%m-%dT%H:%M:%SZ)" > $(BUILD)/readme.txt
	@$(MCOPY) -i $@ -o $(BUILD)/readme.txt ::/home/readme.txt

$(IMAGE): $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG)
ifeq ($(ARCH),arm)
	$(error $(IMAGE) is x86-only today; for arm use: make qemu)
else
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $@ $(IMAGE_MB) "$(CMDLINE)" $(ROOTFS_IMG)
	@$(MAKE) --no-print-directory populate IMG=$@
endif

# Create the filesystem in partition 1 and fill it. Separate from mkimage
# because formatting FAT is exactly the kind of thing not worth reimplementing:
# mtools is proven, and it needs neither root nor a loopback mount.
.PHONY: populate
populate: kernel
	@$(MFORMAT) -i $(IMG)@@$(PART1_OFFSET) -F -T $(PART1_SECTORS) -v VIBEEE ::
	@echo "vibeee $(shell date -u +%Y-%m-%dT%H:%M:%SZ)" > $(BUILD)/version.txt
	@$(MCOPY) -i $(IMG)@@$(PART1_OFFSET) -o $(BUILD)/version.txt ::/version.txt

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
DEV_CMDLINE ?= verbose fb

.PHONY: dev-image
dev-image: $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG)
ifeq ($(ARCH),arm)
	$(error $(DEV_IMAGE) is x86-only today; for arm use: make qemu)
else
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(DEV_IMAGE) $(IMAGE_MB) "$(DEV_CMDLINE)" $(ROOTFS_IMG)
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
# `EXTRA` appends QEMU arguments, which is how a test boots hardware the
# default machine lacks: a second NIC, another disk.
.PHONY: shot
shot: dev-image
	@QEMU_CPU="$(QEMU_CPU)" tools/qemu-shot.sh $(OUT) $(if $(TYPE),-t "$(TYPE)") -w $(or $(WAIT),5) \
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
	$(QEMU) $(QEMU_FLAGS) -vnc :$(VNC_DISPLAY) \
		-drive if=none,id=sd,format=raw,file=$(IMAGE) \
		-device usb-storage,drive=sd,bootindex=0

# Boot the real image. `-drive if=none,format=raw` + `usb-storage` mirrors the
# 701's actual path: the SD card sits behind a USB mass-storage reader, and the
# BIOS boots it through USB-HDD emulation.
qemu-sd: $(IMAGE)
	$(QEMU) $(QEMU_FLAGS) \
		-drive if=none,id=sd,format=raw,file=$(IMAGE) \
		-device usb-storage,drive=sd,bootindex=0

# Same image on an emulated IDE disk, the internal SSD install path.
.PHONY: qemu-ide
qemu-ide: $(IMAGE)
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(IMAGE)

test: qr-verify
	$(ZIG) build test

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
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(BUILD)/vibeee-panic.img $(IMAGE_MB) panictest $(ROOTFS_IMG)
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
	sudo dd if=$(IMAGE) of=$(DEV) bs=1m status=progress
	sync
	diskutil eject $(DEV) || true

clean:
	rm -rf $(BUILD) zig-out .zig-cache
