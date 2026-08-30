/* The compiler and platform half of the lwIP port.
 *
 * Types come from the compiler's own stdint; byte order is the target's.
 * The three platform hooks are implemented in netd's Zig and exported with
 * the C ABI, the same shape platd gives uACPI its kernel API. */
#ifndef VIBEEE_LWIP_CC_H
#define VIBEEE_LWIP_CC_H

#define BYTE_ORDER LITTLE_ENDIAN

/* ssize_t comes from this system's own libc headers when string.h pulls
 * sys/types.h in; naming SSIZE_MAX here keeps arch.h from typedefing a
 * second, disagreeing one. */
#define SSIZE_MAX INT_MAX

/* No libc inttypes here; the format macros only ever feed diagnostics,
 * which are compiled out anyway. */
#define LWIP_NO_INTTYPES_H 1
#define X8_F "02x"
#define U16_F "u"
#define S16_F "d"
#define X16_F "x"
#define U32_F "u"
#define S32_F "d"
#define X32_F "x"
#define SZT_F "u"

unsigned int netd_lwip_rand(void);
#define LWIP_RAND() ((u32_t)netd_lwip_rand())

void netd_lwip_assert(const char *message);
#define LWIP_PLATFORM_ASSERT(x) netd_lwip_assert(x)

/* Diagnostics stay quiet: LWIP_DEBUG is never defined, and defining the
 * macro anyway keeps arch.h from reaching for stdio. */
#define LWIP_PLATFORM_DIAG(x)

#endif
