/* The image decoder, instantiated.
 *
 * stb_image is a header that carries its own implementation; this is the one
 * translation unit that asks for it, and the one place its configuration is
 * written down. The header itself is vendored unmodified, so an update is a
 * re-fetch rather than a merge.
 *
 * Which formats are compiled in is the build's decision, not this file's:
 * a viewer wants JPEG and the desktop behind it does not, and the difference
 * is tens of kilobytes on a machine with four gigabytes of disk. Anything not
 * named by a -DSTBI_ONLY_ flag is left out of the binary entirely.
 */

/* No file handles. The caller reads the bytes and passes them, which is what
 * makes this usable from a program with no notion of a FILE and testable on
 * a host with no machine under it. */
#define STBI_NO_STDIO

/* One thread, so the failure reason is a plain global rather than something
 * the compiler has to arrange per thread. */
#define STBI_NO_THREAD_LOCALS

/* Floating-point paths, for high-dynamic-range images nothing here shows.
 * Leaving them out keeps `pow` and its neighbours out of the binary. */
#define STBI_NO_LINEAR
#define STBI_NO_HDR

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
