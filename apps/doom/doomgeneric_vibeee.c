/* The platform half of the port: the six calls the engine asks a system
 * for, answered with this system's own. Written here rather than in the
 * engine, which is untouched. */

#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vibeee.h>

#include "doomgeneric.h"
#include "doomkeys.h"

static void pump(void);

static vb_display screen;
static unsigned int *pixels;
static int left, top;

/* A small ring, because the engine asks for one key at a time and the
 * keyboard hands over several at once. */
#define QUEUED 32
static struct { int pressed; unsigned char key; } queue[QUEUED];
static unsigned int head, tail;

void DG_Init(void)
{
    pixels = vb_display_acquire(&screen);
    if (pixels == NULL) {
        fprintf(stderr, "doom: the screen is not available\n");
        return;
    }
    left = ((int)screen.width - DOOMGENERIC_RESX) / 2;
    top = ((int)screen.height - DOOMGENERIC_RESY) / 2;
    if (left < 0) left = 0;
    if (top < 0) top = 0;
}

void DG_DrawFrame(void)
{
    if (pixels == NULL) return;

    int rows = DOOMGENERIC_RESY;
    if (top + rows > (int)screen.height) rows = (int)screen.height - top;
    int cols = DOOMGENERIC_RESX;
    if (left + cols > (int)screen.width) cols = (int)screen.width - left;

    for (int y = 0; y < rows; y++) {
        memcpy(pixels + (size_t)(top + y) * screen.stride_px + left,
               DG_ScreenBuffer + (size_t)y * DOOMGENERIC_RESX,
               (size_t)cols * sizeof(unsigned int));
    }

    pump();
}

void DG_SleepMs(uint32_t ms)
{
    usleep(ms * 1000);
}

uint32_t DG_GetTicksMs(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    pump();
    if (head == tail) return 0;

    *pressed = queue[tail % QUEUED].pressed;
    *key = queue[tail % QUEUED].key;
    tail++;
    return 1;
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

/* This system's key numbers to the engine's. Only what a player uses:
 * anything else arrives as its character, which is what the menus and
 * the cheat codes read. */
static unsigned char translate(const vb_key *event)
{
    switch (event->code) {
    case VB_KEY_UP:         return KEY_UPARROW;
    case VB_KEY_DOWN:       return KEY_DOWNARROW;
    case VB_KEY_LEFT:       return KEY_LEFTARROW;
    case VB_KEY_RIGHT:      return KEY_RIGHTARROW;
    case VB_KEY_ESCAPE:     return KEY_ESCAPE;
    case VB_KEY_ENTER:      return KEY_ENTER;
    case VB_KEY_TAB:        return KEY_TAB;
    case VB_KEY_BACKSPACE:  return KEY_BACKSPACE;
    case VB_KEY_CONTROL_LEFT:
    case VB_KEY_CONTROL_RIGHT: return KEY_FIRE;
    case VB_KEY_SPACE:      return KEY_USE;
    case VB_KEY_SHIFT_LEFT:
    case VB_KEY_SHIFT_RIGHT: return KEY_RSHIFT;
    case VB_KEY_ALT_LEFT:
    case VB_KEY_ALT_RIGHT:  return KEY_LALT;
    case VB_KEY_F1:  return KEY_F1;
    case VB_KEY_F2:  return KEY_F2;
    case VB_KEY_F3:  return KEY_F3;
    case VB_KEY_F4:  return KEY_F4;
    case VB_KEY_F5:  return KEY_F5;
    case VB_KEY_F6:  return KEY_F6;
    case VB_KEY_F7:  return KEY_F7;
    case VB_KEY_F8:  return KEY_F8;
    case VB_KEY_F9:  return KEY_F9;
    case VB_KEY_F10: return KEY_F10;
    case VB_KEY_F11: return KEY_F11;
    case VB_KEY_F12: return KEY_F12;
    default: break;
    }

    /* Letters and digits go through as themselves, lowercased, which is
     * what the engine compares against. */
    if (event->codepoint >= 32 && event->codepoint < 127) {
        unsigned char c = (unsigned char)event->codepoint;
        if (c >= 'A' && c <= 'Z') c += 32;
        return c;
    }
    return 0;
}

static void pump(void)
{
    vb_key events[16];
    int n = vb_key_read(events, 16, 0);
    for (int i = 0; i < n; i++) {
        unsigned char k = translate(&events[i]);
        if (k == 0) continue;
        if (head - tail >= QUEUED) break;
        queue[head % QUEUED].pressed = events[i].pressed;
        queue[head % QUEUED].key = k;
        head++;
    }
}

int main(int argc, char **argv)
{
    doomgeneric_Create(argc, argv);
    for (;;) doomgeneric_Tick();
    return 0;
}
