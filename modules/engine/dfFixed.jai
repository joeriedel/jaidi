// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The game's 16.16 fixed-point math, as DARK.EXE does it: products and quotients through 64
// bits, its square root, its distance estimate, its angles (16384 to a turn) and its cosine
// table, and its pseudo-random numbers. Game logic that follows the original uses these, so
// that it comes out the same to the bit.
//
// The cosine and tangent tables are read from DARK.EXE (fixed_load_tables): they aren't
// plain functions of the angle (a few cosine entries are one less than truncating the exact
// cosine gives).

Fixed :: s32;

FIXED_ONE  :Fixed: 0x10000;
FIXED_HALF :Fixed: 0x8000;
ANGLE_TURN :s32: 16384;
ANGLE_MASK :s32: 0x3FFF;

// "No height": the sky over an exterior sector and the like, 9999 units.
FIXED_INFINITY :Fixed: 0x270F0000;

fixed_load_tables :: (dark_dir: string) -> bool {
    image, mapped := dark_exe_map(dark_dir);
    if !mapped return false;
    for * cosine_table  it.* = cast,no_check(s32) lx_read_u32(image, ADDRESS_COSINE_TABLE + it_index * 4);
    for * tangent_table  it.* = cast,no_check(s32) lx_read_u32(image, ADDRESS_TANGENT_TABLE + it_index * 4);
    random_seed = lx_read_u32(image, ADDRESS_RANDOM_SEED);
    tables_loaded = true;
    return true;
}

fixed_are_tables_loaded :: () -> bool { return tables_loaded; }

mul16 :: inline (a: Fixed, b: Fixed) -> Fixed {
    return cast,no_check(Fixed) (((cast(s64) a) * (cast(s64) b)) >> 16);
}

// Truncates toward zero, as the original's idiv does.
div16 :: inline (a: Fixed, b: Fixed) -> Fixed {
    return cast,no_check(Fixed) (((cast(s64) a) << 16) / (cast(s64) b));
}

int_to_fixed :: inline (i: s32) -> Fixed { return cast,no_check(Fixed) (i << 16); }

fixed_to_float :: inline (f: Fixed) -> float { return cast(float) f / 65536.0; }

// The original reads numbers from text with %f into a float and stores them multiplied by
// 65536, truncated toward zero.
fixed_from_text :: (s: string) -> Fixed {
    f, ok := string_to_float64(s);
    if !ok return 0;
    x := cast(float64) cast(float32) f * 65536.0;
    if x >= 2147483647.0 return 0x7FFF_FFFF;
    if x <= -2147483648.0 return -0x7FFF_FFFF - 1;
    return cast(Fixed) x;
}

// Sine and cosine of an angle, from the quarter-wave cosine table (DARK.EXE 0x89ef0).
sin_cos :: (angle: s32) -> sine: Fixed, cosine: Fixed {
    a := angle & ANGLE_MASK;
    t := cosine_table;
    if a & 0x1000 {
        if !(a & 0x2000)  return t[a - 0x1000], -t[0x2000 - a];
        return -t[a - 0x3000], t[0x4000 - a];
    }
    if !(a & 0x2000)  return t[0x1000 - a], t[a];
    return -t[0x3000 - a], -t[a - 0x2000];
}

// The tangent of an angle, from its table of half a turn (DARK.EXE 0x89f91).
tan_fixed :: (angle: s32) -> Fixed {
    a := angle & ANGLE_MASK;
    if a < 0x2000 return tangent_table[a];
    return tangent_table[a - 0x2000];
}

// The angle whose sine is x, searched for in the cosine table (0x8a002). A negative x gives
// 0x2FFF less the angle for |x|, as in the original, not its negation.
get_arcsine :: (x: Fixed) -> s32 {
    v := ifx x < 0 then -x else x;
    i: s32;
    while v < cosine_table[i] {
        i += 1;
        if i >= 0x1000 break;
    }
    if x < 0 return 0x2FFF - i;
    return 0xFFF - i;
}

// Bit by bit, 16.16 in and out (0x8a0a4).
fixed_sqrt :: (x: Fixed) -> Fixed {
    v := cast,no_check(u32) x;
    r: u32;
    bit: u32 = 0x4000_0000;
    while bit {
        t := r + bit;
        if t <= v {
            v -= t;
            r = t + bit;
        }
        v <<= 1;
        bit >>= 1;
    }
    return cast,no_check(Fixed) (r >> 8);
}

// The length of (dx, dz), each halved first so the squares can't overflow (0x579bc).
vec2_length :: (dx: Fixed, dz: Fixed) -> Fixed {
    hx := dx / 2;
    hz := dz / 2;
    return fixed_sqrt(mul16(hx, hx) + mul16(hz, hz)) * 2;
}

// The direction of a vector, and its length (0x57d3c).
get_direction_and_length :: (dx: Fixed, dz: Fixed) -> Fixed, Fixed, Fixed {
    length := vec2_length(dx, dz);
    if !length return 0, 0, 0;
    return div16(dx, length), div16(dz, length), length;
}

// |dx| + |dz| less half the smaller: the original's quick distance (0x8a192).
dist_approx :: (x0: Fixed, z0: Fixed, x1: Fixed, z1: Fixed) -> Fixed {
    dx := x1 - x0;
    if dx < 0  dx = -dx;
    dz := z1 - z0;
    if dz < 0  dz = -dz;
    return dx + dz - (min(dx, dz) >> 1);
}

// The angle of (dx, dz), 0 along +z, 4096 along +x: linear within each octant, not a true
// arctangent (0x8a10a).
vec2_to_angle :: (dx: Fixed, dz: Fixed) -> s32 {
    if dx == 0 && dz == 0 return 0;
    octant: s32 = ((cast(s32) (dz < 0)) << 1) | cast(s32) ((dx ^ dz) < 0);
    ax := ifx dx < 0 then -dx else dx;
    az := ifx dz < 0 then -dz else dz;
    flip: s32 = (octant ^ cast(s32) (ax < az)) & 1;
    turn := (octant << 1) | flip;
    num, den := ax, az;
    if (turn - 1) & 2  num, den = az, ax;
    q := div16(num, den);
    if flip  q = FIXED_ONE - q;
    return ((0x20000 - (q + turn * FIXED_ONE)) >> 5) & ANGLE_MASK;
}

// Moves (x, z) by speed along an angle (0x57cec).
add_move_from_angle :: (x: *Fixed, z: *Fixed, angle: s32, speed: Fixed) {
    s, c := sin_cos(angle);
    x.* += mul16(speed, s);
    z.* += mul16(speed, c);
}

// Scales (x, z) down to max_length when it's longer (0x57c64).
limit_vector_length :: (x: *Fixed, z: *Fixed, max_length: Fixed) {
    hx := x.* / 2;
    hz := z.* / 2;
    length := fixed_sqrt(mul16(hz, hz) + mul16(hx, hx)) * 2;
    if length > max_length && length != 0 {
        scale := div16(max_length, length);
        x.* = mul16(x.*, scale);
        z.* = mul16(z.*, scale);
    }
}

// b - a, the short way round, 16 bits (0x57978). Past half a turn the original takes off
// 0x3FFF, not a whole turn.
get_angle_difference :: (a: s32, b: s32) -> s32 {
    d := (b & 0xFFFF3FFF) - (a & 0xFFFF3FFF);
    short: s32 = cast,no_check(s16) d;
    if short > 0x1FFF || short < -0x1FFF {
        if short >= 0 return cast,no_check(s16) (d - 0x3FFF);
        return cast,no_check(s16) (d + 0x4000);
    }
    return short;
}

// The original's pseudo-random numbers: a shift register on a 32-bit seed (0x8a0ce).
fixed_random_next :: () -> u32 {
    s := random_seed;
    if s & 1  s = (s >> 1) ^ 0xA300_0000;
    else      s >>= 1;
    random_seed = s;
    return s;
}

// A random number up to limit (0x8a0ef): limit scaled by the seed's low 16 bits as a
// fraction, when the seed is past the limit.
fixed_random :: (limit: Fixed) -> Fixed {
    r := fixed_random_next();
    if cast,no_check(u32) limit < r  return mul16(limit, cast,no_check(Fixed) (r & 0xFFFF));
    return cast,no_check(Fixed) r;
}

fixed_set_random_seed :: (seed: u32) { random_seed = seed; }
fixed_get_random_seed :: () -> u32 { return random_seed; }

#scope_file

ADDRESS_COSINE_TABLE :: 0xecafc;
ADDRESS_RANDOM_SEED  :: 0xecaf8;
ADDRESS_TANGENT_TABLE :: 0xf0b00;

cosine_table: [4097] s32;  // A quarter wave and its end, 0 to 4096.
tangent_table: [0x2000] s32;
tables_loaded: bool;
random_seed: u32;

#import "Basic";
#import "File";
#import "Hash";
#import "String";
#import "engine/dfArchive";
