# apps

Programs that are not part of the system.

The system image holds what a machine needs to start and be used: the
kernel, the services, the shell and the tools. Everything else is
somebody's choice, and choices belong where a person's things are. So an
app here is built separately and installed into `/home`, where it sits
beside the files it works on and survives a reboot like they do.

## What is in the tree, and what is not

Third-party source is never committed here. An app is a recipe saying
where its source comes from, plus whatever glue this system needs that
the upstream project does not have. The glue is ours and belongs in the
tree; the project is theirs and is fetched.

    apps/<name>/app.mk        where the source is, and how to build it
    apps/<name>/*.c           the platform half, written for this system

Fetched source lands in `build/apps/<name>/`, which is not tracked.

## Building

    make apps                 build every app
    make app APP=doom         build one

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
