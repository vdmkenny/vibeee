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

/* Whether a name can be reached. The modes are not distinguished here:
 * everything readable is writable, so answering otherwise would answer
 * something that was not asked. */
#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
int access(const char *path, int mode);

/* Options, the plain half: single letters, a colon meaning the letter
 * takes a value, and everything after the first non-option left alone. */
int getopt(int argc, char *const argv[], const char *spec);
extern char *optarg;
extern int optind, opterr, optopt;
int fsync(int fd);
pid_t getpid(void);
unsigned int sleep(unsigned int seconds);
int usleep(unsigned int microseconds);

extern char **environ;
int ftruncate(int fd, off_t size);

/* Unpredictable bytes from the machine's own pool, for anything that needs
 * randomness rather than the repeatable sequence rand() gives. No seeding:
 * the kernel gathers what the machine cannot predict. getentropy() takes at
 * most 256 bytes and answers 0, or -1 with errno set; the arc4random pair
 * take any length and always answer. */
#define GETENTROPY_MAX 256
int getentropy(void *buf, size_t len);
void arc4random_buf(void *buf, size_t len);
unsigned int arc4random(void);
#endif
