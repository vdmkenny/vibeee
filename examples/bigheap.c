/* Whether a program with a working set can have one.
 *
 * A ported game asks for its heap in one block and keeps it. This asks
 * for the same, writes across the whole of it, and reads it back, because
 * an allocation that is not backed everywhere fails where it is touched
 * rather than where it was made. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WANTED (16 * 1024 * 1024)

int main(void)
{
    unsigned char *zone = malloc(WANTED);
    if (zone == NULL) {
        fprintf(stderr, "bigheap: %d MiB refused\n", WANTED / (1024 * 1024));
        return 1;
    }
    printf("bigheap: %d MiB allocated\n", WANTED / (1024 * 1024));

    /* Every page, so nothing is merely promised. */
    for (size_t at = 0; at < WANTED; at += 4096) zone[at] = (unsigned char)(at / 4096);

    int wrong = 0;
    for (size_t at = 0; at < WANTED; at += 4096) {
        if (zone[at] != (unsigned char)(at / 4096)) wrong++;
    }
    printf("bigheap: %d pages read back wrong\n", wrong);

    memset(zone, 0, WANTED);
    printf("bigheap: cleared\n");

    free(zone);
    printf("bigheap: returned\n");
    return wrong == 0 ? 0 : 1;
}
