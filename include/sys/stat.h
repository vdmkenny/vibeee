/* sys/stat.h: what a name is, without opening it. */
#ifndef _SYS_STAT_H
#define _SYS_STAT_H

#include <sys/types.h>

#define S_IFMT   0170000
#define S_IFDIR  0040000
#define S_IFREG  0100000

#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)

/* Everything reachable here is readable and writable, so the mode bits
 * carry the kind and nothing else. The fields this system has no answer
 * for are zero rather than invented. */
struct stat {
    unsigned int  st_mode;
    long          st_size;
    long          st_mtime;
    unsigned int  st_dev;
    unsigned int  st_ino;
    unsigned int  st_nlink;
    unsigned int  st_uid;
    unsigned int  st_gid;
};

int stat(const char *path, struct stat *into);
int mkdir(const char *path, mode_t mode);

#endif /* _SYS_STAT_H */
