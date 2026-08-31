#ifndef _STDIO_H
#define _STDIO_H
#include <stddef.h>
#include <sys/types.h>
#include <stdarg.h>

/* A kilobyte rather than the eight most libraries use: on a machine with 512 MB
 * shared between everything, twenty open files should not be 160 KB of buffer
 * nobody has written to. */
#define BUFSIZ 1024
#define EOF (-1)

#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

typedef struct __FILE FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

FILE *fopen(const char *path, const char *mode);
FILE *fdopen(int fd, const char *mode);
int fclose(FILE *stream);
int fflush(FILE *stream);
int setvbuf(FILE *stream, char *buffer, int mode, size_t size);
int fileno(FILE *stream);

int fputc(int byte, FILE *stream);
int putc(int byte, FILE *stream);
int putchar(int byte);
int fputs(const char *text, FILE *stream);
int puts(const char *text);
size_t fwrite(const void *source, size_t size, size_t count, FILE *stream);

int fgetc(FILE *stream);
int getc(FILE *stream);
int getchar(void);
int ungetc(int byte, FILE *stream);
char *fgets(char *into, int size, FILE *stream);
size_t fread(void *into, size_t size, size_t count, FILE *stream);

int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
void rewind(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);
void clearerr(FILE *stream);
void perror(const char *prefix);

/* Take a name away, whether it names a file or an empty directory. */
int remove(const char *path);
int rename(const char *from, const char *to);

int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int sprintf(char *into, const char *format, ...);
int snprintf(char *into, size_t size, const char *format, ...);
int vprintf(const char *format, va_list args);
int vfprintf(FILE *stream, const char *format, va_list args);
int vsprintf(char *into, const char *format, va_list args);
int vsnprintf(char *into, size_t size, const char *format, va_list args);
int sscanf(const char *text, const char *format, ...);
int vsscanf(const char *text, const char *format, va_list args);
ssize_t getline(char **into, size_t *capacity, FILE *stream);
ssize_t getdelim(char **into, size_t *capacity, int delimiter, FILE *stream);
#endif
