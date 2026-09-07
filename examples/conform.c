/* Whether this system's C library answers what a C library answers.
 *
 * Every line is a fact with one right answer, printed the same way on
 * both sides, so the check is a diff rather than a judgement: build it
 * with the host's compiler, build it with `eeecc`, and the two outputs
 * either match or name what does not.
 *
 * What is exercised is what a ported program leans on: reading a file by
 * seeking around it, formatting, the string functions that have a
 * surprise in them, sorting, and allocation that grows. Nothing here
 * depends on the machine's word size, its pointers, or its locale. */

#include <ctype.h>
#include <inttypes.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>

static int checks;

static int by_key(const void *a, const void *b)
{
    int x = *(const int *)a;
    int y = *(const int *)b;
    return (x > y) - (x < y);
}

static void say(const char *what, const char *got)
{
    printf("%03d %-22s %s\n", ++checks, what, got);
}

static void sayn(const char *what, long got)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%ld", got);
    say(what, buf);
}

/* Separate, because `long` is not the same width everywhere and an
 * unsigned value printed as signed reads differently on each side. */
static void sayu(const char *what, unsigned long got)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%lu", got);
    say(what, buf);
}

/* ---- formatting ------------------------------------------------------ */

static void formatting(void)
{
    char b[64];

    snprintf(b, sizeof b, "%d|%5d|%-5d|%05d", 42, 42, 42, 42);
    say("printf.int", b);

    snprintf(b, sizeof b, "%d|%d", -2147483647 - 1, 2147483647);
    say("printf.int.ends", b);

    snprintf(b, sizeof b, "%u|%x|%X|%o", 4000000000u, 48879u, 48879u, 64u);
    say("printf.bases", b);

    snprintf(b, sizeof b, "%ld|%lu", 1234567890L, 4000000000UL);
    say("printf.long", b);

    /* A wide argument takes eight bytes of the call, and what follows it
     * begins after those eight. */
    snprintf(b, sizeof b, "%lld|%llu|%s|%d", -1234567890123LL, 18446744073709551615ULL, "after", 7);
    say("printf.longlong", b);

    snprintf(b, sizeof b, "%llx|%llX|%llo", 0xDEADBEEFCAFEBABEULL, 0xDEADBEEFCAFEBABEULL, 0777777777777777777777ULL);
    say("printf.longlong.bases", b);

    int64_t least = INT64_MIN;
    uint64_t most = UINT64_MAX;
    snprintf(b, sizeof b, "%" PRId64 "|%" PRIu64 "|%" PRIx64, least, most, most);
    say("printf.int64", b);

    snprintf(b, sizeof b, "%jd|%zu|%td", (intmax_t)-5, sizeof(int), (ptrdiff_t)(b + 3 - b));
    say("printf.max.size.diff", b);

    /* A narrow argument arrives as an int and keeps only its own bytes. */
    int over_char = 300;
    int over_short = 70000;
    snprintf(b, sizeof b, "%hhd|%hhu|%hd|%hu|%hhd", over_char, over_char, over_short, over_short, -1);
    say("printf.narrow", b);

    snprintf(b, sizeof b, "%s|%10s|%-10s|%.3s", "abc", "abc", "abc", "abcdef");
    say("printf.string", b);

    snprintf(b, sizeof b, "%c|%%", 'z');
    say("printf.char", b);

    snprintf(b, sizeof b, "%f|%.2f|%.0f|%8.3f", 3.5, 3.14159, 7.5, -1.5);
    say("printf.float", b);

    snprintf(b, sizeof b, "%e|%g|%g", 1234.5, 0.0001, 100000.0);
    say("printf.float.form", b);

    /* The zero flag fills between the sign and the digits for a float as
     * for an integer: its precision is already in the digits, so it does
     * not stand in the way of padding. */
    snprintf(b, sizeof b, "%08.2f|%010.3e|%08g|%08.2f", 3.5, 1234.5, 42.0, -3.5);
    say("printf.float.zeropad", b);

    /* The case of the verb is the case of what it spells. */
    snprintf(b, sizeof b, "%E|%G|%e|%g", 1234.5, 0.00001234, 1234.5, 0.00001234);
    say("printf.float.case", b);

    /* Exact halves, which are the cases the two rounding rules disagree
     * about. All of these are representable, so the tie is real rather
     * than an artefact of the nearest double: the answer C gives is the
     * even neighbour, not the far one. */
    snprintf(b, sizeof b, "%.0f|%.0f|%.0f|%.0f|%.0f", 0.5, 1.5, 2.5, 3.5, 4.5);
    say("printf.float.ties", b);

    snprintf(b, sizeof b, "%.0f|%.0f|%.0f", -0.5, -1.5, -2.5);
    say("printf.float.ties.neg", b);

    snprintf(b, sizeof b, "%.2f|%.2f|%.1f|%.1f", 0.125, 0.375, 0.25, 0.75);
    say("printf.float.ties.frac", b);

    /* snprintf answers what it would have written, not what it did. */
    char small[4];
    int wanted = snprintf(small, sizeof small, "%s", "abcdefgh");
    snprintf(b, sizeof b, "%d|%s", wanted, small);
    say("snprintf.truncated", b);

    int n = sscanf("17 -4 hello", "%d %d %s", &wanted, &n, b);
    say("sscanf.count", n == 3 ? "3" : "wrong");
    sayn("sscanf.value", wanted);

    /* A length modifier on a scan says how wide the target is, so a byte
     * target keeps its neighbours and a wide one is filled to the top. */
    int8_t bytes[4] = { 1, 2, 3, 4 };
    sscanf("-5", "%" SCNd8, &bytes[0]);
    snprintf(b, sizeof b, "%d|%d|%d|%d", bytes[0], bytes[1], bytes[2], bytes[3]);
    say("sscanf.int8", b);

    uint8_t octets[2] = { 1, 2 };
    sscanf("ff", "%" SCNx8, &octets[0]);
    snprintf(b, sizeof b, "%u|%u", octets[0], octets[1]);
    say("sscanf.uint8", b);

    int16_t halves[2] = { 1, 2 };
    sscanf("-300", "%" SCNd16, &halves[0]);
    snprintf(b, sizeof b, "%d|%d", halves[0], halves[1]);
    say("sscanf.int16", b);

    int64_t wide = -1;
    uint64_t huge = 0;
    sscanf("123456789012 18446744073709551615", "%" SCNd64 " %" SCNu64, &wide, &huge);
    snprintf(b, sizeof b, "%" PRId64 "|%" PRIu64, wide, huge);
    say("sscanf.int64", b);

    sscanf("-1 ffffffffffffffff", "%" SCNd64 " %" SCNx64, &wide, &huge);
    snprintf(b, sizeof b, "%" PRId64 "|%" PRIx64, wide, huge);
    say("sscanf.int64.ends", b);

    long along = 0;
    sscanf("-4", "%ld", &along);
    sayn("sscanf.long", along);
}

/* ---- strings --------------------------------------------------------- */

static void strings(void)
{
    char b[16];

    /* strncpy pads the whole field with zeroes, which is the surprise. */
    memset(b, 'x', sizeof b);
    strncpy(b, "ab", 8);
    b[8] = '|';
    b[9] = 0;
    say("strncpy.pads", b);

    /* And does not terminate when the source fills the field. */
    memset(b, 0, sizeof b);
    strncpy(b, "abcdefgh", 4);
    b[4] = 0;
    say("strncpy.full", b);

    strcpy(b, "abc");
    strncat(b, "defgh", 2);
    say("strncat", b);

    /* An element wider than any scratch still sorts. */
    struct wide { int key; char pad[400]; };
    static struct wide many[4];
    for (int k = 0; k < 4; k++) { many[k].key = 4 - k; many[k].pad[0] = (char)('a' + k); }
    qsort(many, 4, sizeof many[0], by_key);
    snprintf(b, sizeof b, "%d%d%d%d|%c%c%c%c",
             many[0].key, many[1].key, many[2].key, many[3].key,
             many[0].pad[0], many[1].pad[0], many[2].pad[0], many[3].pad[0]);
    say("qsort.wide", b);

    /* Nothing to read is end of input, which is not the same as nothing
     * matched: the usual loop is written against the difference. */
    int scanned = 0;
    sayn("sscanf.empty", sscanf("", "%d", &scanned));
    sayn("sscanf.nomatch", sscanf("abc", "%d", &scanned));
    sayn("sscanf.one", sscanf("42", "%d", &scanned));

    sayn("iscntrl.eof", iscntrl(EOF) ? 1 : 0);
    sayn("iscntrl.nul", iscntrl(0) ? 1 : 0);
    sayn("iscntrl.del", iscntrl(0x7F) ? 1 : 0);
    sayn("iscntrl.letter", iscntrl('a') ? 1 : 0);

    /* A number too large for the type is the nearest limit, and says so. */
    errno = 0;
    long huge = strtol("99999999999999999999", NULL, 10);
    sayn("strtol.over", huge == LONG_MAX ? 1 : 0);
    sayn("strtol.over.errno", errno == ERANGE ? 1 : 0);
    errno = 0;
    long tiny = strtol("-99999999999999999999", NULL, 10);
    sayn("strtol.under", tiny == LONG_MIN ? 1 : 0);
    sayn("strtol.under.errno", errno == ERANGE ? 1 : 0);
    errno = 0;
    unsigned long past = strtoul("99999999999999999999", NULL, 10);
    sayu("strtoul.over", past == ULONG_MAX ? 1 : 0);
    sayn("strtoul.over.errno", errno == ERANGE ? 1 : 0);
    errno = 0;
    sayn("strtol.fits", strtol("123", NULL, 10));
    sayn("strtol.fits.errno", errno == 0 ? 1 : 0);

    sayn("strcmp.order", strcmp("abc", "abd") < 0 ? -1 : 1);
    sayn("strncmp.equal", strncmp("abcx", "abcy", 3));
    sayn("strcasecmp", strcasecmp("AbC", "aBc"));

    say("strstr.found", strstr("hello world", "lo w") ? "yes" : "no");
    say("strstr.missing", strstr("hello", "xyz") ? "yes" : "no");
    say("strchr.last", strrchr("a/b/c", '/'));

    sayn("strlen", (long)strlen("abcdef"));
    sayn("strnlen.bounded", (long)strnlen("abcdef", 3));

    /* memmove has to survive overlap; memcpy is not asked to. */
    char over[] = "abcdefgh";
    memmove(over + 2, over, 6);
    say("memmove.overlap", over);

    sayn("memcmp", memcmp("abc", "abd", 3) < 0 ? -1 : 1);

    char tokens[] = "one,two,,three";
    char *piece = strtok(tokens, ",");
    b[0] = 0;
    while (piece != NULL) {
        strncat(b, piece, 3);
        strncat(b, ".", 1);
        piece = strtok(NULL, ",");
    }
    say("strtok", b);
}

/* ---- numbers out of text --------------------------------------------- */

static void numbers(void)
{
    char *end;
    sayn("strtol.decimal", strtol("  -123abc", &end, 10));
    say("strtol.end", end);
    sayn("strtol.hex", strtol("0x1f", NULL, 16));
    sayn("strtol.auto", strtol("0x20", NULL, 0));
    sayu("strtoul", strtoul("4000000000", NULL, 10));
    sayn("atoi", atoi("42x"));
    sayn("abs", labs(-7));

    /* Numbers with a point in them, and where the reading stopped. */
    char *rest;
    sayn("strtod.value", (long)(strtod("3.25xyz", &rest) * 100));
    say("strtod.end", rest);
    sayn("strtod.exponent", (long)strtod("-1.5e2", NULL));
    sayn("strtod.leading.space", (long)(strtod("  2.75", NULL) * 100));
    sayn("strtod.nothing", (long)strtod("abc", &rest));
    say("strtod.nothing.end", rest);
    sayn("atof", (long)(atof("0.5") * 100));

    /* The same seed gives the same numbers, which is the whole promise. */
    srand(7);
    const long first = rand();
    srand(7);
    sayn("rand.repeats", rand() == first ? 1 : 0);
    sayn("rand.in.range", first >= 0 && first <= RAND_MAX ? 1 : 0);

    sayn("strspn", (long)strspn("aabxyz", "ab"));
    sayn("strcspn", (long)strcspn("xyzab", "ab"));
    say("strpbrk", strpbrk("hello world", "ow"));
    say("strpbrk.missing", strpbrk("hello", "xyz") ? "found" : "none");

    sayn("toupper", toupper('a'));
    sayn("toupper.other", toupper('1'));
    sayn("isdigit", isdigit('7') ? 1 : 0);
    sayn("isalpha.digit", isalpha('7') ? 1 : 0);
    sayn("isspace.tab", isspace('\t') ? 1 : 0);
}

/* ---- the environment ------------------------------------------------- */

/* What is *in* it differs between machines, so nothing here reads a name
 * the system set. What is checked is the behaviour: a name that is not
 * there, one that is, whether a longer name beginning the same way is a
 * different name, and what overwriting does and does not do. */
static void environment(void)
{
    say("getenv.absent", getenv("VIBEEE_NOT_SET_ANYWHERE") ? "found" : "absent");

    setenv("VIBEEE_T", "one", 1);
    say("setenv.then.get", getenv("VIBEEE_T"));

    setenv("VIBEEE_T", "two", 0);
    say("setenv.no.overwrite", getenv("VIBEEE_T"));

    setenv("VIBEEE_T", "two", 1);
    say("setenv.overwrite", getenv("VIBEEE_T"));

    /* A longer name that begins the same way is a different name. */
    setenv("VIBEEE_TT", "other", 1);
    say("getenv.whole.name", getenv("VIBEEE_T"));

    unsetenv("VIBEEE_T");
    say("unsetenv", getenv("VIBEEE_T") ? "still there" : "gone");
    say("unsetenv.leaves.rest", getenv("VIBEEE_TT"));

    unsetenv("VIBEEE_TT");
    sayn("unsetenv.absent", unsetenv("VIBEEE_NOT_SET_ANYWHERE"));
    sayn("setenv.refuses.sign", setenv("BAD=NAME", "x", 1));
}

/* ---- sorting --------------------------------------------------------- */

static int by_value(const void *a, const void *b)
{
    int x = *(const int *)a;
    int y = *(const int *)b;
    return (x > y) - (x < y);
}

static void sorting(void)
{
    int values[] = { 5, 3, 9, 1, 3, 7, 0, 8 };
    const int count = (int)(sizeof values / sizeof values[0]);
    qsort(values, count, sizeof values[0], by_value);

    char b[64];
    int at = 0;
    for (int i = 0; i < count; i++) at += snprintf(b + at, sizeof b - at, "%d", values[i]);
    say("qsort", b);

    int wanted = 7;
    int *found = bsearch(&wanted, values, count, sizeof values[0], by_value);
    sayn("bsearch", found ? *found : -1);
}

/* ---- allocation ------------------------------------------------------ */

static void allocation(void)
{
    char *grown = malloc(8);
    memcpy(grown, "1234567", 8);
    grown = realloc(grown, 64);
    say("realloc.keeps", grown);

    /* realloc of nothing is malloc, which ports rely on. */
    char *fresh = realloc(NULL, 8);
    say("realloc.null", fresh ? "allocated" : "refused");
    free(fresh);
    free(grown);

    int *zeroed = calloc(16, sizeof(int));
    int sum = 0;
    for (int i = 0; i < 16; i++) sum += zeroed[i];
    sayn("calloc.zeroed", sum);
    free(zeroed);

    /* Any allocation has to suit any type, so the low bits are clear. */
    void *a = malloc(1);
    void *b = malloc(3);
    sayn("malloc.aligned", (((unsigned long)(size_t)a | (unsigned long)(size_t)b) & 7) == 0);
    free(a);
    free(b);
}

/* ---- files ----------------------------------------------------------- */

static void files(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        say("file.create", "refused");
        return;
    }
    for (int i = 0; i < 256; i++) fputc(i, f);
    say("file.written", fwrite("tail", 1, 4, f) == 4 ? "yes" : "no");
    fclose(f);

    f = fopen(path, "rb");
    if (f == NULL) {
        say("file.reopen", "refused");
        return;
    }

    /* A WAD is read by seeking to a directory at the end and back, so
     * this is the pattern that has to be right. */
    fseek(f, 0, SEEK_END);
    sayn("ftell.end", ftell(f));

    fseek(f, -4, SEEK_END);
    char tail[5] = { 0 };
    fread(tail, 1, 4, f);
    say("fread.from.end", tail);

    fseek(f, 65, SEEK_SET);
    sayn("fgetc.at.65", fgetc(f));

    fseek(f, 10, SEEK_CUR);
    sayn("ftell.after.cur", ftell(f));

    unsigned char block[16];
    fseek(f, 0, SEEK_SET);
    sayn("fread.count", (long)fread(block, 1, sizeof block, f));
    sayn("fread.first", block[0]);
    sayn("fread.last", block[15]);

    fseek(f, 0, SEEK_END);
    sayn("feof.before.read", feof(f) ? 1 : 0);
    fgetc(f);
    sayn("feof.after.read", feof(f) ? 1 : 0);
    fclose(f);
    remove(path);
}

/* ---- arithmetic ------------------------------------------------------ */

static void arithmetic(void)
{
    char b[64];
    snprintf(b, sizeof b, "%.4f|%.4f|%.4f", sqrt(2.0), pow(2.0, 10.0), atan2(1.0, 1.0));
    say("math.values", b);

    snprintf(b, sizeof b, "%.4f|%.4f|%.4f", floor(-1.5), ceil(-1.5), fmod(7.5, 2.0));
    say("math.rounding", b);

    int e;
    double m = frexp(12.0, &e);
    snprintf(b, sizeof b, "%.4f|%d", m, e);
    say("math.frexp", b);

    sayn("math.isnan", isnan(NAN) ? 1 : 0);
    sayn("math.isfinite", isfinite(1.0) ? 1 : 0);

    /* Fixed point, which is what a renderer of this era actually uses. */
    long fixed = (long)(1.5 * 65536.0);
    sayn("fixed.mul", (long)(((long long)fixed * fixed) >> 16));
    sayn("shift.arith", (long)(-256 >> 4));
    sayn("div.trunc", (long)(-7 / 2));
    sayn("mod.sign", (long)(-7 % 2));
}

int main(int argc, char **argv)
{
    const char *scratch = argc > 1 ? argv[1] : "conform.tmp";
    formatting();
    strings();
    numbers();
    environment();
    sorting();
    allocation();
    files(scratch);
    arithmetic();
    printf("--- %d checks\n", checks);
    return 0;
}
