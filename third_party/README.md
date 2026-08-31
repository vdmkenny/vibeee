# Vendored third-party code

Each entry is pinned, unmodified, and used under its own licence. Nothing here
is edited in place: adaptations belong in a wrapper under `src/`, so an update
is a re-fetch rather than a merge.

## spleen

A bitmap console font by Frederic Cambus, BSD 2-Clause. See `spleen/LICENSE`.

Used for the framebuffer console. The `.bdf` files are the source of truth;
`src/mkfont.zig` converts them to Zig arrays at build time (`zig build fonts`),
so the generated tables in `src/fonts/` are never hand-edited.

Chosen over the video ROM's own font because it is designed for terminals and is
markedly more legible on a 7-inch panel at 133 DPI, where a glyph is about three
millimetres tall. Bitmaps rather than a scalable face: at sixteen pixels a
hand-tuned bitmap beats anything a rasteriser produces, with no hinting to get
wrong.

## ark-pixel

TakWolf's Ark Pixel font, SIL OFL 1.1. See `ark-pixel/LICENSE`.

Two faces of one family: the proportional 12px for interface text, and the
monospaced 12px for the terminal, so a label and a shell share one voice. The
monospaced latin face is pinned at release `2026.08.11`. Its box-drawing
glyphs are full-width in the East Asian convention; the terminal draws its own
line glyphs from cell geometry instead, as terminals conventionally do.

## uACPI

Daniil Tatianin's ACPI implementation, MIT. See `uacpi/LICENSE`. Pinned at
`2e7b6d535b87f968874720daf93c64cc78cf3e23`.

Chosen over writing an AML interpreter, which is what the platform design
called for before there was a C toolchain here. The reasoning that made a
hand-written one look necessary has not changed: the methods this machine needs
evaluated poke embedded-controller lines whose identities nobody has published,
so only the firmware's own bytecode knows what to do, and a table of register
offsets copied from a forum post is a way to turn off a power rail that should
have stayed on.

What changed is the cost of not writing one. uACPI includes nothing but
`stdint.h` and its neighbours, so it needs no library at all, and at some thirty
thousand lines it fits inside the size cap the design had already set aside for
a smaller interpreter of our own. An interpreter is a thing to be correct at,
not a thing to have written.

It runs in `platd` rather than in the kernel. This is bytecode from a 2007 AMI
BIOS, interpreted at runtime, and its job is to poke hardware: that belongs in a
restartable process holding a capability, not in ring 0.
