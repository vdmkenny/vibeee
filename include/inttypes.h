/* inttypes.h: how to print and read the sized integer types.
 *
 * The widths are this machine's: int is thirty-two bits and long is too,
 * long long is sixty-four. So the format letters follow from that and
 * nothing here has to be guessed at.
 */
#ifndef _INTTYPES_H
#define _INTTYPES_H

#include <stdint.h>

#define PRId8   "d"
#define PRIi8   "i"
#define PRIu8   "u"
#define PRIo8   "o"
#define PRIx8   "x"
#define PRIX8   "X"

#define PRId16  "d"
#define PRIi16  "i"
#define PRIu16  "u"
#define PRIo16  "o"
#define PRIx16  "x"
#define PRIX16  "X"

#define PRId32  "d"
#define PRIi32  "i"
#define PRIu32  "u"
#define PRIo32  "o"
#define PRIx32  "x"
#define PRIX32  "X"

#define PRId64  "lld"
#define PRIi64  "lli"
#define PRIu64  "llu"
#define PRIo64  "llo"
#define PRIx64  "llx"
#define PRIX64  "llX"

/* A pointer and a size are both a word wide here, which is what makes
 * these the same as the thirty-two bit ones. */
#define PRIdPTR PRId32
#define PRIiPTR PRIi32
#define PRIuPTR PRIu32
#define PRIxPTR PRIx32
#define PRIXPTR PRIX32

#define PRIdMAX PRId64
#define PRIiMAX PRIi64
#define PRIuMAX PRIu64
#define PRIxMAX PRIx64
#define PRIXMAX PRIX64

#define SCNd8   "hhd"
#define SCNu8   "hhu"
#define SCNx8   "hhx"
#define SCNd16  "hd"
#define SCNu16  "hu"
#define SCNx16  "hx"
#define SCNd32  "d"
#define SCNu32  "u"
#define SCNx32  "x"
#define SCNd64  "lld"
#define SCNu64  "llu"
#define SCNx64  "llx"
#define SCNdPTR SCNd32
#define SCNuPTR SCNu32
#define SCNxPTR SCNx32

typedef long long          intmax_t;
typedef unsigned long long uintmax_t;

#endif /* _INTTYPES_H */
