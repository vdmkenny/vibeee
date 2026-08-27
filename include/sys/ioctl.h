#ifndef _SYS_IOCTL_H
#define _SYS_IOCTL_H

#define TIOCGWINSZ 0x5413

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

/* Whitelisted, and the list is short on purpose: ioctl is where a C library
 * becomes a grab bag. Anything not here says so rather than returning a zero
 * that reads as success. */
int ioctl(int fd, unsigned long request, ...);
#endif
