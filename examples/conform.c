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
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;

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

    snprintf(b, sizeof b, "%s|%10s|%-10s|%.3s", "abc", "abc", "abc", "abcdef");
    say("printf.string", b);

    snprintf(b, sizeof b, "%c|%%", 'z');
    say("printf.char", b);

    snprintf(b, sizeof b, "%f|%.2f|%.0f|%8.3f", 3.5, 3.14159, 7.5, -1.5);
    say("printf.float", b);

    snprintf(b, sizeof b, "%e|%g|%g", 1234.5, 0.0001, 100000.0);
    say("printf.float.form", b);

    /* snprintf answers what it would have written, not what it did. */
    char small[4];
    int wanted = snprintf(small, sizeof small, "%s", "abcdefgh");
    snprintf(b, sizeof b, "%d|%s", wanted, small);
    say("snprintf.truncated", b);

    int n = sscanf("17 -4 hello", "%d %d %s", &wanted, &n, b);
    say("sscanf.count", n == 3 ? "3" : "wrong");
    sayn("sscanf.value", wanted);
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

    sayn("toupper", toupper('a'));
    sayn("toupper.other", toupper('1'));
    sayn("isdigit", isdigit('7') ? 1 : 0);
    sayn("isalpha.digit", isalpha('7') ? 1 : 0);
    sayn("isspace.tab", isspace('\t') ? 1 : 0);
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
    sorting();
    allocation();
    files(scratch);
    arithmetic();
    printf("--- %d checks\n", checks);
    return 0;
}
