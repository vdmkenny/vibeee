#!/bin/sh
# The part of `make check-all` that looks at what was built: the volumes hold
# what a boot needs, and the machine boots headless to a ready desktop,
# answers a probe, keeps a setting across a reboot, and neither panics nor
# trips the boot watchdog on the way. The card image boots the way the 701
# boots it, through a USB reader, and its volumes arrive and keep a setting
# across that path too.
#
# Run from the Makefile, which passes the image paths and partition offsets
# so that the layout is written in one place. The boots go through
# qemu-shot.sh, whose serial transcript is what is read: a line scrolled off
# a screenshot is still on it.
set -e
cd "$(dirname "$0")/.."

: "${BUILD:?}" "${ROOTFS_IMG:?}" "${DEV_IMAGE:?}" "${IMAGE:?}" "${CFG_OFFSET:?}" "${HOME_OFFSET:?}"
: "${QEMU_CPU:=pentium3,+sse2,+pae,+nx,-sse3}"

fail() { printf 'check-all: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
# The transcript carries the console's colours, cursor moves and carriage
# returns; the checks read the words.
plain() { sed -E "s/$(printf '\033')\[[0-9;?]*[a-zA-Z]//g; s/$(printf '\r')$//" "$1"; }

step "volumes"
for path in etc/services etc/disabled etc/open.cfg etc/power.cfg bin/init bin/vsh; do
    mdir -i "$ROOTFS_IMG" -b "::/$path" >/dev/null 2>&1 || fail "the root filesystem has no /$path"
done
mdir -i "$DEV_IMAGE@@$CFG_OFFSET" -b ::/ >/dev/null 2>&1 || fail "the settings volume does not mount"
mdir -i "$DEV_IMAGE@@$HOME_OFFSET" -b ::/readme.txt >/dev/null 2>&1 || fail "the home volume has no readme"
echo "root, settings and home volumes hold what a boot needs"

boot() {
    out="$1"; shift
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -drive if=ide,format=raw,file="$DEV_IMAGE" >/dev/null 2>&1 \
        || fail "the emulator did not run (see ${out%.png}.log)"
}

# The card image behind a USB reader, as the 701 boots it. A copy, because
# the boot writes to it and the image itself is what `make sd` flashes.
SD_COPY=$BUILD/check-sd.img
bootsd() {
    out="$1"; shift
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -usb -drive if=none,id=sd,format=raw,file="$SD_COPY" \
        -device usb-storage,drive=sd,bootindex=0 >/dev/null 2>&1 \
        || fail "the emulator did not run (see ${out%.png}.log)"
}

step "first boot: ready, probed, services up, a setting written"
LOG1=$BUILD/check-boot1.log
boot "$BUILD/check-boot1.png" -w 30 -p 3 -s 2 -t "probe
svc
cfg set power.dim_after 5m"
plain "$LOG1" > "$LOG1.txt"
grep -q "boot reported done" "$LOG1.txt" || fail "the boot never reported done (see $LOG1)"
! grep -qi "panic" "$LOG1.txt" || fail "the kernel panicked (see $LOG1)"
! grep -q "watchdog" "$LOG1.txt" || fail "the boot watchdog fired (see $LOG1)"
grep -Eq '([0-9]+) of \1 refused as they should be' "$LOG1.txt" || fail "the probe found a boundary that gives (see $LOG1)"
grep -q "nothing left behind" "$LOG1.txt" || fail "the probe found handles leaking (see $LOG1)"
! grep -Eq '^ *fail ' "$LOG1.txt" || fail "a self-test failed (see $LOG1)"
grep -Eq '^cfgd +up' "$LOG1.txt" || fail "svc does not show cfgd up (see $LOG1)"
! grep -Eq '^[a-z0-9_-]+ +failed' "$LOG1.txt" || fail "a service failed (see $LOG1)"
echo "boot done, every refusal held, nothing leaked, services up"

step "second boot: the setting kept, a service stopped on request"
LOG2=$BUILD/check-boot2.log
boot "$BUILD/check-boot2.png" -w 30 -p 2 -s 1 -t "cfg get power.dim_after
cfg reset power.dim_after
svc stop cfgd
svc"
plain "$LOG2" > "$LOG2.txt"
grep -q "^5m" "$LOG2.txt" || fail "power.dim_after did not survive the reboot (see $LOG2)"
grep -Eq '^cfgd +stopped' "$LOG2.txt" || fail "cfgd did not stop when asked (see $LOG2)"
! grep -Eq "did not stop when asked|cannot be asked to stop" "$LOG2.txt" || fail "a service had to be ended rather than asked (see $LOG2)"
echo "a setting written before a reboot is read back after it, and a service asked to stop went"

step "the card through a USB reader: its volumes arrive, and a setting written"
cp "$IMAGE" "$SD_COPY"
LOG3=$BUILD/check-boot3.log
bootsd "$BUILD/check-boot3.png" -w 30 -d 6 -p 3 -s 2 -t "disk
cfg set power.dim_after 5m"
plain "$LOG3" > "$LOG3.txt"
! grep -qi "panic" "$LOG3.txt" || fail "the kernel panicked on the USB boot (see $LOG3)"
grep -Eq 'usb0p[0-9]+ .* /cfg$' "$LOG3.txt" || fail "the settings volume did not arrive over USB (see $LOG3)"
grep -Eq 'usb0p[0-9]+ .* /home$' "$LOG3.txt" || fail "the home volume did not arrive over USB (see $LOG3)"
echo "the card booted through the reader, and its volumes took their places"

step "the card again: the setting kept on its own volume"
LOG4=$BUILD/check-boot4.log
bootsd "$BUILD/check-boot4.png" -w 30 -d 6 -p 2 -s 1 -t "cfg get power.dim_after"
plain "$LOG4" > "$LOG4.txt"
grep -q "^5m" "$LOG4.txt" || fail "power.dim_after did not survive a reboot of the card (see $LOG4)"
echo "a setting written to the card is read back from it"

printf '\ncheck-all: everything holds\n'
