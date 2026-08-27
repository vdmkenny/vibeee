#ifndef _STDLIB_H
#define _STDLIB_H
#include <stddef.h>
#include <sys/types.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void *malloc(size_t size);
void free(void *pointer);
void *calloc(size_t count, size_t size);
void *realloc(void *pointer, size_t size);
int posix_memalign(void **out, size_t alignment, size_t size);

void exit(int status) __attribute__((noreturn));
void _exit(int status) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int atexit(void (*handler)(void));

/* No fork: there is no address-space clone in the kernel and no overcommit
 * story behind one. A port that wanted `fork(); exec(...)` wants posix_spawn,
 * and one that wanted `fork(); work()` wants a thread. */

long strtol(const char *text, char **end, int base);
unsigned long strtoul(const char *text, char **end, int base);
int atoi(const char *text);
long atol(const char *text);
int abs(int value);
long labs(long value);

void qsort(void *base, size_t count, size_t size,
           int (*compare)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t count, size_t size,
              int (*compare)(const void *, const void *));

char *getenv(const char *name);
#endif
