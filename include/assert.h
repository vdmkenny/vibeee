/* assert.h: the check a program leaves in to catch itself.
 *
 * Defining NDEBUG before including this turns every assertion into
 * nothing, which is what a release build does. */
#ifndef _ASSERT_H
#define _ASSERT_H

void __assert_fail(const char *claim, const char *file, int line);

#endif /* _ASSERT_H */

/* Outside the guard on purpose: a program may include this more than
 * once with NDEBUG set differently between them, and the standard says
 * the last one wins. */
#undef assert
#ifdef NDEBUG
#define assert(claim) ((void)0)
#else
#define assert(claim) \
    ((claim) ? (void)0 : __assert_fail(#claim, __FILE__, __LINE__))
#endif
