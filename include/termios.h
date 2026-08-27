#ifndef _TERMIOS_H
#define _TERMIOS_H

#define NCCS 32

struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
    unsigned char c_line;
    unsigned char c_cc[NCCS];
    unsigned int c_ispeed;
    unsigned int c_ospeed;
};

/* The two that decide anything here: together they are the whole difference
 * between a line discipline that assembles and echoes lines and one that does
 * neither. The rest are kept as written and handed back unchanged, so saving
 * and restoring the old settings gives back exactly what was there. */
#define ICANON 0x0002
#define ECHO   0x0008

#define ISIG   0x0001
#define IEXTEN 0x8000
#define IXON   0x0400
#define ICRNL  0x0100
#define BRKINT 0x0002
#define INPCK  0x0010
#define ISTRIP 0x0020
#define OPOST  0x0001
#define CS8    0x0030

#define VMIN  6
#define VTIME 5

#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2

int tcgetattr(int fd, struct termios *out);
int tcsetattr(int fd, int when, const struct termios *wanted);
#endif
