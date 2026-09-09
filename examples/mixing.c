/* Several sounds at once, which one stream cannot carry on its own.
 *
 * Shaped like a game's audio: each sound goes in a slot and is left to
 * play, and the loop does nothing but keep the stream fed. The mixing is
 * the system's, so what a program of this kind writes is which sound goes
 * where and how loud, and nothing about samples at all. */

#include <math.h>
#include <stdio.h>
#include <vibeee.h>

#define MS 1200

/* One cycle of a sine, which a looping voice turns into a held note. The
 * rate it is played back at decides the pitch, so the same cycle at two
 * rates is two notes and there is one buffer rather than two. */
#define CYCLE 64
static short wave[CYCLE];

int main(void)
{
    vb_sound shape;
    int i, done = 0, wanted;

    if (vb_sound_open("mixing", VB_SOUND_PROMPT, &shape) != 0) {
        fprintf(stderr, "mixing: no sound service\n");
        return 1;
    }

    for (i = 0; i < CYCLE; i++) {
        wave[i] = (short) (7000.0 * sin(2.0 * M_PI * (double) i / (double) CYCLE));
    }

    /* Three notes of a chord, each leaning to a different side. The rate
     * given is the rate the cycle stands for, so a cycle of 64 samples
     * called 440 times 64 a second sounds at 440 hertz. */
    vb_mix_start(0, wave, CYCLE, 440 * CYCLE, 16, VB_MIX_FULL, 90, 1);
    vb_mix_start(1, wave, CYCLE, 554 * CYCLE, 16, 160, 160, 1);
    vb_mix_start(2, wave, CYCLE, 659 * CYCLE, 16, 90, VB_MIX_FULL, 1);

    printf("mixing: three notes at %u Hz, %u channels, %u bits\n",
           shape.rate, shape.channels, shape.bits);

    /* Hand over what there is room for, then wait to be told there is
     * room again. The waiting is the point: the service signals as each
     * period drains, and a loop that polls instead takes the processor
     * the service needs to drain it, which on one core is how a tone
     * comes out full of holes. */
    wanted = (int) shape.rate * MS / 1000;
    while (done < wanted) {
        int n = vb_mix_pump();
        if (n < 0) {
            fprintf(stderr, "mixing: the stream went away\n");
            return 1;
        }
        done += n;
        vb_sound_wait(50000);
    }

    /* The middle note alone, to show a slot being taken away without
     * disturbing the others. */
    vb_mix_stop(0);
    vb_mix_stop(2);
    done = 0;
    wanted = (int) shape.rate * 400 / 1000;
    while (done < wanted) {
        int n = vb_mix_pump();
        if (n > 0) done += n;
        vb_sound_wait(50000);
    }

    vb_mix_stop_all();
    while (!vb_sound_drained()) vb_sound_wait(50000);
    vb_sound_close();
    printf("mixing: done\n");
    return 0;
}
