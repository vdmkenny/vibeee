#!/bin/sh
# The part of `make check-all` that looks at what was built: the volumes hold
# what a boot needs, and the machine boots headless to a ready desktop,
# answers a probe, keeps a setting across a reboot, and neither panics nor
# trips the boot watchdog on the way.
#
# Run from the Makefile, which passes the image paths and partition offsets
# so that the layout is written in one place. The boots go through
# qemu-shot.sh, whose serial transcript is what is read: a line scrolled off
# a screenshot is still on it.
set -e
cd "$(dirname "$0")/.."

: "${BUILD:?}" "${ROOTFS_IMG:?}" "${DEV_IMAGE:?}" "${CFG_OFFSET:?}" "${HOME_OFFSET:?}"
: "${QEMU_CPU:=pentium3,+sse2,+pae,+nx,-sse3}"

fail() { printf 'check-all: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
# The transcript carries the console's colours and cursor moves; the checks
# read the words.
plain() { sed -E "s/$(printf '\033')\[[0-9;?]*[a-zA-Z]//g" "$1"; }

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

step "first boot: ready, probed, services up, a setting written"
LOG1=$BUILD/check-boot1.log
boot "$BUILD/check-boot1.png" -w 4 -p 3 -s 2 -t "probe
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
boot "$BUILD/check-boot2.png" -w 4 -p 2 -s 1 -t "cfg get power.dim_after
cfg reset power.dim_after
svc stop cfgd
svc"
plain "$LOG2" > "$LOG2.txt"
grep -q "^5m" "$LOG2.txt" || fail "power.dim_after did not survive the reboot (see $LOG2)"
grep -Eq '^cfgd +stopped' "$LOG2.txt" || fail "cfgd did not stop when asked (see $LOG2)"
! grep -Eq "did not stop when asked|cannot be asked to stop" "$LOG2.txt" || fail "a service had to be ended rather than asked (see $LOG2)"
echo "a setting written before a reboot is read back after it, and a service asked to stop went"

printf '\ncheck-all: everything holds\n'
