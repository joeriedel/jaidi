// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The original's lighting, in its integer math (16.16 fixed point), for what it computes on
// the CPU: a light level per flat-shaded polygon, an intensity per vertex of a vertex-lit 3D
// object, and the distance light of things lit as a whole. The per-pixel distance light of
// walls, floors and textured polygons is the same formula, in the scene shader.
//
// A light level of 31 or more means the colormap is skipped and the palette index drawn as
// it is.

Lighting :: struct {
    sector_ambient: s32 = 31;   // The sector's light, 0..31 (rounded from its 16.16 value).
    world_ambient:  s32 = 31;   // 31 minus the light source, the brighter of the headlight
                                // (31 when on, with a charged battery) and a weapon flash.
    headlight:      bool;       // The headlight is on.
    light_offset:   s32;        // 16.16, added after the fade.
}

LIGHT_FULL :: 31;

// The floor the fade can't go below: 7/8 of the sector's light, each eighth rounded down.
get_scaled_ambient :: (sector_ambient: s32) -> s32 {
    return (sector_ambient >> 1) + (sector_ambient >> 2) + (sector_ambient >> 3);
}

// Distance light (DARK.EXE 0x50ef8): the light source (headlight or world light) by the
// colormap's ramp, at least the sector's light, faded 3/32 of a level per unit of distance
// down to the scaled ambient, then the offset.
get_light_by_depth :: (lighting: Lighting, ramp: [] u8, z: s32) -> s32 {
    if lighting.sector_ambient > 30 return LIGHT_FULL;
    z = max(z, 0);
    light := get_light_source(lighting, ramp, z);
    light = max(light, lighting.sector_ambient);
    light -= (z >> 20) + (z >> 21);
    light = max(light, get_scaled_ambient(lighting.sector_ambient));
    if lighting.light_offset  light += (lighting.light_offset + 0x8000) >> 16;
    return light;
}

// The directional lights that shade 3D objects: three fixed directions in the world, turned
// with the camera's yaw only (the original has no true pitch), each pointing back at the
// surface. Brightness 1 each; the original's call sites pass it in a register the decompiler
// loses, so that value is the reconstruction's.
Camera_Lights :: struct {
    directions: [3][3] s32;     // View space, 16.16, unit length.
    brightness: [3] s32;
}

get_camera_lights :: (yaw_cos: float = 1, yaw_sin: float = 0) -> Camera_Lights {
    WORLD :: Vector3.[.{0, 0, 1}, .{0, 1, 0}, .{1, 0, 0}];
    lights: Camera_Lights;
    for WORLD {
        // DARK.EXE 0x51a78 without the translation: x' = x cos + z sin, z' = z cos - x sin.
        v := Vector3.{it.x * yaw_cos + it.z * yaw_sin, it.y, it.z * yaw_cos - it.x * yaw_sin};
        lights.directions[it_index] = to_fixed_vector(-unit_vector(v));
        lights.brightness[it_index] = 0x10000;
    }
    return lights;
}

// One light level for a flat-shaded polygon (DARK.EXE 0x5f654 and 0x5f7cc): the directional
// lights by the polygon's view-space normal, scaled by the sector's light, then the distance
// light at the average depth of its corners.
get_polygon_light :: (lighting: Lighting, ramp: [] u8, lights: *Camera_Lights, normal: [3] s32, z: s32) -> s32 {
    if lighting.sector_ambient > 30 return LIGHT_FULL;
    z = max(z, 0);
    sum := get_directional_light(lights, normal);
    light := mul16(sum, lighting.sector_ambient << 11) >> 16;
    if light > 30 return LIGHT_FULL;
    light += get_light_source(lighting, ramp, z);
    light = max(light, lighting.sector_ambient);
    light -= (z >> 21) + (z >> 20);
    light = max(light, get_scaled_ambient(lighting.sector_ambient));
    return light;
}

// A 16.16 intensity, 0 to 31, for a vertex of a vertex-lit object (DARK.EXE 0x59ae0). The
// original subtracts the distance fade and compares the scaled ambient without converting
// them to 16.16, so for vertices they hardly count; kept as it is.
get_vertex_intensity :: (lighting: Lighting, ramp: [] u8, lights: *Camera_Lights, normal: [3] s32, z: s32) -> s32 {
    if lighting.sector_ambient > 30 return 31 << 16;
    sum := get_directional_light(lights, normal);
    intensity := mul16(sum, lighting.sector_ambient << 11);
    z = max(z, 0);
    intensity += get_light_source(lighting, ramp, z) << 16;
    intensity = max(intensity, lighting.sector_ambient << 16);
    intensity -= (z >> 21) + (z >> 20);
    intensity = max(intensity, get_scaled_ambient(lighting.sector_ambient));
    return clamp(intensity, 0, 31 << 16);
}

to_fixed :: (f: float) -> s32 {
    return cast(s32) floor(f * 65536.0 + 0.5);
}

to_fixed_vector :: (v: Vector3) -> [3] s32 {
    return .[to_fixed(v.x), to_fixed(v.y), to_fixed(v.z)];
}

#scope_file

// The headlight or world light by distance, as levels above none.
get_light_source :: (lighting: Lighting, ramp: [] u8, z: s32) -> s32 {
    if !lighting.headlight && lighting.world_ambient >= 31 return 0;
    index := min(z >> 14, 127);
    step: s32 = ifx index < ramp.count then ramp[index] else 31;
    return max(31 - (step + lighting.world_ambient), 0);
}

// Each light facing the surface adds its brightness times 31 times the cosine, 16.16.
get_directional_light :: (lights: *Camera_Lights, normal: [3] s32) -> s32 {
    sum: s32;
    for 0..2 {
        d := lights.directions[it];
        dot := mul16(normal[0], d[0]) + mul16(normal[1], d[1]) + mul16(normal[2], d[2]);
        if dot > 0  sum += mul16(dot, mul16(lights.brightness[it], 31 << 16));
    }
    return sum;
}

#import "engine/dfFixed";
