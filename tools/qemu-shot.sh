#!/bin/sh
# Boot a target in QEMU, optionally type at it, capture the screen as PNG.
#
# Exists because "screenshot the running kernel" is the main way to see what
# happened on a machine with no serial port, and it should be one command.
#
#   tools/qemu-shot.sh <out.png> [-t "text to type"] [-w seconds] [-- qemu args]
#
# The CPU model comes from QEMU_CPU, which the Makefile exports. It must match
# the target: emulating something less capable than the real Celeron M makes
# user code fault on instructions the hardware would have run, which looks
# exactly like a kernel bug and is not one.
set -e

: "${QEMU_CPU:=pentium3,+sse2,+pae,+nx,-sse3}"
: "${QEMU_MEM:=512M}"

OUT="$1"; shift
TYPE=""
BOOT_WAIT=3

while [ $# -gt 0 ]; do
    case "$1" in
        -t) TYPE="$2"; shift 2 ;;
        -w) BOOT_WAIT="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

SOCK=$(mktemp -u /tmp/vibeee-mon.XXXXXX)
PPM=$(mktemp -u /tmp/vibeee-shot.XXXXXX).ppm

qemu-system-i386 -machine pc -cpu "$QEMU_CPU" -m "$QEMU_MEM" -no-reboot \
    -display none -vga std -monitor "unix:$SOCK,server,nowait" "$@" &
QPID=$!
trap 'kill $QPID 2>/dev/null || true; rm -f "$SOCK"' EXIT

# Wait for the monitor socket rather than sleeping a guessed interval.
i=0; while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
sleep "$BOOT_WAIT"

monitor() { printf '%s\n' "$1" | nc -U "$SOCK" >/dev/null 2>&1 || true; }

# Translate a character to the QEMU monitor's key name. The monitor speaks
# scancode names, not text, so anything typed has to be spelled out.
keyname() {
    case "$1" in
        ' ') echo spc ;;
        '/') echo slash ;;
        '-') echo minus ;;
        '.') echo dot ;;
        ',') echo comma ;;
        '=') echo equal ;;
        ';') echo semicolon ;;
        [a-z0-9]) echo "$1" ;;
        [A-Z]) echo "shift-$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
        *) echo "" ;;
    esac
}

# Each line of TYPE is typed and then entered. Keys go one at a time with a
# pause: the guest's keyboard interrupt has to drain the controller between
# them, and a burst gets coalesced into missing characters.
if [ -n "$TYPE" ]; then
    printf '%s\n' "$TYPE" | while IFS= read -r line; do
        i=1
        while [ $i -le ${#line} ]; do
            ch=$(printf '%s' "$line" | cut -c$i)
            key=$(keyname "$ch")
            [ -n "$key" ] && monitor "sendkey $key"
            sleep 0.06
            i=$((i+1))
        done
        monitor "sendkey ret"
        sleep 0.6
    done
    sleep 1
fi

monitor "screendump $PPM"
sleep 1
[ -f "$PPM" ] || { echo "no screendump: guest may have died"; exit 1; }
sips -s format png "$PPM" --out "$OUT" >/dev/null
rm -f "$PPM"
echo "$OUT"
