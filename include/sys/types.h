#ifndef _SYS_TYPES_H
#define _SYS_TYPES_H

/* size_t, NULL and ptrdiff_t come from the compiler's own stddef.h: it ships
 * them, they have to match its idea of a pointer, and a second definition here
 * would be a second thing to get wrong. What is below is what C leaves to the
 * system. */
#include <stddef.h>

typedef long ssize_t;
typedef int pid_t;
typedef long off_t;
typedef long time_t;
typedef unsigned int mode_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
#endif
