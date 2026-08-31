# Doom, through the portable engine that keeps the platform to six calls.
#
# The engine is fetched rather than kept here. What is kept is
# `doomgeneric_vibeee.c`, which is those six calls answered with this
# system's own: the screen, the keyboard and the clock.
#
# The game's data is not here and is not fetched for you. Doom reads its
# maps, sprites and sounds from a WAD, and which WAD is your business:
# the retail ones are bought, and the shareware one is free to pass
# around. Fetch one and drop it in `home/`, beside the binary.

SOURCE := https://github.com/ozkl/doomgeneric.git
REF    := master

# Where the engine's sources sit inside the checkout.
SUBDIR := doomgeneric

# The engine names its own source list in its makefile, so that is read
# rather than copied: a file added upstream arrives without anyone here
# noticing it should have. Its own platform files are dropped, since this
# app supplies one.
SOURCES = $(shell sed -n 's/^SRC_DOOM = //p' $(SRC)/Makefile \
	| tr ' ' '\n' | sed 's/\.o$$/.c/' | grep -v '^doomgeneric_' | tr '\n' ' ')

GLUE := doomgeneric_vibeee.c

# What the app cannot run without and this makefile will not go and get.
DATA      := doom1.wad
DATA_FROM := https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad

# The engine renders at whatever size it is told and does not scale, so it
# is told the size the screen actually comes up at. No video BIOS offers the
# 701's own 800x480, so the boot search settles on 640x480 and that is what
# there is to draw on.
CFLAGS := -DNORMALUNIX -DLINUX -DDOOMGENERIC_RESX=640 -DDOOMGENERIC_RESY=480
