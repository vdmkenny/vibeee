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
