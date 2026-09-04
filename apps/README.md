# apps

Programs that are not part of the system.

The system image holds what a machine needs to start and be used: the
kernel, the services, the shell and the tools. Everything else is
somebody's choice, and choices belong where a person's things are. So an
app here is built separately and installed into `/home`, where it sits
beside the files it works on and survives a reboot like they do.

## What is here

| Program | Source | What it is |
|---|---|---|
| Doom | [`doom/`](doom/) | The portable engine, fetched. What is kept here is its platform half: six calls answered with this system's screen, key stream and clock. It runs at whatever size the screen comes up at and saves into `/home`. No sound backend. The WAD is not fetched for you; the recipe says which one and where to get it. |
| Hero | [`hero/`](hero/) | A character journal for Dungeons and Dragons on the 2024 rules, written here and built by the main `build.zig`. It opens a `.hero` file from the launcher or its own File menu, and handles rolls, damage, rests, spells, gold and notes. |
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

An app builds into `home/`, and the image seeds `/home` from there. So
anything in `home/` is on the machine at the next boot, and rebuilding
the image does not lose it: `home/` on this side is the source of truth,
not the copy inside the image.

Nothing that boots the machine depends on this: `make qemu` and `make vnc`
use whatever is already staged. Building an app is a compiler run over
somebody else's whole source tree, and a fetch on a clone that has not
done one, which is not a thing to put in front of every boot. So after
changing an app, build it before booting:

    make apps && make vnc

Data files go in `home/` too, and you put them there yourself. An app
recipe says what it needs and where to get it, and stops short of
fetching it: what a program may be redistributed with is not something a
build should decide for you. Drop the file beside the binary and it is
there when the machine starts.
