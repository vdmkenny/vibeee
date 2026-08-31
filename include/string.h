#ifndef _STRING_H
#define _STRING_H
#include <stddef.h>
#include <sys/types.h>

void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
void *memset(void *dest, int value, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *haystack, int value, size_t n);

size_t strlen(const char *s);
size_t strnlen(const char *s, size_t limit);

/* How many leading characters are in the set, and how many are not: the
 * two halves of splitting a string by hand. */
size_t strspn(const char *s, const char *set);
size_t strcspn(const char *s, const char *set);
char *strpbrk(const char *s, const char *set);

/* Copy until the byte has been copied, or until count bytes have. */
void *memccpy(void *into, const void *from, int byte, size_t count);
char *strcpy(char *dest, const char *src);
char *strncpy(char *dest, const char *src, size_t n);
char *strcat(char *dest, const char *src);
char *strncat(char *dest, const char *src, size_t n);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
int strcasecmp(const char *a, const char *b);
char *strchr(const char *s, int value);
char *strrchr(const char *s, int value);
char *strstr(const char *haystack, const char *needle);
char *strdup(const char *s);
char *strndup(const char *s, size_t limit);
char *strtok(char *text, const char *separators);
char *strtok_r(char *text, const char *separators, char **save);
char *strerror(int code);
#endif
