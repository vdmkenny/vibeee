//! The arithmetic C programs expect to find already written.
//!
//! Almost none of it is ours. Zig ships two layers of it and both are
//! already in this archive:
//!
//!   * `compiler_rt` implements what the compiler lowers a float builtin
//!     to on a machine without an instruction for it: `sin`, `cos`,
//!     `tan`, `exp`, `exp2`, `log`, `log2`, `log10`, `sqrt`, `fabs`,
//!     `floor`, `ceil`, `round`, `trunc`, `fmod`, `fmax`, `fmin`. They
//!     already carry their C names, so a program calling `sinf` links
//!     against them without anything here.
//!
//!   * `std.math` implements the rest in source: the inverse angles, the
//!     hyperbolics, `pow`, `hypot`, `cbrt`, and taking a float apart.
//!
//! So what is here is the second list wearing its C name, and nothing
//! else. Re-exporting the first list would be worse than redundant: a
//! `sin` that called `@sin` would be a function calling itself, because
//! the builtin lowers to exactly the symbol being defined.

const std = @import("std");

// ---------------------------------------------------------------------------
// Angles
// ---------------------------------------------------------------------------

export fn asin(x: f64) f64 {
    return std.math.asin(x);
}

export fn acos(x: f64) f64 {
    return std.math.acos(x);
}

export fn atan(x: f64) f64 {
    return std.math.atan(x);
}

/// The angle of a point, taking the quadrant from the signs of both parts,
/// which is the whole reason it takes two arguments rather than a ratio.
export fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

export fn sinh(x: f64) f64 {
    return std.math.sinh(x);
}

export fn cosh(x: f64) f64 {
    return std.math.cosh(x);
}

export fn tanh(x: f64) f64 {
    return std.math.tanh(x);
}

export fn asinf(x: f32) f32 {
    return std.math.asin(x);
}

export fn acosf(x: f32) f32 {
    return std.math.acos(x);
}

export fn atanf(x: f32) f32 {
    return std.math.atan(x);
}

export fn atan2f(y: f32, x: f32) f32 {
    return std.math.atan2(y, x);
}

// ---------------------------------------------------------------------------
// Powers and roots
// ---------------------------------------------------------------------------

export fn pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}

export fn powf(x: f32, y: f32) f32 {
    return std.math.pow(f32, x, y);
}

export fn cbrt(x: f64) f64 {
    return std.math.cbrt(x);
}

/// The length of a right triangle's hypotenuse, computed so that a large
/// side does not overflow on the way to an answer that would fit.
export fn hypot(x: f64, y: f64) f64 {
    return std.math.hypot(x, y);
}

export fn expm1(x: f64) f64 {
    return std.math.expm1(x);
}

export fn log1p(x: f64) f64 {
    return std.math.log1p(x);
}

// ---------------------------------------------------------------------------
// Taking a number apart
// ---------------------------------------------------------------------------

/// `x` times two to the `n`, done by adjusting the exponent rather than
/// by multiplying, which is exact where multiplying would round.
export fn ldexp(x: f64, n: c_int) f64 {
    return std.math.ldexp(x, @intCast(n));
}

/// The same thing under the name the standard also gives it.
export fn scalbn(x: f64, n: c_int) f64 {
    return std.math.ldexp(x, @intCast(n));
}

/// A number as a fraction in [0.5, 1) and a power of two, which is how a
/// caller takes a float apart without knowing its layout.
export fn frexp(x: f64, out: *c_int) f64 {
    const parts = std.math.frexp(x);
    out.* = @intCast(parts.exponent);
    return parts.significand;
}

/// The fractional part, with the whole part written where asked.
export fn modf(x: f64, whole: *f64) f64 {
    const parts = std.math.modf(x);
    whole.* = parts.ipart;
    return parts.fpart;
}

// ---------------------------------------------------------------------------
// What a number is
//
// C spells these as macros over functions, because a value that is not
// equal to itself cannot be written as a constant.
// ---------------------------------------------------------------------------

export fn nan(_: [*:0]const u8) f64 {
    return std.math.nan(f64);
}

export fn __isnan(x: f64) c_int {
    return @intFromBool(std.math.isNan(x));
}

export fn __isinf(x: f64) c_int {
    return @intFromBool(std.math.isInf(x));
}

export fn __isfinite(x: f64) c_int {
    return @intFromBool(std.math.isFinite(x));
}

export fn __signbit(x: f64) c_int {
    return @intFromBool(std.math.signbit(x));
}

export fn copysign(x: f64, y: f64) f64 {
    return std.math.copysign(x, y);
}
