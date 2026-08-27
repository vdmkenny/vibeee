#ifndef _FCNTL_H
#define _FCNTL_H
#include <sys/types.h>

#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR 0x0002
#define O_CREAT 0x0040
#define O_TRUNC 0x0200
#define O_APPEND 0x0400
#define O_DIRECTORY 0x10000

int open(const char *path, int flags, ...);
int creat(const char *path, mode_t mode);
int rename(const char *from, const char *to);
int mkdir(const char *path, mode_t mode);
#endif
