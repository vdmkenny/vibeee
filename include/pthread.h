#ifndef _PTHREAD_H
#define _PTHREAD_H

#include <time.h>

/* One thread. A program of this system is built single-threaded, so a lock
   guards nothing and a thread made is a thread that cannot be made: QuickJS
   asks for these in its atomics, which is the one part of it that presumes
   another thread to wait on. The mutex calls succeed and do nothing, which
   is what a lock means where there is no one else to hold it; the condition
   calls succeed and wake at once, so `Atomics.wait` answers rather than
   stopping a program that has nothing to wake it. See
   `src/user/libc/pthread.zig`. */

typedef int pthread_t;
typedef int pthread_mutex_t;
typedef int pthread_cond_t;
typedef struct {
    int detachstate;
} pthread_attr_t;
typedef struct {
    int unused;
} pthread_mutexattr_t;
typedef struct {
    int unused;
} pthread_condattr_t;

#define PTHREAD_MUTEX_INITIALIZER 0
#define PTHREAD_COND_INITIALIZER 0

int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);
int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);
int pthread_mutex_destroy(pthread_mutex_t *mutex);
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_cond_signal(pthread_cond_t *cond);
int pthread_cond_broadcast(pthread_cond_t *cond);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           const struct timespec *when);
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start)(void *), void *arg);
int pthread_join(pthread_t thread, void **value);

#endif
