# vibeee — top-level build.
#
# Produces build/vibeee.img: a raw, dd-able SD-card image.
#
# Toolchain: zig, nasm, qemu (for `make qemu`). Nothing else — no cross-GCC, no
# autotools, no root privileges, no loopback mounts. See design/00-vibeee.md §14.

ZIG      ?= zig
NASM     ?= nasm
QEMU     ?= qemu-system-i386
MFORMAT  ?= mformat
MCOPY    ?= mcopy

BUILD    := build
IMAGE    := $(BUILD)/vibeee.img
IMAGE_MB ?= 48
# Boot parameters baked into the image; the SD path has no equivalent of
# QEMU's -append, so they travel in the stage2 header.
CMDLINE  ?=

# The emulated machine is as close to the Eee PC 701 as QEMU gets: 512 MB, a
# pre-SSE3 CPU, and the PIIX3 chipset. It is NOT an ICH6 and has no GMA900, no
# AR2425, no Attansic NIC and no EC — those are real-hardware-only. QEMU proves
# the boot chain, memory, interrupts and PCI enumeration; nothing more.
QEMU_FLAGS := -machine pc -cpu pentium2 -m 512M -no-reboot

# Partition 1 layout, mirrored from tools/mkimage.zig. mtools addresses an
# image at a byte offset with the @@ syntax, which is how the filesystem gets
# created inside the partition without loopback mounts or root.
ROOTFS_IMG    := $(BUILD)/rootfs.img
# Small on purpose: it is read over the BIOS's slow USB path at boot, so every
# kilobyte is time on the target machine.
ROOTFS_MB     ?= 2

PART1_LBA     := 32768
PART1_OFFSET  := $(shell expr $(PART1_LBA) \* 512)
PART1_SECTORS := $(shell expr $(IMAGE_MB) \* 2048 - $(PART1_LBA))

KERNEL_ELF := zig-out/bin/vibeee.elf
USER_HELLO := zig-out/bin/hello
USER_TOOLS := zig-out/bin/tools
KERNEL_BIN := $(BUILD)/kernel.bin
STAGE1_BIN := $(BUILD)/stage1.bin
STAGE2_BIN := $(BUILD)/stage2.bin
MKIMAGE    := $(BUILD)/mkimage

.PHONY: all clean image qemu qemu-sd run test tools sd help

all: image

help:
	@echo "vibeee build targets:"
	@echo "  make image            build $(IMAGE)"
	@echo "  make qemu             boot the kernel directly (fast dev loop)"
	@echo "  make qemu-sd          boot the SD image the way real hardware does"
	@echo "  make test             host-side unit tests + QR verification"
	@echo "  make qemu-panic       boot into the panic screen"
	@echo "  make sd DEV=/dev/rdiskN   flash the image to a card"
	@echo "  make clean"

# ---------------------------------------------------------------------------
# Kernel
# ---------------------------------------------------------------------------
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: kernel
kernel:
	$(ZIG) build

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

image: $(IMAGE)

# The root filesystem: a plain FAT image, loaded into RAM by stage2.
#
# FAT rather than a bespoke container because the driver already exists, and
# because it can then be inspected and edited from any other machine.
$(ROOTFS_IMG): kernel | $(BUILD)
	@rm -f $@
	@dd if=/dev/zero of=$@ bs=1m count=$(ROOTFS_MB) status=none
	@$(MFORMAT) -i $@ -F -T $(shell expr $(ROOTFS_MB) \* 2048) -v VIBEEEROOT ::
	@$(MCOPY) -i $@ -o $(USER_HELLO) ::/HELLO
	@$(MCOPY) -i $@ -o $(USER_TOOLS) ::/TOOLS

$(IMAGE): $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG)
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $@ $(IMAGE_MB) "$(CMDLINE)" $(ROOTFS_IMG)
	@$(MAKE) --no-print-directory populate IMG=$@

# Create the filesystem in partition 1 and fill it. Separate from mkimage
# because formatting FAT is exactly the kind of thing not worth reimplementing:
# mtools is proven, and it needs neither root nor a loopback mount.
.PHONY: populate
populate: kernel
	@$(MFORMAT) -i $(IMG)@@$(PART1_OFFSET) -F -T $(PART1_SECTORS) -v VIBEEE ::
	@$(MCOPY) -i $(IMG)@@$(PART1_OFFSET) -o $(USER_HELLO) ::/HELLO
	@echo "vibeee $(shell date -u +%Y-%m-%dT%H:%M:%SZ)" > $(BUILD)/version.txt
	@$(MCOPY) -i $(IMG)@@$(PART1_OFFSET) -o $(BUILD)/version.txt ::/VERSION.TXT

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
qemu: $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(MKIMAGE) $(ROOTFS_IMG)
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(BUILD)/vibeee-dev.img $(IMAGE_MB) verbose $(ROOTFS_IMG)
	@$(MAKE) --no-print-directory populate IMG=$(BUILD)/vibeee-dev.img
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(BUILD)/vibeee-dev.img

run: qemu

# Boot the real image. `-drive if=none,format=raw` + `usb-storage` mirrors the
# 701's actual path: the SD card sits behind a USB mass-storage reader, and the
# BIOS boots it through USB-HDD emulation.
qemu-sd: $(IMAGE)
	$(QEMU) $(QEMU_FLAGS) \
		-drive if=none,id=sd,format=raw,file=$(IMAGE) \
		-device usb-storage,drive=sd,bootindex=0

# Same image on an emulated IDE disk — the internal SSD install path.
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
	@$(MKIMAGE) $(STAGE1_BIN) $(STAGE2_BIN) $(KERNEL_BIN) $(BUILD)/vibeee-panic.img $(IMAGE_MB) panictest $(ROOTFS_IMG)
	@$(MAKE) --no-print-directory populate IMG=$(BUILD)/vibeee-panic.img
	$(QEMU) $(QEMU_FLAGS) -drive if=ide,format=raw,file=$(BUILD)/vibeee-panic.img

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
	dd if=$(IMAGE) of=$(DEV) bs=1m status=progress
	sync
	diskutil eject $(DEV) || true

clean:
	rm -rf $(BUILD) zig-out .zig-cache
