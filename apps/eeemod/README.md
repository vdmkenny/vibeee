# eeemod

A tracker module player.

A module is a song stored as the instruments it uses and the patterns
that play them: a few hundred kilobytes carrying minutes of music,
which is why the format outlived the machine it was written for. This
plays the ProTracker and SoundTracker ones, four channels or more.

## What is here

| File | What it holds |
|---|---|
| [`module.zig`](module.zig) | The file: instruments, patterns, and the cells inside them. Nothing is copied and nothing is allocated, so a module is a view over the bytes the caller read. |
| [`player.zig`](player.zig) | The song on a clock: rows, ticks, and the effects that bend a note between them. It hands voices to the system's mixer and never touches a sample. |
| [`eeemod.zig`](eeemod.zig) | The window, and keeping the sound service fed. |

The format and the player are host-tested: a module is bytes in and
notes out, and a song is those notes on a clock, so neither needs a
sound card to be checked.

    zig build test-eeemod
    make eeemod

## The window

Four strips. The song at the top, a page of the pattern with the playing
row on the accent and every fourth row picked out, a meter per channel
with what it is playing, and where the song has got to along the bottom.

The pattern is a page rather than a list that scrolls under the playing
row. Scrolling moves every line whenever the row changes, which is the
whole strip repainted and copied to the screen eight times a second; a
page costs two lines a row and one repaint a screenful. Each strip
redraws only when what it shows has changed, and the stream is fed on
either side of the drawing as well as between passes, since painting a
window is the longest thing this does.

If the sound stutters, the status bar says how many times the service
went to the ring and found it short.

| Key | What it does |
|---|---|
| O | Look for a module |
| Space | Stop, and start again where it stopped |
| Left, Right | A place back or on along the song |
| Home | Back to the start |

## The music is not here

A module is somebody's work and is not ours to redistribute, so none
ships. Drop one in `home/` and open it from the launcher, the file
manager, or the O key.

The Mod Archive holds tens of thousands of them, most under terms that
let you keep a copy. `space_debris.mod` by Captain is the one this was
written against.
