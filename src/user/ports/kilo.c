/* The wrapper that gives kilo the whole screen.
 *
 * `third_party/README.md` says vendored code is never edited in place, so this
 * is the adaptation living beside it instead: kilo's own `main` is renamed at
 * compile time and called from here, which needs no change to its source and
 * survives re-fetching it.
 *
 * What it adds is the alternate screen. kilo draws over whatever was on the
 * display and, on the way out, restores only the terminal mode, so the shell's
 * next prompt lands in the middle of the editor's last frame. Asking for the
 * screen and giving it back means the scrollback is exactly as it was left.
 *
 * Through `atexit` rather than after the call, because Ctrl-Q leaves by
 * calling `exit` and never returns. Registered before kilo registers its own,
 * so this one runs last: the screen goes back after the terminal does. */

/* The rename is for kilo's file, not this one: both are compiled by the same
 * command, so it has to be undone here or this file's `main` becomes a second
 * definition of the function it means to call. */
#undef main

#include <stdlib.h>
#include <unistd.h>

int kilo_main(int argc, char **argv);

static void give_back_screen(void)
{
    write(STDOUT_FILENO, "\x1b[?1049l", 8);
}

int main(int argc, char **argv)
{
    write(STDOUT_FILENO, "\x1b[?1049h", 8);
    atexit(give_back_screen);

    return kilo_main(argc, argv);
}
