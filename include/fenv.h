#ifndef _FENV_H
#define _FENV_H

/* One rounding mode, the default, and no traps to raise: this system runs
   one program at a time on one core with the FPU in its power-on state, and
   no one asks for it to be otherwise. Asked for by vendored code that
   includes the header for a rounding query it never makes; there is nothing
   behind these declarations, so a file that did call them would not link. */

#define FE_INVALID    0x01
#define FE_DIVBYZERO  0x02
#define FE_OVERFLOW   0x04
#define FE_UNDERFLOW  0x08
#define FE_INEXACT    0x10

#define FE_TONEAREST  0
#define FE_DOWNWARD   1
#define FE_UPWARD     2
#define FE_TOWARDZERO 3

typedef struct {
    unsigned short control;
    unsigned short status;
} fenv_t;

typedef unsigned short fexcept_t;

int fegetround(void);
int fesetround(int mode);
int fegetenv(fenv_t *env);
int fesetenv(const fenv_t *env);

#endif
