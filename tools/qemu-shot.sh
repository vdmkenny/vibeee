#!/bin/sh
# Boot a target in QEMU, capture the screen, and convert it to PNG.
# Exists because "screenshot the running kernel" is the main way to see what
# happened on a machine with no serial port, and it should be one command.
#
#   tools/qemu-shot.sh <out.png> [-- extra qemu args...]
set -e
OUT="$1"; shift
[ "$1" = "--" ] && shift
SOCK=$(mktemp -u /tmp/vibeee-mon.XXXXXX)
PPM=$(mktemp -u /tmp/vibeee-shot.XXXXXX).ppm

qemu-system-i386 -machine pc -cpu pentium2 -m 512M -no-reboot \
    -display none -vga std -monitor "unix:$SOCK,server,nowait" "$@" &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT

# Wait for the monitor socket rather than sleeping a guessed interval.
i=0; while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
sleep 3
printf 'screendump %s\n' "$PPM" | nc -U "$SOCK" >/dev/null 2>&1
sleep 1
[ -f "$PPM" ] || { echo "no screendump: guest may have died"; exit 1; }
sips -s format png "$PPM" --out "$OUT" >/dev/null
rm -f "$PPM" "$SOCK"
echo "$OUT"
