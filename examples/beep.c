/* A C program that makes a sound, to prove the system can host one.
 *
 * Shaped like a game's audio loop rather than like a demo: mix exactly
 * what there is room for, hand it over, and never wait, because a sound
 * loop that blocks is a picture that stops. */

#include <math.h>
#include <stdio.h>
#include <vibeee.h>

#define HERTZ  998
#define MS     400

int main(void)
{
    vb_sound shape;
    if (vb_sound_open("beep", &shape) != 0) {
        fprintf(stderr, "beep: no sound service\n");
        return 1;
    }
    printf("beep: %u Hz, %u channels, %u bits\n",
           shape.rate, shape.channels, shape.bits);

    /* One cycle, worked out once. A sound loop that computes a sine per
     * sample is a sound loop that cannot keep up, and what comes out is
     * not the tone asked for but the gaps between the parts of it. */
    int cycle = (int)(shape.rate / HERTZ);
    short wave[128];
    if (cycle > (int)(sizeof wave / sizeof wave[0])) cycle = sizeof wave / sizeof wave[0];
    for (int i = 0; i < cycle; i++) {
        wave[i] = (short)(8000.0 * sin(2.0 * M_PI * (double)i / (double)cycle));
    }

    long wanted = (long)shape.rate * MS / 1000;
    long done = 0;

    short block[512 * 2];
    while (done < wanted) {
        int room = vb_sound_room();
        if (room <= 0) {                       /* full: wait, never spin */
            vb_sound_wait(VB_WAIT_FOREVER);
            continue;
        }
        if (room > 512) room = 512;
        if (room > wanted - done) room = (int)(wanted - done);

        for (int i = 0; i < room; i++) {
            short v = wave[(done + i) % cycle];
            for (int c = 0; c < shape.channels; c++) block[i * shape.channels + c] = v;
        }
        done += vb_sound_write(block, room);
    }

    /* Written is not heard: the ring drains at the speed of sound. */
    while (!vb_sound_drained()) vb_sound_wait(10000);
    vb_sound_close();
    printf("beep: %ld frames played\n", done);
    return 0;
}
