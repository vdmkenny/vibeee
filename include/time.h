#ifndef _TIME_H
#define _TIME_H
#include <sys/types.h>

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1

struct timespec { long tv_sec; long tv_nsec; };
struct timeval { long tv_sec; long tv_usec; };

struct tm {
    int tm_sec, tm_min, tm_hour;
    int tm_mday, tm_mon, tm_year;
    int tm_wday, tm_yday, tm_isdst;
    /* Nothing west or east of UTC, and no name for the zone there is not:
       one clock, no timezone table. Kept because a port reads them. */
    long tm_gmtoff;
    const char *tm_zone;
};

int clock_gettime(int which, struct timespec *out);
int gettimeofday(struct timeval *out, void *timezone);
time_t time(time_t *out);
int nanosleep(const struct timespec *wanted, struct timespec *left);

/* UTC, always. With one clock and no timezone table there is no local time to
 * be different, so localtime is gmtime. */
struct tm *gmtime(const time_t *seconds);
struct tm *localtime(const time_t *seconds);
/* The same, written where the caller says. */
struct tm *localtime_r(const time_t *seconds, struct tm *out);
#endif
