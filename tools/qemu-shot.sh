#!/bin/sh
# Boot a target in QEMU, optionally type at it, capture the screen as PNG.
#
# Exists because "screenshot the running kernel" is the main way to see what
# happened on a machine with no serial port, and it should be one command.
#
#   tools/qemu-shot.sh <out.png> [-t "text to type"] [-m "monitor commands"]
#                      [-w seconds] [-d seconds] [-p seconds] [-s seconds]
#                      [-- qemu args]
#
# `-w` is how long to wait for the boot to report itself done before typing;
# the wait ends as soon as it does. `-d` is how much longer to wait after
# that, for a machine whose removable storage arrives once the boot has
# reported: a volume is mounted when the bus finds it, which is after.
#
# `-p` is the pause after each typed line, for a line whose command takes
# longer than a moment: keys typed while it runs are not read by the shell.
#
# `-m` sends raw QEMU monitor commands after the typing, one per line, which is
# how the pointing device is exercised: `mouse_move dx dy`, `mouse_button mask`
# with 1 left, 2 middle, 4 right.
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
# How long to leave the machine alone before the shot. A program that reads
# a large file has not drawn anything yet a second after being asked to run,
# and a screenshot taken then says nothing about whether it works.
SETTLE=1
MONITOR=""
# The longest the machine is given to report a finished boot before it is
# typed at anyway. A boot that never reports is a boot worth screenshotting.
BOOT_WAIT=3
# What a finished boot says. Every image runs the same init.
READY="boot reported done"
# How long the machine is left alone after that. The prompt is drawn before
# it, so this is only for what is still arriving as the boot reports.
AFTER_READY=0.5
PAUSE=0.6

while [ $# -gt 0 ]; do
    case "$1" in
        -t) TYPE="$2"; shift 2 ;;
        -m) MONITOR="$2"; shift 2 ;;
        -w) BOOT_WAIT="$2"; shift 2 ;;
        -d) AFTER_READY="$2"; shift 2 ;;
        -p) PAUSE="$2"; shift 2 ;;
        -s) SETTLE="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

SOCK=$(mktemp -u /tmp/vibeee-mon.XXXXXX)
PPM=$(mktemp -u /tmp/vibeee-shot.XXXXXX).ppm

# The console is mirrored to the serial port (platform.zig), so the whole boot
# log and every command's output land here as text. The target machine has no
# serial port, which is why the QR panic screen exists, but QEMU does: reading
# a transcript beats reading a screenshot for everything except what the screen
# itself looks like.
LOG="${OUT%.png}.log"

qemu-system-i386 -machine pc -cpu "$QEMU_CPU" -m "$QEMU_MEM" -no-reboot \
    -display none -vga none -device VGA,edid=on,xres=800,yres=600 -serial "file:$LOG" \
    -monitor "unix:$SOCK,server,nowait" "$@" &
QPID=$!
# Waited for as well as killed, and waited for by asking whether it is still
# there rather than by `wait`: the next boot opens the same disk image, and
# QEMU holds that image's write lock until it has actually gone. A boot that
# starts while the last one still holds the lock does not start at all.
gone() {
    kill "$QPID" 2>/dev/null || true
    i=0
    while kill -0 "$QPID" 2>/dev/null && [ $i -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    rm -f "$SOCK"
}
trap gone EXIT

# Wait for the monitor socket rather than sleeping a guessed interval. Its
# never appearing means the emulator never came up, which is worth saying
# now and by name: waited out instead, it surfaces half a minute later as a
# missing screenshot, which is the one thing it is not about.
i=0; while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
if [ ! -S "$SOCK" ]; then
    echo "the emulator did not start: it may still be holding a disk image open" >&2
    exit 1
fi

# And for the machine, on the same principle. A key sent before the shell
# reads it is dropped by the keyboard controller, and the command it belonged
# to reads afterwards like one that ran and printed nothing. The boot says
# when it is done on the serial line the rest of the transcript arrives on,
# so the wait ends on that; `-w` is only how long to wait for it.
ticks=$(awk -v s="$BOOT_WAIT" 'BEGIN { printf "%d", (s * 10) + 0.5 }')
i=0
while [ $i -lt "$ticks" ]; do
    grep -q "$READY" "$LOG" 2>/dev/null && break
    sleep 0.1
    i=$((i+1))
done
sleep "$AFTER_READY"

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
        "'") echo apostrophe ;;
        '[') echo bracket_left ;;
        ']') echo bracket_right ;;
        '\\') echo backslash ;;
        # Shifted punctuation. The monitor speaks scancodes, so anything
        # needing shift on a US layout has to say so; an unmapped character is
        # dropped silently, which makes a test line run as something else.
        '>') echo shift-dot ;;
        '<') echo shift-comma ;;
        '|') echo shift-backslash ;;
        '_') echo shift-minus ;;
        '+') echo shift-equal ;;
        ':') echo shift-semicolon ;;
        '"') echo shift-apostrophe ;;
        '?') echo shift-slash ;;
        '!') echo shift-1 ;;
        '@') echo shift-2 ;;
        '#') echo shift-3 ;;
        '$') echo shift-4 ;;
        '%') echo shift-5 ;;
        '^') echo shift-6 ;;
        '&') echo shift-7 ;;
        '*') echo shift-8 ;;
        '(') echo shift-9 ;;
        ')') echo shift-0 ;;
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
        sleep "$PAUSE"
    done
fi

if [ -n "$MONITOR" ]; then
    printf '%s\n' "$MONITOR" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        monitor "$line"
        sleep 0.3
    done
fi

sleep "$SETTLE"
monitor "screendump $PPM"

# The emulator writes the screendump in its own time, and under load that is
# not within any particular second. Waited for rather than slept on, and
# waited for twice over: the file appears before it has finished being
# written, so a size that has stopped changing is what says it is done.
waited=0
while [ "$waited" -lt 100 ]; do
    if [ -s "$PPM" ]; then
        was=$(wc -c < "$PPM")
        sleep 0.1
        [ "$was" = "$(wc -c < "$PPM")" ] && break
    else
        # The monitor command is sent over a socket and its delivery is
        # not guaranteed: a screendump that was never heard never arrives,
        # however long it is waited for. So it is asked for again while it
        # is waited for, which costs nothing when the first was heard.
        if [ $((waited % 10)) -eq 9 ]; then monitor "screendump $PPM"; fi
        sleep 0.1
    fi
    waited=$((waited + 1))
done
[ -s "$PPM" ] || { echo "no screendump: guest may have died"; exit 1; }
if command -v sips >/dev/null 2>&1; then
    sips -s format png "$PPM" --out "$OUT" >/dev/null
elif command -v magick >/dev/null 2>&1; then
    magick "$PPM" "$OUT"
else
    convert "$PPM" "$OUT"
fi
rm -f "$PPM"
echo "$OUT"
# Named only when there is one, and not as the script's own answer: a
# missing log is not a failed run, and this is the last line of the script.
if [ -s "$LOG" ]; then echo "$LOG"; fi
