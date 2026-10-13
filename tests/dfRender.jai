// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The CPU side of the original's lighting (lighting.jai). Values worked out by hand from
// DARK.EXE's integer formulas.

light_fades_with_distance :: () {
    lighting := Lighting.{sector_ambient = 20};
    ramp: [128] u8;
    // 16 units: 20 - (1 + 0). 64 units: 20 - (4 + 2) = 14, held at the scaled ambient 10+5+2.
    check(get_light_by_depth(lighting, ramp, 16 << 16) == 19, "16 units: %", get_light_by_depth(lighting, ramp, 16 << 16));
    check(get_light_by_depth(lighting, ramp, 64 << 16) == 17, "64 units: %", get_light_by_depth(lighting, ramp, 64 << 16));
    check(get_scaled_ambient(31) == 15 + 7 + 3, "scaled ambient of 31");
    full := Lighting.{sector_ambient = 31};
    check(get_light_by_depth(full, ramp, 0) == LIGHT_FULL, "full light skips the colormap");
} @test

headlight_follows_the_ramp :: () {
    // Headlight on: world ambient 0, the ramp says how far below full each distance is.
    lighting := Lighting.{sector_ambient = 0, world_ambient = 0, headlight = true};
    ramp: [128] u8;
    for * ramp  it.* = cast(u8) min(it_index / 4, 31);
    // 2 units: ramp index 8 -> 2, so 31 - 2 = 29, minus the fade (0).
    check(get_light_by_depth(lighting, ramp, 2 << 16) == 29, "2 units: %", get_light_by_depth(lighting, ramp, 2 << 16));
    // Off, with nothing else lighting the view: the sector's 0.
    off := Lighting.{sector_ambient = 0, world_ambient = 31};
    check(get_light_by_depth(off, ramp, 2 << 16) == 0, "headlight off: %", get_light_by_depth(off, ramp, 2 << 16));
    // A light offset rounds from 16.16.
    offset := Lighting.{sector_ambient = 10, light_offset = 0x18000};
    check(get_light_by_depth(offset, ramp, 0) == 12, "offset: %", get_light_by_depth(offset, ramp, 0));
} @test

polygon_light_faces_the_lights :: () {
    ramp: [128] u8;
    lights := get_camera_lights();
    lighting := Lighting.{sector_ambient = 16};
    // Facing the camera (normal -z) catches the light along -z fully: 31 * 16/32 = 15.5 -> 15,
    // then at least the sector's 16.
    toward := get_polygon_light(lighting, ramp, *lights, .[0, 0, -0x10000], 0);
    check(toward == 16, "facing the camera: %", toward);
    // Facing up and toward the camera at 45 degrees catches two lights at cos 45.
    s :: 46341;  // 0x10000 / sqrt(2)
    up := get_polygon_light(lighting, ramp, *lights, .[0, -s, -s], 0);
    check(up == 21, "up and toward: %", up);
} @test

smooth_light_follows_the_same_curve :: () {
    ramp: [128] u8;
    flat: [128] float;
    lighting := Lighting.{sector_ambient = 20};
    // 16 units: 20 - 1.5. 64 units: 20 - 6 = 14, held at 7/8 of 20.
    check(abs(get_light_by_depth_smooth(lighting, flat, 16) - 18.5) < 0.001, "16 units: %", get_light_by_depth_smooth(lighting, flat, 16));
    check(abs(get_light_by_depth_smooth(lighting, flat, 64) - 17.5) < 0.001, "64 units: %", get_light_by_depth_smooth(lighting, flat, 64));
    // Within the two fractions the original's integer steps truncate.
    for z: 0..200 {
        smooth := get_light_by_depth_smooth(lighting, flat, xx z);
        exact  := cast(float) get_light_by_depth(lighting, ramp, cast(s32) z << 16);
        if !check(abs(smooth - exact) < 2, "% units: % against %", z, smooth, exact) break;
    }
    full := Lighting.{sector_ambient = 31};
    check(get_light_by_depth_smooth(full, flat, 10) == LIGHT_FULL, "full light skips the colormap");
} @test

smoothed_ramp_runs_through_the_middles :: () {
    // Runs of 0 (to 3), 1 (4-6) and 2 (7 on): knots at 3, 5 and the last run's middle.
    ramp: [128] u8;
    for 4..6  ramp[it] = 1;
    for 7..127  ramp[it] = 2;
    smooth := smooth_light_ramp(ramp);
    check(smooth[0] == 0 && smooth[3] == 0, "the first run kept: % %", smooth[0], smooth[3]);
    check(abs(smooth[4] - 0.5) < 0.001 && smooth[5] == 1, "between the knots: % %", smooth[4], smooth[5]);
    middle := (7 + 127) / 2;
    check(abs(smooth[6] - (1 + 1.0 / (middle - 5))) < 0.001, "toward the last run's middle: %", smooth[6]);
    check(smooth[middle] == 2 && smooth[127] == 2, "held at the end: % %", smooth[middle], smooth[127]);
} @test

fit_of_the_identity_changes_nothing :: () {
    palette: Palette;
    for * palette.colors  it.* = .{cast(u8) it_index, cast(u8) (255 - it_index), 128};
    identity: Colormap;
    for * level: identity.levels  for * level.* it.* = cast(u8) it_index;
    fit := New(Light_Fit);
    defer free(fit);
    fit.* = fit_light(*palette, *identity);
    for level: 0..LIGHT_LEVELS-1  for i: 0..255 {
        c := palette.colors[i];
        expected := Vector3.{to_linear_8(c.r), to_linear_8(c.g), to_linear_8(c.b)};
        if !check(length(fit.curves[level][i] - expected) < 0.00001, "level % entry %: % for %", level, i, fit.curves[level][i], expected) return;
    }
    for fit.scale  if !check(it == 1, "level %: scale %", it_index, it) break;
} @test

fit_follows_a_known_darkening :: () {
    // A grey ramp, each level taking every grey to the one nearest a known fraction of its
    // light. The curves are straight in the level, so the smoothing keeps them but at the
    // ends; the single scale finds the fraction.
    palette: Palette;
    for * palette.colors  it.* = .{cast(u8) it_index, cast(u8) it_index, cast(u8) it_index};
    colormap: Colormap;
    for level: 0..LIGHT_LEVELS-1 {
        k := (level + 1) / 32.0;
        for i: 0..255  colormap.levels[level][i] = find_grey(to_linear_8(cast(u8) i) * k);
    }
    fit := New(Light_Fit);
    defer free(fit);
    fit.* = fit_light(*palette, *colormap);
    white := to_linear_8(255);
    for level: 1..LIGHT_LEVELS-2 {
        k := (level + 1) / 32.0;
        if !check(abs(fit.scale[level] - k) < 0.01, "level %: scale % for %", level, fit.scale[level], k) break;
        c := fit.curves[level][255];
        if !check(abs(c.x - white * k) < 0.01 && c.x == c.y && c.y == c.z, "level %: white at % for %", level, c, white * k) break;
    }
    check(fit.scale[LIGHT_LEVELS - 1] == 1, "level 31 is the identity");
    check(fit.curves[LIGHT_LEVELS - 1][255].x == white, "level 31 is the entry itself");
} @test

// The curves against the retail colormaps, in the DAC's 6-bit units: at whole levels they're
// the colormap's own colors but for the smoothing.
fit_follows_the_retail_colormaps :: () {
    skip_without_dark();
    if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs")  return;
    fit := New(Light_Fit);
    defer free(fit);
    for name: string.["SECBASE", "TALAY"] {
        palette_data, palette_found := gob_find(tprint("%.PAL", name));
        cmp_data, cmp_found := gob_find(tprint("%.CMP", name));
        if !check(palette_found && cmp_found, "no % palette or colormap", name) continue;
        palette := pal_parse(palette_data);
        colormap := cmp_parse(cmp_data);
        fit.* = fit_light(*palette, *colormap);
        sum, count: float64;
        for level: 0..LIGHT_LEVELS-2  for i: 0..255 {
            target := palette.colors[colormap.levels[level][i]];
            lit := fit.curves[level][i];
            e := Vector3.{to_6_bit(lit.x) - target.r * 63.0 / 255, to_6_bit(lit.y) - target.g * 63.0 / 255, to_6_bit(lit.z) - target.b * 63.0 / 255};
            sum += dot(e, e);
            count += 3;
        }
        error := sqrt(sum / count);
        check(error < 1, "%: RMS error % DAC units", name, error);
        // Full-bright entries (0-31) are flat.
        for i: 0..31  for level: 0..LIGHT_LEVELS-1
            if !check(fit.curves[level][i] == fit.curves[LIGHT_LEVELS - 1][i], "%: entry % changes at level %", name, i, level) break;

        // The ramp: never falling, rising past the first run, and at most half a level from
        // the original's whole numbers.
        first_run := 0;
        while colormap.light_ramp[first_run + 1] == colormap.light_ramp[0]  first_run += 1;
        for i: 1..LIGHT_RAMP_COUNT-1 {
            if !check(fit.ramp[i] >= fit.ramp[i - 1], "%: the ramp falls at %", name, i) break;
            if i > first_run && i < LIGHT_RAMP_COUNT - 2  if !check(fit.ramp[i] > fit.ramp[i - 1], "%: the ramp is flat at %", name, i) break;
            if !check(abs(fit.ramp[i] - colormap.light_ramp[i]) <= 0.5, "%: ramp % is % against %", name, i, fit.ramp[i], colormap.light_ramp[i]) break;
        }
    }
} @test

#scope_file

to_linear_8 :: (c: u8) -> float {
    v := c / 255.0;
    return ifx v <= 0.04045 then v / 12.92 else pow((v + 0.055) / 1.055, 2.4);
}

to_6_bit :: (v: float) -> float {
    v = clamp(v, 0, 1);
    s := ifx v <= 0.0031308 then v * 12.92 else 1.055 * pow(v, 1 / 2.4) - 0.055;
    return s * 63;
}

find_grey :: (linear: float) -> u8 {
    best: u8;
    for 0..255  if abs(to_linear_8(cast(u8) it) - linear) < abs(to_linear_8(best) - linear)  best = cast(u8) it;
    return best;
}

#import "Basic";
#import "Math";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/dfRender";
