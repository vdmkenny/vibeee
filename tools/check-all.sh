#!/bin/sh
# The part of `make check-all` that looks at what was built: the volumes hold
# what a boot needs, and the machine boots headless to a ready desktop,
# answers a probe, keeps a setting across a reboot, and neither panics nor
# trips the boot watchdog on the way. The card image boots the way the 701
# boots it, through a USB reader, and its volumes arrive over that path.
#
# Run from the Makefile, which passes the image paths and partition offsets
# so that the layout is written in one place. The boots go through
# qemu-shot.sh, whose serial transcript is what is read: a line scrolled off
# a screenshot is still on it.
set -e
cd "$(dirname "$0")/.."

: "${BUILD:?}" "${ROOTFS_IMG:?}" "${DEV_IMAGE:?}" "${IMAGE:?}" "${CFG_OFFSET:?}" "${HOME_OFFSET:?}"
: "${QEMU_CPU:=pentium3,+sse2,+pae,+nx,-sse3}"

# Nothing from a previous run survives into this one. A boot that fails to
# produce a transcript leaves the last run's sitting there, and a stale
# transcript read as this run's evidence is worse than no evidence: it says
# the thing worked.
rm -f "$BUILD"/check-boot*.png "$BUILD"/check-boot*.log "$BUILD"/check-boot*.log.txt
rm -f "$BUILD"/check-net-*.png "$BUILD"/check-net-*.log "$BUILD"/check-net-*.log.txt
rm -f "$BUILD"/check-serial.png "$BUILD"/check-serial.log "$BUILD"/check-serial.log.txt "$BUILD"/check-serial.out
rm -f "$BUILD"/check-console.png "$BUILD"/check-console.log "$BUILD"/check-console.log.txt "$BUILD"/check-console.out
rm -f "$BUILD"/check-bus.png "$BUILD"/check-bus.log "$BUILD"/check-bus.log.txt "$BUILD"/check-stick.img
rm -f "$BUILD"/check-cut*.png "$BUILD"/check-cut*.log "$BUILD"/check-cut*.log.txt
rm -f "$BUILD"/check-grow*.png "$BUILD"/check-grow*.log "$BUILD"/check-grow*.log.txt "$BUILD"/check-grow.img

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

# Only the chatter is discarded, never the complaint: the emulator says on
# its error output why it would not start, and a run that throws that away
# leaves nothing behind but the fact that it did not.
boot() {
    out="$1"; shift
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -drive if=ide,format=raw,file="$DEV_IMAGE" >/dev/null \
        || fail "the emulator did not run (see ${out%.png}.log)"
}

# The same boot behind an adapter the default machine does not have, which is
# how one driver at a time is put in front of real traffic.
bootnet() {
    out="$1"; model="$2"; shift 2
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -drive if=ide,format=raw,file="$DEV_IMAGE" \
        -netdev user,id=net0 -device "$model,netdev=net0" >/dev/null \
        || fail "the emulator did not run (see ${out%.png}.log)"
}

# The card image behind a USB reader, as the 701 boots it. A copy, because
# the boot writes to it and the image itself is what `make sd` flashes.
SD_COPY=$BUILD/check-sd.img
bootsd() {
    out="$1"; shift
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -usb -drive if=none,id=sd,format=raw,file="$SD_COPY" \
        -device usb-storage,drive=sd,bootindex=0 >/dev/null \
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

step "power cut: the volume is found dirty, checked and repaired"
# A write marks the volume dirty until unmount. Killing the emulator is a power
# cut: the next boot must find the mark, check the volume and keep its data.
LOGCUT1=$BUILD/check-cut1.log
boot "$BUILD/check-cut1.png" -w 30 -p 2 -s 1 -t "echo written-before-the-cut > /home/cut.txt
cat /home/cut.txt"
plain "$LOGCUT1" > "$LOGCUT1.txt"
grep -q "written-before-the-cut" "$LOGCUT1.txt" || fail "the file was not written before the cut (see $LOGCUT1)"

# Killed without unmount or shutdown.
LOGCUT2=$BUILD/check-cut2.log
boot "$BUILD/check-cut2.png" -w 30 -p 2 -s 1 -t "cat /home/cut.txt
check /home"
plain "$LOGCUT2" > "$LOGCUT2.txt"
grep -q "/home was not unmounted" "$LOGCUT2.txt" ||
    fail "a volume cut off mid-write was mounted as though it were clean (see $LOGCUT2)"
grep -q "written-before-the-cut" "$LOGCUT2.txt" ||
    fail "what was written before the cut did not survive it (see $LOGCUT2)"
grep -q "cross-linked" "$LOGCUT2.txt" &&
    fail "the check found cross-linked clusters on an undamaged volume (see $LOGCUT2)"
grep -q "/home: clean" "$LOGCUT2.txt" ||
    fail "the volume was still not sound after being checked (see $LOGCUT2)"

# After the check, the next boot finds the volume clean.
LOGCUT3=$BUILD/check-cut3.log
boot "$BUILD/check-cut3.png" -w 30 -p 2 -s 1 -t "unmount /home"
plain "$LOGCUT3" > "$LOGCUT3.txt"
! grep -q "/home was not unmounted" "$LOGCUT3.txt" ||
    fail "a volume checked on the last boot was checked again on this one (see $LOGCUT3)"
echo "a volume cut off mid-write says so, is checked, keeps what was written, and settles"

step "a card larger than the image: grow into it, and format a volume"
# The image on a 256 MiB card. `grow` must extend the /home partition and its
# filesystem and keep the data; `format` must produce a volume that checks clean.
GROWIMG=$BUILD/check-grow.img
cp "$DEV_IMAGE" "$GROWIMG"
dd if=/dev/zero bs=1m count=0 seek=256 of="$GROWIMG" >/dev/null 2>&1

LOGGROW=$BUILD/check-grow.log
QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$BUILD/check-grow.png" -w 30 -p 4 -s 6 \
    -t "echo written-before-the-grow > /home/keep.txt
unmount /home
grow hd0p3
hd0p3
mount hd0p3 /home
cat /home/keep.txt
check /home
unmount /media/hd0p1
format hd0p1
hd0p1
mount hd0p1 /media/hd0p1
check /media/hd0p1" \
    -- -drive if=ide,format=raw,file="$GROWIMG" >/dev/null ||
    fail "the emulator did not run (see $LOGGROW)"
plain "$LOGGROW" > "$LOGGROW.txt"
! grep -qi "panic\|STOPPED" "$LOGGROW.txt" || fail "the kernel stopped growing or formatting (see $LOGGROW)"

# Partition extended to the card, filesystem extended to the partition.
grep -q "covers 425984 sectors, was 32768" "$LOGGROW.txt" ||
    fail "the partition was not extended over the rest of the card (see $LOGGROW)"
grep -Eq "to [0-9]{6,} clusters" "$LOGGROW.txt" ||
    fail "the filesystem did not grow with its partition (see $LOGGROW)"
grep -q "written-before-the-grow" "$LOGGROW.txt" ||
    fail "what was on the volume did not survive the grow (see $LOGGROW)"
# Two clean checks: the grown volume and the formatted one.
[ "$(grep -Ec ": clean$" "$LOGGROW.txt")" -ge 2 ] ||
    fail "a grown or freshly formatted volume was not sound (see $LOGGROW)"
grep -q "hd0p1: formatted" "$LOGGROW.txt" ||
    fail "the volume was not formatted (see $LOGGROW)"
echo "a card larger than its image grows into itself, and a volume can be made afresh"

step "the wire: a leased address and an echo answered, on every adapter QEMU has"
# The drivers the emulator can stand in for, each as QEMU's model and the
# driver that takes it: the PRO/100 as its oldest part and as the one inside
# the ICH. The Attansic and the Atheros have no model, so they are only ever
# proven on the machine that has them.
for adapter in e1000:e1000 rtl8139:rtl8139 i82557b:e100 i82801:e100; do
    model=${adapter%%:*}
    driver=${adapter#*:}
    LOGNET=$BUILD/check-net-$model.log
    bootnet "$BUILD/check-net-$model.png" "$model" -w 30 -d 12 -p 3 -s 10 \
        -t "net
ping 10.0.2.2"
    plain "$LOGNET" > "$LOGNET.txt"
    grep -q "boot reported done" "$LOGNET.txt" || fail "the boot never reported done (see $LOGNET)"
    ! grep -qi "panic" "$LOGNET.txt" || fail "$model: the kernel panicked (see $LOGNET)"
    grep -Eq "^$driver +up " "$LOGNET.txt" || fail "$model: the adapter did not come up (see $LOGNET)"
    grep -Eq "addr +10\.0\.2\.[0-9]+" "$LOGNET.txt" || fail "$model: no address was leased (see $LOGNET)"
    grep -q "answering for" "$LOGNET.txt" || fail "$model: nothing answered its ARP (see $LOGNET)"
    grep -Eq "[0-9]+ of [0-9]+ answered" "$LOGNET.txt" || fail "$model: no echo came back (see $LOGNET)"
    ! grep -q "0 of" "$LOGNET.txt" || fail "$model: every echo was lost (see $LOGNET)"
    echo "$model: up, leased, answering"
done
echo "every modelled adapter carries traffic end to end"

# A serial adapter on a controller the default machine does not have. The
# emulator's cable is the vendor part, so this proves that driver; the class
# driver has no emulated device anywhere and is proven only by its tests.
#
# The chardev is a file because the emulator's adapter attaches to the bus
# only while its backend is open, and a file always is. It carries what the
# guest sends, which is the half of the conversation a gate can read back.
bootserial() {
    out="$1"; shift
    QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$out" "$@" \
        -- -drive if=ide,format=raw,file="$DEV_IMAGE" \
        -device piix3-usb-uhci,id=uh -chardev file,id=sport,path="$SER_WIRE" \
        -device usb-serial,bus=uh.0,chardev=sport >/dev/null \
        || fail "the emulator did not run (see ${out%.png}.log)"
}

step "a serial adapter: named, set, and carrying what is typed"
SER_WIRE=$BUILD/check-serial.out
LOGSER=$BUILD/check-serial.log
bootserial "$BUILD/check-serial.png" -w 30 -p 3 -s 3 -t "ser ser0 set 9600 8N1
ser
ser ser0
over the wire"
plain "$LOGSER" > "$LOGSER.txt"
! grep -qi "panic" "$LOGSER.txt" || fail "the kernel panicked with an adapter plugged in (see $LOGSER)"
grep -Eq '^ser0 +0403:6001' "$LOGSER.txt" || fail "the adapter was not named as a port (see $LOGSER)"
grep -Eq '^ser0 +0403:6001 +9600 8N1' "$LOGSER.txt" || fail "the line was not set (see $LOGSER)"
grep -q "F10 leaves" "$LOGSER.txt" || fail "no terminal opened on the port (see $LOGSER)"
grep -q "over the wire" "$SER_WIRE" || fail "what was typed did not reach the wire (see $SER_WIRE)"
echo "the adapter enumerates, takes a line, and carries what is typed to the far end"

step "the machine's record, out of a serial port"
# The one thing this machine has never had. Named at the shell rather than
# shipped set, because a machine with nothing plugged in should not be
# looking for a port: what is checked is that naming one sends the whole
# record down it and keeps sending.
CON_WIRE=$BUILD/check-console.out
LOGCON=$BUILD/check-console.log
QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$BUILD/check-console.png" -w 30 -p 3 -s 6 \
    -t "cfg set log.console ser0" \
    -- -drive if=ide,format=raw,file="$DEV_IMAGE" \
    -device piix3-usb-uhci,id=uh -chardev file,id=sp,path="$CON_WIRE" \
    -device usb-serial,bus=uh.0,chardev=sp >/dev/null \
    || fail "the emulator did not run (see ${LOGCON})"
plain "$LOGCON" > "$LOGCON.txt"
! grep -qi "panic" "$LOGCON.txt" || fail "the kernel panicked with a console port named (see $LOGCON)"
[ -s "$CON_WIRE" ] || fail "nothing came out of the console port (see $CON_WIRE)"
# The first line of the boot proves the whole record went, not just what
# was said after the port opened.
grep -q "keeping time by the firmware counter" "$CON_WIRE" ||
    fail "the record's opening lines did not reach the wire (see $CON_WIRE)"
# And this one was written after the port was open, so it can only have
# arrived by being followed.
grep -q "the record is going out of ser0" "$CON_WIRE" ||
    fail "the record stopped at what was already there (see $CON_WIRE)"
echo "the whole record reached the wire, and went on reaching it"

step "a disk behind a hub, across the bus being put down and brought back"
# What a machine waking from sleep will ask for. Behind a hub because
# that is where the bus's own bookkeeping is hardest: a hub's ports are
# the hub driver's to watch, and the addresses are handed out afresh, so
# a volume followed by address rather than by where its disk sits would
# come back mounted over the wrong one.
STICK=$BUILD/check-stick.img
dd if=/dev/zero of="$STICK" bs=1m count=16 >/dev/null 2>&1
mformat -i "$STICK" -F :: || fail "cannot make a stick to test with"
echo "the stick still reads" > "$BUILD/check-stick.txt"
mcopy -i "$STICK" "$BUILD/check-stick.txt" ::/hello.txt || fail "cannot write to the test stick"

LOGBUS=$BUILD/check-bus.log
QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$BUILD/check-bus.png" -w 30 -p 4 -s 4 \
    -t "cat /media/usb0/hello.txt
usb rebuild
cat /media/usb0/hello.txt" \
    -- -drive if=ide,format=raw,file="$DEV_IMAGE" \
    -device piix3-usb-uhci,id=uh -device usb-hub,bus=uh.0,port=1 \
    -drive if=none,id=st,format=raw,file="$STICK" \
    -device usb-storage,bus=uh.0,port=1.2,drive=st,id=stick >/dev/null \
    || fail "the emulator did not run (see $LOGBUS)"
plain "$LOGBUS" > "$LOGBUS.txt"
! grep -qi "panic" "$LOGBUS.txt" || fail "the kernel panicked rebuilding the bus (see $LOGBUS)"
# A disk plugged into a hub is offered to the kernel at all, which is what
# the walk after the class drivers is for.
grep -q "the bus is back with 2 devices" "$LOGBUS.txt" ||
    fail "the bus did not come back with the hub and the disk (see $LOGBUS)"
# Twice: once before the bus went down and once after, from a mount that
# was never dropped and still reaches the disk it was made for.
[ "$(grep -c "the stick still reads" "$LOGBUS.txt")" -ge 2 ] ||
    fail "the mount did not survive the bus being rebuilt (see $LOGBUS)"
echo "the bus went down and came back, and the disk behind the hub kept its mount"

step "the machine asleep and awake again, with its screen, its keys and its disk"
# The whole suspend path, which the emulator can run because its display
# adapter has a backend: a machine whose screen could not be set a mode again
# refuses to sleep at all, so without that this would only ever run on the
# hardware it is hardest to run on.
#
# Typed at twice, once before the sleep and once after, and the second time
# through the monitor because the keys of a line typed while the machine is
# asleep are simply not there to be read.
#
# Both waits are on what the machine says rather than on a length of time.
# Waking one that has not finished going to sleep does nothing at all, and a
# letter sent while it is still putting itself back is a letter gone: the
# keyboard controller holds one byte, and the whole resume runs with
# interrupts off. Neither is a fixed number of seconds on a loaded host.
LOGS3=$BUILD/check-suspend.log
QEMU_CPU="$QEMU_CPU" tools/qemu-shot.sh "$BUILD/check-suspend.png" -w 30 -p 3 -s 6 \
    -t "disk
suspend" \
    -m "wait-for sleeping
system_wakeup
wait-for awake
sendkey d
sendkey i
sendkey s
sendkey k
sendkey ret" \
    -- -drive if=ide,format=raw,file="$DEV_IMAGE" >/dev/null \
    || fail "the emulator did not run (see $LOGS3)"
plain "$LOGS3" > "$LOGS3.txt"
! grep -qi "panic" "$LOGS3.txt" || fail "the kernel panicked across the sleep (see $LOGS3)"
grep -q "suspend sleeping" "$LOGS3.txt" || fail "the machine was never asked to sleep (see $LOGS3)"
grep -q "suspend awake" "$LOGS3.txt" || fail "the machine did not come back (see $LOGS3)"
# The screen: set again by a driver, because what firmware set was set by code
# that no longer runs.
grep -q "native, panel fitter off" "$LOGS3.txt" || fail "the display did not come back (see $LOGS3)"
# The input controller, which is not on a bus and comes back with its
# interrupt off and its translation lost.
grep -q "i8042 ready" "$LOGS3.txt" || fail "the keyboard controller did not come back (see $LOGS3)"
# The adapters, which the platform service asks their driver to take again.
[ "$(grep -c "link 1000 Mbit" "$LOGS3.txt")" -ge 2 ] ||
    fail "the network adapter was not taken again after the wake (see $LOGS3)"
# And the proof that the keys reach a shell and the volumes are still there:
# the same listing before the sleep and after it.
[ "$(grep -Ec '^hd0 +64 MiB +read-write' "$LOGS3.txt")" -ge 2 ] ||
    fail "the machine did not answer the keyboard after waking (see $LOGS3)"
echo "the machine slept, woke, and came back with its screen, its keys, its disk and its wire"

step "the card through a USB reader: its volumes arrive"
cp "$IMAGE" "$SD_COPY"
LOG3=$BUILD/check-boot3.log
bootsd "$BUILD/check-boot3.png" -w 30 -d 6 -p 3 -s 2 -t "disk"
plain "$LOG3" > "$LOG3.txt"
! grep -qi "panic" "$LOG3.txt" || fail "the kernel panicked on the USB boot (see $LOG3)"
grep -Eq 'usb0p[0-9]+ .* /cfg$' "$LOG3.txt" || fail "the settings volume did not arrive over USB (see $LOG3)"
grep -Eq 'usb0p[0-9]+ .* /home$' "$LOG3.txt" || fail "the home volume did not arrive over USB (see $LOG3)"
echo "the card booted through the reader, and its volumes took their places"

printf '\ncheck-all: everything holds\n'
