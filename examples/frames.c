/* A C program that draws its own pixels, to prove the system can host one.
 *
 * Shaped like a game rather than like a demo: a small back buffer scaled
 * up into the framebuffer every frame, keys read without blocking, and
 * the frame rate measured. That is the whole of what a ported game asks
 * of a system, so if this runs, one can. */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vibeee.h>

#define BACK_W 320
#define BACK_H 200
#define SCALE  2

static unsigned int back[BACK_W * BACK_H];

static unsigned long long now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (unsigned long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Something that moves. Integer arithmetic, the way a game's renderer
 * works: the floating point is exercised once per frame rather than once
 * per pixel, because that is where a renderer actually uses it. */
static void paint(int tick)
{
    /* One transcendental per frame, standing in for the trigonometry a
     * renderer does per view rather than per pixel. */
    int wobble = (int)(32.0 * sin(tick / 8.0));

    for (int y = 0; y < BACK_H; y++) {
        int dy = y - BACK_H / 2;
        for (int x = 0; x < BACK_W; x++) {
            int dx = x - BACK_W / 2;
            int v = ((dx * dx + dy * dy) / 64 + tick * 3 + wobble) & 0xFF;
            back[y * BACK_W + x] = ((unsigned)v << 16) | ((unsigned)(255 - v) << 8) | 0x40;
        }
    }
}

/* The back buffer into the screen, scaled and centred. Integer scaling,
 * because a game's pixels should stay square and a fractional one costs
 * more than it is worth on this machine. */
static void present(unsigned int *screen, const vb_display *d, int tick)
{
    int left = (d->width - BACK_W * SCALE) / 2;
    int top = (d->height - BACK_H * SCALE) / 2;
    if (left < 0) left = 0;
    if (top < 0) top = 0;

    for (int y = 0; y < BACK_H && top + y * SCALE + SCALE <= d->height; y++) {
        for (int s = 0; s < SCALE; s++) {
            unsigned int *row = screen + (size_t)(top + y * SCALE + s) * d->stride_px + left;
            const unsigned int *from = &back[y * BACK_W];
            for (int x = 0; x < BACK_W && left + x * SCALE + SCALE <= d->width; x++) {
                for (int k = 0; k < SCALE; k++) row[x * SCALE + k] = from[x];
            }
        }
    }
    (void)tick;
}

int main(void)
{
    vb_display screen;
    unsigned int *pixels = vb_display_acquire(&screen);
    if (pixels == NULL) {
        fprintf(stderr, "frames: the screen is not available\n");
        return 1;
    }

    unsigned long long started = now_ms();
    unsigned long long painting = 0;
    unsigned long long presenting = 0;
    int frames = 0;
    int running = 1;

    while (running) {
        unsigned long long a = now_ms();
        paint(frames);
        unsigned long long b = now_ms();
        present(pixels, &screen, frames);
        unsigned long long c = now_ms();
        painting += b - a;
        presenting += c - b;
        frames++;

        vb_key keys[8];
        int n = vb_key_read(keys, 8, 0);
        for (int i = 0; i < n; i++) {
            if (!keys[i].pressed) continue;
            if (keys[i].code == VB_KEY_ESCAPE || keys[i].code == VB_KEY_Q) running = 0;
        }

        if (now_ms() - started >= 5000) running = 0;
    }

    unsigned long long took = now_ms() - started;
    vb_display_release();

    printf("frames: %dx%d at %d bits, stride %d\n",
           screen.width, screen.height, 32, screen.stride_px);
    printf("frames: %d frames in %llu ms", frames, took);
    if (took > 0) printf(" = %llu per second", (unsigned long long)frames * 1000 / took);
    printf("\n");
    if (frames > 0) {
        printf("frames: drawing %llu us a frame, showing %llu us a frame\n",
               painting * 1000 / frames, presenting * 1000 / frames);
    }
    return 0;
}
