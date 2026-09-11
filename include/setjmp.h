#ifndef _SETJMP_H
#define _SETJMP_H

/* No non-local exit: a program of this system neither needs one nor has the
   thread of execution to unwind, and a long jump out of a callback would
   leave the engine's own stack where it was. Asked for by vendored code that
   includes the header against an error path it never takes; there is nothing
   behind these declarations, so a file that did call them would not link. */

typedef struct {
    unsigned long slots[8];
} jmp_buf[1];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int value) __attribute__((noreturn));

#endif
