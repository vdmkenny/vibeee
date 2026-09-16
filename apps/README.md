# apps

Programs that are not part of the system image.

The image holds the kernel, services, shell and tools. Other programs are built
separately and installed into `/home`, which persists across boots.

## Where they go

- Programs go into `home/bin/`, which is searched before `/bin`. A program in
  `home/bin/` takes precedence over a system program of the same name.
- Data files go in `home/`. Recipes do not fetch data; each names what it needs and
  where to get it. Programs started from the desktop run in `/home`.

## What is here

| Program | Source | What it is |
|---|---|---|
| Doom | [`doom/`](doom/) | The portable engine, fetched, with a platform layer for this system's screen, keys, clock and mixer. Runs in a window, plays sound effects, saves into `/home`. No music. The WAD is not fetched; the recipe names it. |
| Hero | [`hero/`](hero/) | D&D 2024 character journal, first-party, built by the main `build.zig`. Opens `.hero` files from the launcher or its File menu. Rolls, damage, rests, spells, gold, notes. |
| eeemod | [`eeemod/`](eeemod/) | Tracker module player for ProTracker and SoundTracker songs, four or more channels, through the system mixer. Format and sequencer host-tested. No modules ship; put one in `home/` and open it from the launcher. |
| web | [`web/`](web/) | **Experimental** browser. See below. |
| echat | [`echat/`](echat/) | IRC client: network rail with channels, grouped transcript, member list, input line. `make echat` tests the engine and model first. Plaintext on port 6667; TLS is blocked by the standard library (see [docs/status.md](../docs/status.md)). |

Each is versioned separately from the system.

### web

- Fetches over HTTP and HTTPS, parses, runs scripts, draws one column in the system
  faces.
- Styles applied: visibility, text and background colour, text direction, box
  spacing and borders, flex and grid rows, positioned boxes.
- Forms use the toolkit's controls; GET and POST.
- Pictures load three at a time; alt text shows until each arrives.
- Scripts run on the page tree with bounds on memory, call depth and run time. Script
  requests do not block the page.
- `web -t <address>` prints a page's text.
- Settings: the `web` domain (`cfg web`): home page, images, mobile, styles, theme
  (auto, light, dark). The menu at the end of the strip edits them.
- Not supported: layout measurement from scripts (returns zeros),
  `IntersectionObserver`, stated widths on ordinary blocks, CJK glyphs. Mainstream
  pages render partially; script-heavy pages take tens of seconds on the 701.

## Source

Third-party source is not committed. A recipe says where the source comes from and how
to build it; glue code for this system is committed beside it.

    apps/<name>/app.mk        source location and build
    apps/<name>/*.c           platform layer for this system

Fetched source goes into `build/apps/<name>/`, untracked.

First-party programs that are not part of the image live here whole, in Zig, built by
the main `build.zig` into `home/`. Hero is one: `apps/hero/` holds its source, and
`make hero` builds and stages it. Each carries its launcher icon with
`eui.icon.carry` ([design/10-gui.md](../design/10-gui.md) §6.7).

## Building

    make apps                 build every app
    make app APP=doom         build one
    make hero                 build Hero
    make echat                test echat's engine
    make eeemod               build the tracker player
    make web                  test the browser's host side and build it

Apps build into `home/bin/`, and the image seeds `/home` from `home/`. Rebuilding the
image keeps installed apps: `home/` on the host is the source of truth.

`make menuconfig` > Extra applications builds the selected apps with the image. Turning
off "Copy home/ into /home" limits `/home` to the selected apps.

`make qemu` and `make vnc` use whatever is already staged and do not build apps. After
changing an app, build it before booting:

    make apps && make vnc
