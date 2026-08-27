/* A C program, to prove the library and the toolchain rather than to be
 * useful. Touches the parts a port depends on first: arguments, formatted
 * output, allocation, string handling and the size of the screen. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    printf("greet: %d argument%s\n", argc, argc == 1 ? "" : "s");
    for (int i = 0; i < argc; i++)
        printf("  argv[%d] = %s\n", i, argv[i]);

    char *copy = strdup("allocated and copied");
    if (copy == NULL) {
        fprintf(stderr, "greet: out of memory\n");
        return 1;
    }
    printf("  strdup   = %s (%zu bytes)\n", copy, strlen(copy));
    free(copy);

    char buf[64];
    snprintf(buf, sizeof buf, "%-8s|%8s|%05d|%#x", "left", "right", 42, 48879);
    printf("  snprintf = %s\n", buf);

    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0)
        printf("  console  = %dx%d\n", ws.ws_col, ws.ws_row);

    printf("  cwd      = %s\n", getcwd(buf, sizeof buf));
    return 0;
}
