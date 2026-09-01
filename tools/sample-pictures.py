#!/usr/bin/env python3
"""Regenerate the sample pictures in home/pictures.

They are generated rather than photographed for two reasons. A picture whose
expected values are known by construction is worth more as a fixture than one
that merely looks nice: the orientation this writes is the orientation the
viewer must show. And the machine image is distributed, so every file in it
would otherwise be somebody else's photograph under somebody else's licence.

The EXIF is written by a real EXIF writer, which is the part being tested:
what the parser reads has to be what a camera would have written, not what
this script thinks one would.

    python3 tools/sample-pictures.py

Needs Pillow. The outputs are committed, so this is only run when the set
changes.
"""

import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "home", "pictures")


def png(path, width, height, pixel):
    """A PNG, written here rather than by a library: no EXIF, no dependency."""

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    raw = b""
    for y in range(height):
        raw += b"\x00"
        for x in range(width):
            raw += bytes(pixel(x, y))

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def scene(image):
    """Something with a horizon, a sun and a shadow, so which way up it is
    drawn is obvious at a glance and a thumbnail of it is recognisable."""
    w, h = image.size
    px = image.load()

    for y in range(h):
        for x in range(w):
            if y < h * 0.55:
                # Sky, lighter towards the horizon.
                t = y / (h * 0.55)
                px[x, y] = (60 + int(120 * t), 110 + int(110 * t), 200 + int(45 * t))
            else:
                # Ground, darker towards the bottom.
                t = (y - h * 0.55) / (h * 0.45)
                px[x, y] = (90 - int(40 * t), 120 - int(60 * t), 60 - int(30 * t))

    # A sun in the upper left, which is the corner an orientation tag moves.
    cx, cy, r = w // 5, h // 5, min(w, h) // 8
    for y in range(max(0, cy - r), min(h, cy + r)):
        for x in range(max(0, cx - r), min(w, cx + r)):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                px[x, y] = (250, 240, 180)

    return image


def photo(path, width, height, orientation, model="Eee PC 701"):
    """`width` and `height` are the picture the right way up.

    What is stored is that picture turned the way the orientation tag says it
    was, so a viewer honouring the tag gets the upright one back. A fixture
    that stored the upright picture and merely claimed a tag would pass for
    any viewer that ignored the tag, which is the bug being tested for.
    """
    from PIL import Image

    upright = scene(Image.new("RGB", (width, height)))

    # PIL rotates counter-clockwise, and the tag says how far clockwise a
    # viewer has to turn it: the two are opposites, which is the whole of it.
    stored = {
        1: lambda im: im,
        3: lambda im: im.rotate(180),
        6: lambda im: im.rotate(90, expand=True),
        8: lambda im: im.rotate(-90, expand=True),
    }[orientation](upright)

    exif = stored.getexif()
    exif[0x010F] = "ASUS"
    exif[0x0110] = model
    exif[0x0132] = "2026:08:31 22:14:07"
    exif[0x0112] = orientation
    stored.save(path, quality=82, exif=exif)


def main():
    os.makedirs(OUT, exist_ok=True)

    # Pictures with no metadata at all, one landscape and one portrait, so the
    # fitting is exercised both ways round.
    png(
        os.path.join(OUT, "colours.png"),
        240,
        160,
        lambda x, y: (x * 255 // 239, y * 255 // 159, ((x + y) * 255) // 398),
    )
    png(
        os.path.join(OUT, "tall.png"),
        90,
        300,
        lambda x, y: (40, (y * 255) // 299, 200 - x * 2),
    )

    # Photographs, with what a camera writes beside the picture. The last two
    # are stored turned: shown as they are stored, the sun is in the wrong
    # corner, which is the whole reason the orientation tag is read.
    photo(os.path.join(OUT, "photo.jpg"), 320, 240, 1)
    photo(os.path.join(OUT, "sideways.jpg"), 240, 320, 6)
    photo(os.path.join(OUT, "upside-down.jpg"), 320, 240, 3)
    photo(os.path.join(OUT, "other-way.jpg"), 240, 320, 8)

    # Something this build cannot open, for the preview that has to say so.
    open(os.path.join(OUT, "unknown.dat"), "wb").write(bytes(range(256)) * 4)

    for name in sorted(os.listdir(OUT)):
        path = os.path.join(OUT, name)
        print(f"{name:20} {os.path.getsize(path):>8} bytes")


if __name__ == "__main__":
    main()
