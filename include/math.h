/* math.h: the arithmetic a ported program expects to find already written. */
#ifndef _MATH_H
#define _MATH_H

#define M_E        2.7182818284590452354
#define M_LOG2E    1.4426950408889634074
#define M_LN2      0.69314718055994530942
#define M_LN10     2.30258509299404568402
#define M_PI       3.14159265358979323846
#define M_PI_2     1.57079632679489661923
#define M_PI_4     0.78539816339744830962
#define M_SQRT2    1.41421356237309504880

double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double sinh(double x);
double cosh(double x);
double tanh(double x);

double sqrt(double x);
double cbrt(double x);
double pow(double x, double y);
double exp(double x);
double exp2(double x);
double expm1(double x);
double log1p(double x);
double log(double x);
double log2(double x);
double log10(double x);
double hypot(double x, double y);

double fabs(double x);
double floor(double x);
double ceil(double x);
double round(double x);
double trunc(double x);
double fmod(double x, double y);
double ldexp(double x, int n);
double frexp(double x, int *exponent);
double modf(double x, double *whole);
double fmax(double x, double y);
double fmin(double x, double y);

double nan(const char *tag);
int __isnan(double x);
int __isinf(double x);
int __isfinite(double x);
int __signbit(double x);
double copysign(double x, double y);
double scalbn(double x, int n);
float asinf(float x);
float acosf(float x);

/* A value that is not equal to itself, and one that is larger than every
 * number. Written through the functions above, because neither can be
 * spelled as a constant. */
#define NAN       nan("")
#define INFINITY  (1.0 / 0.0)
#define HUGE_VAL  INFINITY

#define isnan(x)    __isnan((double)(x))
#define isinf(x)    __isinf((double)(x))
#define isfinite(x) __isfinite((double)(x))
#define signbit(x)  __signbit((double)(x))

float sinf(float x);
float cosf(float x);
float tanf(float x);
float atanf(float x);
float atan2f(float y, float x);
float sqrtf(float x);
float powf(float x, float y);
float expf(float x);
float logf(float x);
float log10f(float x);
float fabsf(float x);
float floorf(float x);
float ceilf(float x);
float fmodf(float x, float y);

#endif /* _MATH_H */
