# roll

A contact sheet for a card of photographs.

What is on the card, laid out to look at, marked keep or reject, and
the keepers copied where the work belongs. The whole of a basic
photography pass on a machine with a card reader and no room to
develop anything.

## What is here

| File | What it holds |
|---|---|
| [`sheet.zig`](sheet.zig) | The roll: what is on the card, what has been marked, which of it is being looked at, and what a page holds. Pure, and host-tested. |
| [`roll.zig`](roll.zig) | The window: the grid, the one-up view, and copying. The places row and the key strip are the toolkit's, and the names come straight out of the listing. |

The model is host-tested: which picture is current, what a filter
leaves and which page something is on is arithmetic over a list, and
none of it needs a card in the reader.

    zig build test-roll
    make roll

## A picture of a picture

A frame out of a camera is twelve megapixels, which is fifty megabytes
of pixels and seconds of this processor. A page of those would be a wait
rather than a sheet.

Cameras write a small JPEG into the file's own tables for exactly this,
and `lib/exif.zig` finds it. A raw file carries a larger one again, and
for a raw file it is the only picture there is: nothing here develops
one. Only a file carrying no picture of its own is decoded itself.

A raw file's tables are at its front but the picture they name is
megabytes further in, so what the front gives is where it is and
exactly that stretch is read. A thumbnail then costs sixty-four
kilobytes plus the picture itself, whatever the file comes to, and the
sheet fills in one picture a pass while somebody is already walking it.
Names come from the directory listing and are all there at once, so a
photograph can be marked before its picture has arrived.

## The window

Four parts. The places along the top, which is the toolkit's own row
of volumes, the same one the file manager puts its volumes in and with
the same gauge saying how full each is, showing home and whatever is
plugged in and not the machine's own volumes; the roll itself, a page
of thumbnails; the keys along the bottom; and, in place of the roll,
one picture as large as the room allows with the camera's own words
beside it.

The grid is as many cells of at least a hundred and forty across as
fit, grown to fill the room exactly, so a wider window gets more
pictures and a taller one more rows rather than a border of nothing.
The plates are made to match and are taken from the heap, since how
many fit and how large they are are both facts about the window.

It opens on a card with photographs on it where one is in the reader,
and on the pictures folder where none is. Which of the mounted volumes
that means is decided by looking rather than by the name: a card mounts
under `/media` and so does whatever else the machine keeps there.

A page, not a scroll. This panel has no scroll to give, so walking past
the edge of a page turns it; a bar down the right says where in the
roll the page is and can be dragged to somewhere else in it, and is not
drawn at all when the whole roll is on one page. Marking walks on, because that is what
culling is: the decision and the next picture are one gesture, and
marking the same way twice takes the mark off again.

| Key | What it does |
|---|---|
| arrows | walk the roll, or the pictures one at a time |
| return | look at the current picture |
| escape | back to the roll |
| `p` | keep |
| `x` | reject |
| `r`, `l` | turn a quarter, as in the viewer |
| `i` | the camera's words, as in the viewer |
| `f` | show only what is kept |
| `c` | copy the keepers |
| `o` | choose a folder |

## What it draws

A pass arrives for every movement of the pointer anywhere in the
window, and what this window holds is expensive: a page of plates
blitted and a photograph resampled is most of the machine. So the
page, each cell, the large picture and the key row each remember what
they last drew and draw only when it differs. Marking a photograph
repaints two cells.

## What was decided

A card holds more frames than anyone culls in one sitting, so what has
been decided is written down: `roll.marks`, beside the pictures it is
about. It goes in the source folder rather than under home because the
decisions belong to the card, so a card culled on one machine and
carried to another arrives with what was decided about it.

Plain text, with what wrote it and which shape it is in on the first
line:

    # roll marks 1
    keep DSC_0001.JPG
    reject DSC_0002.JPG

A file whose shape a roll does not know is left alone entirely, marks
and all: reading the part it recognises and writing the result back
would lose whatever the rest of it said.

Written when the sheet has nothing left to read, before the folder
changes, and when the window closes. Not on every keystroke, which
would be a write to the card per picture.

## What it does not do

It does not develop a raw file. A raw file with no preview written into
it cannot be shown here, which is a thing to say plainly rather than to
work around.

It shows a thousand and twenty-four pictures at most, which is a card's
worth and then some. A folder with more shows a `+` on the count rather
than a sentence, and which part of it you get is whichever part the
filesystem handed over first.

It copies the file, not the picture. Nothing here writes a photograph
back out, so a turn is a way of looking at one and never a change to
it.
