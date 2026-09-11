#ifndef _DLFCN_H
#define _DLFCN_H

/* No shared objects: every program here is one static image, and there is no
   loader to map another into it. `dlopen` answers nothing and `dlerror` says
   why, which is what a script asking for a module written in C gets told.
   See `src/user/libc/dlfcn.zig`. */

#define RTLD_LAZY   0x01
#define RTLD_NOW    0x02
#define RTLD_LOCAL  0x00
#define RTLD_GLOBAL 0x04

void *dlopen(const char *filename, int flags);
void *dlsym(void *handle, const char *name);
int dlclose(void *handle);
char *dlerror(void);

#endif
