#ifndef _SIGNAL_H
#define _SIGNAL_H

/* There is no asynchronous delivery here, by decision rather than omission: a
 * handler that can run between any two instructions is a source of bugs that
 * only appear under load, and this system has other ways to say every one of
 * the things signals are used to say.
 *
 * `signal` accepts a handler and returns the previous one so ported code
 * compiles and runs. Nothing calls it. A program that needs to know the window
 * changed size should ask, and one that needs to stop should be told through
 * the channel it already has. */

#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGKILL 9
#define SIGSEGV 11
#define SIGPIPE 13
#define SIGTERM 15
#define SIGCONT 18
#define SIGWINCH 28

typedef void (*sighandler_t)(int);

#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIG_ERR ((sighandler_t)-1)

sighandler_t signal(int which, sighandler_t handler);
int raise(int which);
#endif
