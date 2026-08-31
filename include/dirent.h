/* dirent.h: looking through a directory. */
#ifndef _DIRENT_H
#define _DIRENT_H

#define DT_DIR 4
#define DT_REG 8

struct dirent {
    unsigned int  d_ino;
    unsigned char d_type;   /* DT_DIR or DT_REG */
    char          d_name[256];
};

typedef struct __dir DIR;

DIR *opendir(const char *path);

/* The next entry, or NULL at the end. The answer points into the open
 * directory and stands until the next call, so a caller keeping one
 * copies the name out. */
struct dirent *readdir(DIR *dir);

int closedir(DIR *dir);

#endif /* _DIRENT_H */
