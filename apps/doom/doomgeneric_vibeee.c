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

/* The engine sleeps when it is ahead of its own clock, which is the one
 * stretch of a frame where nothing else is happening, and so where the
 * stream is fed for nothing. */
void DG_SleepMs(uint32_t ms)
{
    vb_mix_sleep(ms * 1000);
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

/* ---- sound ----------------------------------------------------------- *
 *
 * The engine asks a platform for eight sounds at once, each at its own
 * volume and its own place between the ears, and for one call that keeps
 * them coming. The mixing itself is the system's, in `vb_mix_*`: reading a
 * sound at the rate it was recorded and scaling it for each ear is the same
 * work for every program that makes sounds, and none of it is Doom's.
 *
 * What is Doom's is here: which lump a sound lives in, how a wad stores
 * samples, and what its numbers for loudness and separation mean.
 */

#include "i_sound.h"
#include "deh_str.h"
#include "m_misc.h"
#include "w_wad.h"
#include "z_zone.h"

static boolean sound_up = false;
static boolean sfx_prefix = true;

/* Two settings the engine binds whenever its sound feature is on. They
 * belonged to the resampler the SDL backend could be built with; the
 * mixing here is the system's and has no such choice. Kept because the
 * configuration file is shared with builds that do, and a setting that
 * vanished would be a line somebody's file no longer parses. */
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

/* A sound as the mixer wants it: where its samples are and how fast they
 * were recorded. Kept on the sfxinfo so a sound looked up once is not
 * looked up again, and pointing into the cached lump, which is held for
 * the life of the program because the mixer reads it while it plays. */
typedef struct {
    const unsigned char *samples;
    int count;
    unsigned int rate;
} vb_sfx;

/* The lump a sound lives in. A linked sound is its own sound's lump, and
 * Doom prefixes the name where Heretic and Hexen do not. */
static void sfx_lump_name(sfxinfo_t *sfx, char *buf, size_t len)
{
    if (sfx->link != NULL) {
        sfx = sfx->link;
    }
    if (sfx_prefix) {
        M_snprintf(buf, len, "ds%s", DEH_String(sfx->name));
    } else {
        M_StringCopy(buf, DEH_String(sfx->name), len);
    }
}

static int vb_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char name[9];
    sfx_lump_name(sfx, name, sizeof(name));
    return W_GetNumForName(name);
}

/* A wad's sound lump: a two byte format, a two byte rate, a four byte
 * count, then that many unsigned samples. The library the original used
 * left the first and last sixteen bytes alone, and the wads were cut to
 * suit, so a sound played from its first byte starts with a click. */
static vb_sfx *sfx_of(sfxinfo_t *sfx)
{
    const unsigned char *lump;
    unsigned int rate, count;
    int length;
    vb_sfx *ready;

    if (sfx->driver_data != NULL) {
        return (vb_sfx *) sfx->driver_data;
    }

    if (sfx->lumpnum < 0) {
        sfx->lumpnum = vb_GetSfxLumpNum(sfx);
    }

    length = W_LumpLength(sfx->lumpnum);
    if (length < 8) {
        return NULL;
    }

    lump = W_CacheLumpNum(sfx->lumpnum, PU_STATIC);
    if (lump[0] != 0x03 || lump[1] != 0x00) {
        return NULL;
    }
    rate = lump[2] | (lump[3] << 8);
    count = lump[4] | (lump[5] << 8) | (lump[6] << 16) | ((unsigned int) lump[7] << 24);
    if (rate == 0 || count == 0 || count > (unsigned int) (length - 8)) {
        return NULL;
    }

    lump += 8;
    if (count > 48) {
        lump += 16;
        count -= 32;
    }

    ready = Z_Malloc(sizeof(vb_sfx), PU_STATIC, NULL);
    ready->samples = lump;
    ready->count = (int) count;
    ready->rate = rate;
    sfx->driver_data = ready;
    return ready;
}

/* Doom counts volume to 127 and separation to 254, with 128 in the middle.
 * The mixer counts each side to 255, which is what these come to. */
static void vb_UpdateSoundParams(int channel, int vol, int sep)
{
    int left = ((254 - sep) * vol) / 127;
    int right = (sep * vol) / 127;

    if (left < 0) left = 0; else if (left > 255) left = 255;
    if (right < 0) right = 0; else if (right > 255) right = 255;

    vb_mix_gain(channel, (unsigned char) left, (unsigned char) right);
}

static int vb_StartSound(sfxinfo_t *sfx, int channel, int vol, int sep)
{
    vb_sfx *ready;
    int left, right;

    if (!sound_up || channel < 0 || channel >= VB_MIX_VOICES) {
        return -1;
    }

    ready = sfx_of(sfx);
    if (ready == NULL) {
        return -1;
    }

    left = ((254 - sep) * vol) / 127;
    right = (sep * vol) / 127;
    if (left < 0) left = 0; else if (left > 255) left = 255;
    if (right < 0) right = 0; else if (right > 255) right = 255;

    if (vb_mix_start(channel, ready->samples, ready->count, ready->rate, 8,
                     (unsigned char) left, (unsigned char) right, 0) < 0) {
        return -1;
    }
    return channel;
}

static void vb_StopSound(int channel)
{
    vb_mix_stop(channel);
}

static boolean vb_SoundIsPlaying(int channel)
{
    return vb_mix_playing(channel) != 0;
}

/* Called on the engine's own beat, which is what keeps the stream fed.
 * Silence counts as something to send: a stream that runs dry starts the
 * next sound with a click. */
static void vb_UpdateSound(void)
{
    if (sound_up) {
        vb_mix_pump();
    }
}

/* Read now rather than when a sound is first heard: the alternative is a
 * seek in the middle of the moment the sound was for. */
static void vb_PrecacheSounds(sfxinfo_t *sounds, int num_sounds)
{
    int i;

    for (i = 0; i < num_sounds; ++i) {
        sfx_of(&sounds[i]);
    }
}

static boolean vb_InitSound(boolean use_sfx_prefix)
{
    sfx_prefix = use_sfx_prefix;
    if (vb_sound_open("doom", NULL) < 0) {
        fprintf(stderr, "doom: no sound service; playing without it\n");
        return false;
    }
    sound_up = true;
    printf("I_InitSound: mixing %d sounds into the system's stream\n", VB_MIX_VOICES);
    return true;
}

static void vb_ShutdownSound(void)
{
    if (!sound_up) {
        return;
    }
    vb_mix_stop_all();
    vb_sound_close();
    sound_up = false;
}

static snddevice_t vb_sound_devices[] = {
    SNDDEVICE_SB,
    SNDDEVICE_PAS,
    SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS,
    SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module = {
    vb_sound_devices,
    sizeof(vb_sound_devices) / sizeof(vb_sound_devices[0]),
    vb_InitSound,
    vb_ShutdownSound,
    vb_GetSfxLumpNum,
    vb_UpdateSound,
    vb_UpdateSoundParams,
    vb_StartSound,
    vb_StopSound,
    vb_SoundIsPlaying,
    vb_PrecacheSounds,
};

/* ---- music ----------------------------------------------------------- *
 *
 * None. A wad's music is a score to be played by an instrument, not a
 * recording, so playing it means a sequencer and a synthesiser, and this
 * system has neither yet. The engine takes a module that declines
 * everything, which is how it knows there is no music rather than waiting
 * on one that never arrives.
 */

static boolean vb_InitMusic(void) { return false; }
static void vb_ShutdownMusic(void) {}
static void vb_SetMusicVolume(int volume) { (void) volume; }
static void vb_PauseMusic(void) {}
static void vb_ResumeMusic(void) {}
static void *vb_RegisterSong(void *data, int len) { (void) data; (void) len; return NULL; }
static void vb_UnRegisterSong(void *handle) { (void) handle; }
static void vb_PlaySong(void *handle, boolean looping) { (void) handle; (void) looping; }
static void vb_StopSong(void) {}
static boolean vb_MusicIsPlaying(void) { return false; }
static void vb_PollMusic(void) {}

static snddevice_t vb_music_devices[] = {
    SNDDEVICE_GENMIDI,
};

music_module_t DG_music_module = {
    vb_music_devices,
    sizeof(vb_music_devices) / sizeof(vb_music_devices[0]),
    vb_InitMusic,
    vb_ShutdownMusic,
    vb_SetMusicVolume,
    vb_PauseMusic,
    vb_ResumeMusic,
    vb_RegisterSong,
    vb_UnRegisterSong,
    vb_PlaySong,
    vb_StopSong,
    vb_MusicIsPlaying,
    vb_PollMusic,
};
