#!/bin/sh
# Diff our QR encoder against libqrencode.
#
# libqrencode picks its mask by penalty score and gives no way to pin it, so we
# sweep all eight of ours and require an exact match on one. An exact match
# validates the whole pipeline at once: bitstream, padding, Reed-Solomon,
# function patterns, data placement, masking and format info.
set -e

QRDUMP=${QRDUMP:-build/qrdump}
command -v qrencode >/dev/null || { echo "qrencode not installed; skipping"; exit 0; }

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
