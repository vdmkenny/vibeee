/* strings.h: the string comparisons that ignore case.
 *
 * Separate from <string.h> because POSIX put them here, and ported code
 * includes whichever one it was written against. The functions are the
 * same ones either way. */
#ifndef _STRINGS_H
#define _STRINGS_H

#include <stddef.h>

int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, size_t limit);

#endif /* _STRINGS_H */
