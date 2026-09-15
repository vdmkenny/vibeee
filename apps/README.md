# apps

Programs that are not part of the system.

The system image holds what a machine needs to start and be used: the
kernel, the services, the shell and the tools. Everything else is
somebody's choice, and choices belong where a person's things are. So an
app here is built separately and installed into `/home`, where it sits
beside the files it works on and survives a reboot like they do.

## Where they go

Programs go into `home/bin/`, which is on the search path ahead of the
system's `/bin`: an app is run by typing its name like anything else, and
a machine's own copy of a program wins over the one it shipped with. What
an app reads is not a program and stays in `home/` with the rest of
somebody's files.

## What is here

| Program | Source | What it is |
|---|---|---|
| Doom | [`doom/`](doom/) | The portable engine, fetched. What is kept here is its platform half: the calls it asks a system for, answered with this system's screen, key stream, clock and mixer. It runs in a window and saves into `/home`. Its effects play; its music does not, a wad's music being a score rather than a recording. The WAD is not fetched for you; the recipe says which one and where to get it. |
| Hero | [`hero/`](hero/) | A character journal for Dungeons and Dragons on the 2024 rules, written here and built by the main `build.zig`. It opens a `.hero` file from the launcher or its own File menu, and handles rolls, damage, rests, spells, gold and notes. |
| eeemod | [`eeemod/`](eeemod/) | A tracker module player: ProTracker and SoundTracker songs, four channels or more, through the system's own mixer. The format and the sequencer are host-tested, since a module is bytes in and notes out. No module ships; drop one in `home/` and open it from the launcher. |
| web | [`web/`](web/) | **Experimental.** A web browser: it fetches a page over HTTP or HTTPS, parses it, runs its scripts and draws it in one column in the system's own faces. Of what a page's stylesheets say it follows what it can draw: what shows and what is hidden, the colours of words and of what they sit on, which way lines lean, the room and the lines around a box, rows set side by side by flex and by grid, and where a page positions a box against another. A form is filled in with the toolkit's own controls and sent, by GET in the address the way a search is, or by POST in the body the way a login is. Pictures come three at a time, what the page says each one shows standing in until it arrives. Scripts run on the tree the page was read from, under bounds on what they may hold, how deep they may call and how long each may run; what they change is read again and drawn, and what they ask for is answered without the rest of the page waiting on it. `web -t <address>` prints a page's words in the shell. Its settings are the `web` domain, `cfg web`, and the menu at the end of its strip changes them, whether pages are drawn light or dark among them, and makes the page on screen the home page. What it is not: a page that measures itself is told noughts, nothing watches for a part of a page coming into view, a block box takes the column's width rather than a width the page states, and the faces carry no Chinese, Japanese or Korean. Mainstream pages come out in part rather than in full, and one whose scripts do much work holds the machine for tens of seconds. |
| echat | [`echat/`](echat/) | An IRC client: networks and their channels down a rail, the transcript grouped by who is speaking, who is here, and a line to type into. `make echat` checks its engine and model against the reference vectors first. It reaches a network on 6667. Sealed connections are written and blocked in the standard library, not here: see the known gaps in [docs/status.md](../docs/status.md). |

Each is built and versioned on its own, separately from the system's version
string.

## What is in the tree, and what is not

Third-party source is never committed here. An app is a recipe saying
where its source comes from, plus whatever glue this system needs that
the upstream project does not have. The glue is ours and belongs in the
tree; the project is theirs and is fetched.

    apps/<name>/app.mk        where the source is, and how to build it
    apps/<name>/*.c           the platform half, written for this system

Fetched source lands in `build/apps/<name>/`, which is not tracked.

Not every app is fetched, and not every app is C. A first-party program that
is ours but is still not part of the system lives here whole rather than as a
recipe: its source is in the tree, and it is built by the main `build.zig` into
`home/` the same way a system program is built into the image. Hero, the
character journal, is one of these: `apps/hero/` holds its source, `make hero`
builds and stages it, and `make apps` does so along with the rest.

## Building

    make apps                 build every app
    make app APP=doom         build one
    make hero                 build Hero alone
    make echat                check echat's protocol engine
    make eeemod               build the tracker player
    make web                  check the reader's host side and build it

An app builds into `home/bin/`, and the image seeds `/home` from there. So
anything in `home/` is on the machine at the next boot, and rebuilding
the image does not lose it: `home/` on this side is the source of truth,
not the copy inside the image.

Nothing that boots the machine depends on this: `make qemu` and `make vnc`
use whatever is already staged. Building an app is a compiler run over
somebody else's whole source tree, and a fetch on a clone that has not
done one, which is not a thing to put in front of every boot. So after
changing an app, build it before booting:

    make apps && make vnc

Data files go in `home/` itself rather than beside the program, and you
put them there yourself. An app recipe says what it needs and where to
get it, and stops short of fetching it: what a program may be
redistributed with is not something a build should decide for you. A
program started from the desktop runs in `/home`, so a file dropped
there is where it looks.
