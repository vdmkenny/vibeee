#ifndef _UNISTD_H
#define _UNISTD_H
#include <stddef.h>
#include <sys/types.h>

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

/* A descriptor is a kernel handle. There is no table in the library mapping
 * one to the other, which is why there is no dup2 onto a chosen number. */
int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
off_t lseek(int fd, off_t offset, int whence);
int unlink(const char *path);
int rmdir(const char *path);
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
int isatty(int fd);
int fsync(int fd);
pid_t getpid(void);
unsigned int sleep(unsigned int seconds);
int usleep(unsigned int microseconds);

extern char **environ;
#endif
