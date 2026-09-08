/* The platform half of the port: the six calls the engine asks a system
 * for, answered with this system's own. Written here rather than in the
 * engine, which is untouched. */

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <vibeee.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_system.h"

/* Leave the way the engine's own quit does. Its exit list runs first,
 * which is where the configuration is written and a demo being recorded
 * is finished; the engine ends the process from there once the game has
 * started, and this ends it otherwise. */
static void leave(void)
{
    I_Quit();
    exit(0);
}

void DG_Init(void)
{
    /* The engine's own resolution, whatever it is shown on: the window
     * scales it and puts it in the middle. Its shape is the engine's, so
     * there is nothing to be told back about it. */
    void *surface = vb_window_open("Doom", DOOMGENERIC_RESX, DOOMGENERIC_RESY,
                                   NULL);
    if (surface == NULL) {
        fprintf(stderr, "doom: there is nowhere to draw\n");
        exit(1);
    }
    atexit(vb_window_close);

    /* The engine draws each frame into DG_ScreenBuffer, which it allocated
     * before calling here. The window's own surface takes its place, so a
     * frame is drawn once, where it is presented from, and is not copied.
     * The surface is read in full by each present, so drawing into it
     * between presents is safe. */
    free(DG_ScreenBuffer);
    DG_ScreenBuffer = surface;
}

void DG_DrawFrame(void)
{
    if (vb_window_present() < 0) leave();
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

/* This system's key numbers to the engine's, by physical position.
 *
 * The engine reads a key as the place it sits, the way the DOS original
 * did: a weapon is the digit row, strafing is the two keys beside the
 * right shift, and what a key types is worked out by the engine itself
 * from the shift it saw go down. So the layout in force is not consulted,
 * and a press and its release name the same key by construction. On a
 * keyboard that is not QWERTY the game's keys stay where the engine put
 * them, and text typed into it, cheats and save names, is typed by
 * position.
 *
 * Indexed by `vb_key.code`, which is a byte, so every code has a slot.
 * A key the engine has no use for maps to zero and is not passed on. */
static const unsigned char by_position[UCHAR_MAX + 1] = {
    [VB_KEY_ESCAPE]          = KEY_ESCAPE,
    [VB_KEY_N1]              = '1',
    [VB_KEY_N2]              = '2',
    [VB_KEY_N3]              = '3',
    [VB_KEY_N4]              = '4',
    [VB_KEY_N5]              = '5',
    [VB_KEY_N6]              = '6',
    [VB_KEY_N7]              = '7',
    [VB_KEY_N8]              = '8',
    [VB_KEY_N9]              = '9',
    [VB_KEY_N0]              = '0',
    [VB_KEY_MINUS]           = KEY_MINUS,
    [VB_KEY_EQUAL]           = KEY_EQUALS,
    [VB_KEY_BACKSPACE]       = KEY_BACKSPACE,
    [VB_KEY_TAB]             = KEY_TAB,
    [VB_KEY_Q]               = 'q',
    [VB_KEY_W]               = 'w',
    [VB_KEY_E]               = 'e',
    [VB_KEY_R]               = 'r',
    [VB_KEY_T]               = 't',
    [VB_KEY_Y]               = 'y',
    [VB_KEY_U]               = 'u',
    [VB_KEY_I]               = 'i',
    [VB_KEY_O]               = 'o',
    [VB_KEY_P]               = 'p',
    [VB_KEY_BRACKET_LEFT]    = '[',
    [VB_KEY_BRACKET_RIGHT]   = ']',
    [VB_KEY_ENTER]           = KEY_ENTER,
    [VB_KEY_CONTROL_LEFT]    = KEY_FIRE,
    [VB_KEY_A]               = 'a',
    [VB_KEY_S]               = 's',
    [VB_KEY_D]               = 'd',
    [VB_KEY_F]               = 'f',
    [VB_KEY_G]               = 'g',
    [VB_KEY_H]               = 'h',
    [VB_KEY_J]               = 'j',
    [VB_KEY_K]               = 'k',
    [VB_KEY_L]               = 'l',
    [VB_KEY_SEMICOLON]       = ';',
    [VB_KEY_APOSTROPHE]      = '\'',
    [VB_KEY_GRAVE]           = '`',
    [VB_KEY_SHIFT_LEFT]      = KEY_RSHIFT,
    [VB_KEY_BACKSLASH]       = '\\',
    [VB_KEY_Z]               = 'z',
    [VB_KEY_X]               = 'x',
    [VB_KEY_C]               = 'c',
    [VB_KEY_V]               = 'v',
    [VB_KEY_B]               = 'b',
    [VB_KEY_N]               = 'n',
    [VB_KEY_M]               = 'm',
    [VB_KEY_COMMA]           = ',',
    [VB_KEY_PERIOD]          = '.',
    [VB_KEY_SLASH]           = '/',
    [VB_KEY_SHIFT_RIGHT]     = KEY_RSHIFT,
    [VB_KEY_KEYPAD_ASTERISK] = KEYP_MULTIPLY,
    [VB_KEY_ALT_LEFT]        = KEY_LALT,
    [VB_KEY_SPACE]           = KEY_USE,
    [VB_KEY_CAPS_LOCK]       = KEY_CAPSLOCK,
    [VB_KEY_F1]              = KEY_F1,
    [VB_KEY_F2]              = KEY_F2,
    [VB_KEY_F3]              = KEY_F3,
    [VB_KEY_F4]              = KEY_F4,
    [VB_KEY_F5]              = KEY_F5,
    [VB_KEY_F6]              = KEY_F6,
    [VB_KEY_F7]              = KEY_F7,
    [VB_KEY_F8]              = KEY_F8,
    [VB_KEY_F9]              = KEY_F9,
    [VB_KEY_F10]             = KEY_F10,
    [VB_KEY_F11]             = KEY_F11,
    [VB_KEY_F12]             = KEY_F12,
    [VB_KEY_NUM_LOCK]        = KEY_NUMLOCK,
    [VB_KEY_SCROLL_LOCK]     = KEY_SCRLCK,
    [VB_KEY_KP7]             = KEYP_7,
    [VB_KEY_KP8]             = KEYP_8,
    [VB_KEY_KP9]             = KEYP_9,
    [VB_KEY_KP_MINUS]        = KEYP_MINUS,
    [VB_KEY_KP4]             = KEYP_4,
    [VB_KEY_KP5]             = KEYP_5,
    [VB_KEY_KP6]             = KEYP_6,
    [VB_KEY_KP_PLUS]         = KEYP_PLUS,
    [VB_KEY_KP1]             = KEYP_1,
    [VB_KEY_KP2]             = KEYP_2,
    [VB_KEY_KP3]             = KEYP_3,
    [VB_KEY_KP0]             = KEYP_0,
    [VB_KEY_KP_PERIOD]       = KEYP_PERIOD,
    [VB_KEY_KP_ENTER]        = KEYP_ENTER,
    [VB_KEY_KP_SLASH]        = KEYP_DIVIDE,
    [VB_KEY_CONTROL_RIGHT]   = KEY_FIRE,
    [VB_KEY_ALT_RIGHT]       = KEY_LALT,
    [VB_KEY_HOME]            = KEY_HOME,
    [VB_KEY_UP]              = KEY_UPARROW,
    [VB_KEY_PAGE_UP]         = KEY_PGUP,
    [VB_KEY_LEFT]            = KEY_LEFTARROW,
    [VB_KEY_RIGHT]           = KEY_RIGHTARROW,
    [VB_KEY_END]             = KEY_END,
    [VB_KEY_DOWN]            = KEY_DOWNARROW,
    [VB_KEY_PAGE_DOWN]       = KEY_PGDN,
    [VB_KEY_INSERT]          = KEY_INS,
    [VB_KEY_DELETE]          = KEY_DEL,
};

/* One key, read from the window as the engine asks for it: one at a
 * time, so nothing is taken out of the window's queue before the engine
 * has room for it. A closed window ends the game. */
int DG_GetKey(int *pressed, unsigned char *key)
{
    vb_key event;

    for (;;) {
        int n = vb_window_key_read(&event, 1, 0);
        if (n < 0) leave();
        if (n == 0) return 0;

        unsigned char k = by_position[event.code];
        if (k == 0) continue;
        *pressed = event.pressed;
        *key = k;
        return 1;
    }
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

int main(int argc, char **argv)
{
    doomgeneric_Create(argc, argv);
    for (;;) doomgeneric_Tick();
    return 0;
}
