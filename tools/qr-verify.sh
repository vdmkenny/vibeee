#!/bin/sh
# Diff our QR encoder against libqrencode.
#
# libqrencode picks its mask by penalty score and gives no way to pin it, so we
# sweep all eight of ours and require an exact match on one. An exact match
# validates the whole pipeline at once: bitstream, padding, Reed-Solomon,
# function patterns, data placement, masking and format info.
set -e

QRDUMP=${QRDUMP:-build/qrdump}

# Not skipped when qrencode is missing. A panic report is the only thing this
# machine can say for itself when nothing else works, and its encoder is
# verified against a reference or not at all: a skip here reads as a pass and
# the one diagnostic that has to be right goes unchecked. SKIP_QR=1 is the way
# to say you meant to leave it out.
if ! command -v qrencode >/dev/null; then
    if [ "${SKIP_QR:-0}" = "1" ]; then
        echo "qrencode not installed; skipping (SKIP_QR=1)"
        exit 0
    fi
    echo "qrencode not installed: install it, or set SKIP_QR=1 to skip" >&2
    exit 1
fi

fail=0
check() {
    payload="$1"; version="$2"
    qrencode -t ASCII -l L -v "$version" --strict-version -m 0 -8 -o - "$payload" \
        | sed -e 's/[[:space:]]*$//' > /tmp/qr-ref.txt
    for mask in 0 1 2 3 4 5 6 7; do
        "$QRDUMP" "$payload" "$version" "$mask" | sed -e 's/[[:space:]]*$//' > /tmp/qr-ours.txt
        if diff -q /tmp/qr-ref.txt /tmp/qr-ours.txt >/dev/null 2>&1; then
            echo "ok    v$version mask $mask  (${#payload} bytes)"
            return 0
        fi
    done
    echo "FAIL  v$version  no mask reproduced the reference (${#payload} bytes)"
    fail=1
}

check "VIBEEE" 1
check "PANIC" 2
check "VBE1|E0E|00000002|DEADBEEF|00102F31" 3
check "VBE1|E0D|00000000|00000000|00102F31|0010ABCD,00103F00" 4
check "VBE1|E0E|00000002|DEADBEEF|00102F31|0010ABCD,00103F00,00104112,001055AA" 5

exit $fail
