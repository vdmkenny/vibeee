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
 * Passing NULL for `info` is allowed if the sizes are not wanted. */
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

/* Key numbers, written from the enum that defines them. */
#include <vibeee-keys.h>

#endif /* _VIBEEE_H */
