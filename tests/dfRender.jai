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

#import "Basic";
#import "engine/dfRender";
