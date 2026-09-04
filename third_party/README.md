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

Three faces of one family: the proportional 12px for interface text, the
monospaced 12px for the terminal, so a label and a shell share one voice, and
the proportional 16px for what is set large, a title or a figure, so large
text is a larger drawing of the same letters rather than the small ones
doubled. The
monospaced latin face is pinned at release `2026.08.11`. Its box-drawing
glyphs are full-width in the East Asian convention; the terminal draws its own
line glyphs from cell geometry instead, as terminals conventionally do.

`make fonts` converts the source to the tables in `src/lib/fonts/`, and the
image build packs those three faces into `/share/fonts.pack`. No GUI program
links them: the window manager reads the pack into a shared segment and hands
it to each client, so the glyphs are in memory once rather than once per
window.

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

## stb_image

Sean Barrett's image loader, public domain or MIT at the reader's choice. See
`stb/LICENSE`. Pinned at `2c980bb59875b0d32144a71867fbdebb2f77cd20`, v2.30.

Chosen over writing decoders, as `design/00-vibeee.md` decided. PNG alone is
an inflate implementation and a filter pass with a decade of corner cases
behind it, and JPEG is a Huffman decoder, a dequantiser and an inverse DCT.
None of that is interesting work, all of it is work that has to be exactly
right, and this is one header with no I/O in it: the caller reads the bytes
and passes them, which is the shape a system with no standard library wants.

The blocker the design recorded is gone. It needed `malloc`, `memcpy`,
`assert` and a freestanding C toolchain, and `eeelibc` provides all of them
for uACPI and lwIP already.

Beside it, `stb_image_write.h` from the same collection, v1.16, pinned at
`1ee679ca2ef753a528db5ba6801e1067b40481b8`, for the one thing written back:
a portrait shrunk small and kept as JPEG inside a character journal. The
wrapper calls only its JPEG path.

Which formats a binary carries is a build decision, one `-DSTBI_ONLY_` flag
each: the viewer opens photographs, and a program that only needs a wallpaper
should not carry a JPEG decoder to do it.

It decodes and nothing else. What a camera wrote beside the picture, the
orientation above all, it steps over, so `src/lib/exif.zig` reads that here.

## ath_hal (Atheros radio reference)

FreeBSD's Atheros Hardware Access Layer, ISC and BSD-2-Clause. See the
permission headers in each file. Pinned at
`7ca0c1eba2e4c49ac92499ef0f6adf27c8b930d4`; `ath_hal/COMMIT` records where it
came from.

**Reference only. None of it is compiled.** It is here the way `spleen`'s
`.bdf` files are here: as the source of truth for data that is transcribed
into Zig, not as code that is built. The AR2425 is reverse-engineered silicon
with no datasheet, and the reset and channel-set pipeline the design's network
section calls owed, the ar5212 and RF2425 mode initval tables, the EEPROM
power and antenna derivation, the PCU and RF-bank programming, and the AGC and
noise-floor calibration, is exactly the reverse-engineered data that is too
error-prone to reconstruct from prose. The values come from here: `make
athtables` reads the reference's own initialiser file and writes
`src/user/netd/ar5212/tables.zig`, so no number in the tables is typed by
hand, and the sequences that apply them are written in `src/user/netd` as Zig,
so the driver stays enums, packed structs and masks with no C shapes on any
path, and this tree is never linked.

The whole ar5212 family is kept at one revision rather than the AR2425's files
alone, because the 701 is the first of its family this machine drives and not
necessarily the last: a sibling part, an AR2417 or an AR2413, is transcribed
the same way from the same pinned reference when a machine needs it, without a
re-fetch that might land on a different revision.

Chosen over compiling the HAL as C, which is how uACPI and lwIP are vendored,
because those are large correct interpreters of a standard and this is a driver
whose every hot path the house rules keep in idiomatic Zig. What is irreplaceable
about the HAL is its numbers, not its C; so the numbers are what is kept, and the
code that uses them is ours.

## irc-parser-tests

Daniel Oaks' cross-implementation IRC parser test cases, CC0 1.0. See
`irc-parser-tests/LICENSE`. Pinned at
`6b417e666de20ba677b14e0189213b3706009df6`; `irc-parser-tests/COMMIT` records
where they came from.

**Reference only. None of it is compiled.** These are data transcribed into
Zig, like `spleen`'s `.bdf` files, not code that is built. `make irctests`
reads them and writes `apps/echat/irc/vectors.zig`, so no case in the table is
typed by hand and re-pinning means re-running the generator.

Three of the five files are transcribed: splitting a line into its atoms,
rendering atoms back into a line, and splitting a source into nick, user and
host. The other two cover mask matching and hostname validation, which
`apps/echat` does not do.

Chosen over writing cases from the grammar because the grammar is not what
implementations disagree about. The disagreements are in the corners: two
spaces where the standard allows one, an empty parameter, a trailing backslash
in a tag value, a colon inside a message. These cases were collected from four
other projects' suites and reflect what real networks send, so a client that
matches them matches other clients.

## cacert (certificate authorities)

The Mozilla root certificate store, extracted by the curl project, MPL 2.0.
Pinned at the extraction dated 2026-08-13, which the file's own header records.

**Reference only. None of it is compiled.** `make castore` decodes the
hundred and twenty-one certificates in it once and writes
`/share/ca.store`, so nothing on the machine decodes base64 at connection
time and the file it reads is a hundred and thirty kilobytes rather than a
hundred and eighty-eight.

Chosen over a curated handful of authorities because which roots a network
signs with is not something this system can predict, and a store missing one
fails in the way that teaches people to turn verification off. Chosen over
trusting on first use because a first use is exactly when somebody is on a
network they do not control.

Updating is a re-fetch from https://curl.se/ca/cacert.pem and a re-run of the
generator; the store is built, not committed.
