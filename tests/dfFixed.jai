// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

fixed_products_and_quotients :: () {
    // Products round toward minus infinity (the shift), quotients toward zero (idiv).
    check(mul16(-1, 0x8000) == -1, "mul16(-1, 0.5) = %", mul16(-1, 0x8000));
    check(mul16(3 * FIXED_ONE, 0x8000) == 0x18000, "mul16(3, 0.5) = %", mul16(3 * FIXED_ONE, 0x8000));
    check(div16(-1, 2 * FIXED_ONE) == 0, "div16(-1, 2) = %", div16(-1, 2 * FIXED_ONE));
    check(div16(FIXED_ONE, 3 * FIXED_ONE) == 21845, "div16(1, 3) = %", div16(FIXED_ONE, 3 * FIXED_ONE));
} @test

fixed_square_root_and_lengths :: () {
    check(fixed_sqrt(4 * FIXED_ONE) == 2 * FIXED_ONE, "sqrt(4) = %", fixed_sqrt(4 * FIXED_ONE));
    check(fixed_sqrt(2 * FIXED_ONE) == 92681, "sqrt(2) = %", fixed_sqrt(2 * FIXED_ONE));
    check(vec2_length(3 * FIXED_ONE, 4 * FIXED_ONE) == 5 * FIXED_ONE, "|3, 4| = %", vec2_length(3 * FIXED_ONE, 4 * FIXED_ONE));
    // |dx| + |dz| less half the smaller.
    check(dist_approx(0, 0, 3 * FIXED_ONE, -4 * FIXED_ONE) == 0x58000, "approx |3, -4| = %", dist_approx(0, 0, 3 * FIXED_ONE, -4 * FIXED_ONE));
    x, z := 6 * FIXED_ONE, 8 * FIXED_ONE;
    limit_vector_length(*x, *z, 5 * FIXED_ONE);
    check(x == 3 * FIXED_ONE && z == 4 * FIXED_ONE, "limited to %, %", x, z);
} @test

fixed_angles :: () {
    // 0 along +z, 4096 along +x; linear within each octant.
    expected :: struct { dx, dz: s32; angle: s32; };
    for expected.[.{0, 1, 0}, .{1, 1, 2048}, .{1, 0, 4096}, .{1, -1, 6144}, .{0, -1, 8192},
                  .{-1, -1, 10240}, .{-1, 0, 12288}, .{-1, 1, 14336}, .{3, 1, 3413}] {
        a := vec2_to_angle(it.dx * FIXED_ONE, it.dz * FIXED_ONE);
        check(a == it.angle, "angle of (%, %) = %, wanted %", it.dx, it.dz, a, it.angle);
    }
} @test

fixed_cosine_table :: () {
    skip_without_dark();
    if !check(fixed_load_tables(find_dark_data_dir()), "couldn't read DARK.EXE's tables")  return;
    s, c := sin_cos(0);
    check(s == 0 && c == FIXED_ONE, "sin, cos 0 = %, %", s, c);
    s, c = sin_cos(4096);
    check(s == FIXED_ONE && c == 0, "sin, cos 4096 = %, %", s, c);
    s, c = sin_cos(8192 + 2048);
    check(s == -46340 && c == -46340, "sin, cos 225 degrees = %, %", s, c);
    // One of the entries that isn't the truncated cosine: 441 is 64600, not 64601.
    _, c = sin_cos(441);
    check(c == 64600, "cos 441 = %", c);
} @test

// The tangent table: half a turn, read from DARK.EXE; 45 degrees is a hair under one.
fixed_tangent_table :: () {
    skip_without_dark();
    if !check(fixed_load_tables(find_dark_data_dir()), "couldn't read DARK.EXE's tables")  return;
    check(tan_fixed(0) == 0, "tan 0 = %", tan_fixed(0));
    check(tan_fixed(0x800) == 0xFFFF && tan_fixed(0x2800) == 0xFFFF, "tan 45 degrees = %, at 225: %", tan_fixed(0x800), tan_fixed(0x2800));
    check(tan_fixed(-0x800) < 0, "tan -45 degrees = %", tan_fixed(-0x800));
} @test

#import "Basic";
#import "engine/dfArchive";
#import "engine/dfFixed";
