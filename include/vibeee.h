/* vibeee.h: the calls this system has and POSIX has no word for.
 *
 * A ported program opens files and allocates memory through the headers
 * it already knows. What it cannot do through them is take the screen or
 * read a key: neither is a file here. The screen is a shared-memory
 * object one process owns at a time, and keys arrive as events rather
 * than as bytes on a terminal.
 */
#ifndef _VIBEEE_H
#define _VIBEEE_H

/* What the screen is. `stride_px` is pixels per scanline and is not the
 * width: a framebuffer is padded to whatever the hardware found
 * convenient, and stepping by width would shear the picture. */
typedef struct {
    unsigned short width;
    unsigned short height;
    unsigned short stride_px;
    unsigned char  format;
    unsigned char  buffers;
    unsigned int   caps;
    unsigned int   bytes;
} vb_display;

/* Eight bits each of blue, green and red in a little-endian word, top
 * eight ignored: a pixel is written as 0x00RRGGBB. */
#define VB_FORMAT_XRGB8888 0

/* Take the screen and map it; returns the pixels, or NULL when the screen
 * is already somebody else's. One process owns it at a time, by decision:
 * two programs drawing into one framebuffer make a mess neither can undo.
 * Passing NULL for `info` is allowed if the sizes are not wanted.
 *
 * This is the screen as it is, at whatever size it turns out to be, and it
 * is refused while a desktop is running. A program that draws a picture of
 * its own fixed size wants vb_window_open below, which coexists with one. */
void *vb_display_acquire(vb_display *info);

/* Give it back. The console gets the screen, cleared. */
void vb_display_release(void);

/* One key, as it happened. Presses and releases both arrive: a program
 * holding a direction needs to know when it stopped being held.
 * `codepoint` is what the current layout made of it, or zero for a key
 * that makes no character; text comes from there and shortcuts from
 * `code`. */
typedef struct {
    unsigned char code;
    unsigned char pressed;
    unsigned char modifiers;
    unsigned char _pad;
    unsigned int  codepoint;
} vb_key;

/* Read up to `count` keys, waiting at most `timeout_us` microseconds.
 * Zero polls; VB_WAIT_FOREVER waits for as long as it takes. Returns how
 * many arrived, or -1.
 *
 * The first call claims the keyboard: a shell reading lines and a program
 * reading keys cannot both consume the same keystroke. The claim ends
 * when the process does. */
int vb_key_read(vb_key *into, int count, unsigned int timeout_us);

#define VB_WAIT_FOREVER 0xFFFFFFFFu

/* ---- virtual framebuffer windows -------------------------------------- */

/* A virtual framebuffer is a fixed-size pixel buffer, shown wherever there is
 * room for it: an ordinary desktop window when a desktop is running, and the
 * screen itself when none is. It is for games, emulators and other ports that
 * draw their own pixels, which is why the program's loop is the same either
 * way. The pixels are scaled with nearest-neighbour sampling, keeping their
 * proportions and leaving black where they do not reach. Only one virtual
 * framebuffer is open per C program; native Zig programs use
 * framebuffer.Window directly and may own more.
 *
 * Passing VB_WINDOW_FULLSCREEN asks for the desktop content area above other
 * windows. The desktop bar remains available. Without it the window follows
 * the normal tiling policy. On the bare screen the flag makes no difference.
 * Returns NULL when neither a window nor the screen can be had, or when
 * memory cannot be allocated. `info` describes the fixed logical framebuffer
 * rather than the surface it is presented on, and may be NULL for a program
 * that already knows the shape it asked for. */
#define VB_WINDOW_FULLSCREEN 0x1u
void *vb_window_open(const char *title, unsigned short width,
                     unsigned short height, unsigned int flags,
                     vb_display *info);

/* Scale and present the virtual framebuffer. Returns 0 on success, or -1
 * when the desktop window has closed or cannot be presented. */
int vb_window_present(void);

/* Read keyboard events for this window: from the desktop when it is in one,
 * and from the keyboard itself when it is on the bare screen. Same result
 * shape as vb_key_read. A window-close request returns -1. */
int vb_window_key_read(vb_key *into, int count, unsigned int timeout_us);

/* Give the window or the screen back and free the framebuffer. */
void vb_window_close(void);

/* Key numbers, written from the enum that defines them. */
#include <vibeee-keys.h>

/* ---- sound ---------------------------------------------------------- */

/* What a stream is. Fixed by the system rather than chosen per program,
 * so a caller reads it rather than asking for it: samples are signed and
 * little endian at the width given here. */
typedef struct {
    unsigned int  rate;      /* frames a second */
    unsigned char channels;  /* samples a frame */
    unsigned char bits;      /* bits a sample */
    unsigned char _pad[2];
} vb_sound;

/* Join the sound graph as a node with one output, connected to wherever
 * sound goes. Returns 0, or -1 when there is no sound service. One output
 * per program: a program wanting two wants the graph itself, which is a
 * richer thing than a header should pretend to be. */
int vb_sound_open(const char *name, vb_sound *shape);

/* Hand over frames; returns how many were taken. Fewer than asked means
 * the ring is full, and the rest should be offered again rather than
 * waited on: a sound loop that blocks is a picture that stops. */
int vb_sound_write(const void *frames, int count);

/* How many frames would be taken right now, which is what to mix. */
int vb_sound_room(void);

/* Wait until the ring wants more, or until the timeout passes. The one
 * call a sound loop cannot do without: a full ring waits for the engine
 * and never spins, because a program that polls instead takes the
 * processor the service needs to drain it, and on one core that is how a
 * tone comes out full of holes. */
int vb_sound_wait(unsigned int timeout_us);

/* Whether everything handed over has been played. */
int vb_sound_drained(void);

void vb_sound_close(void);

#endif /* _VIBEEE_H */
