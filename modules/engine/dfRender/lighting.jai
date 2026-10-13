// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The original's lighting, in its integer math (16.16 fixed point), for what it computes on
// the CPU: a light level per flat-shaded polygon, an intensity per vertex of a vertex-lit 3D
// object, and the distance light of things lit as a whole. The per-pixel distance light of
// walls, floors and PLANE polygons is the same formula, in the scene shader.
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

// get_light_by_depth for Enhanced drawing: the same formula in floating point, z in world
// units, so the level falls smoothly with distance instead of in whole steps. The ramp is
// the smoothed one (smooth_light_ramp), read between its entries, and the floor is 7/8 of
// the sector's light exactly. Keep it in step with light_by_depth_smooth in scene.frag.hlsl.
get_light_by_depth_smooth :: (lighting: Lighting, ramp: [LIGHT_RAMP_COUNT] float, z: float) -> float {
    if lighting.sector_ambient > 30 return LIGHT_FULL;
    z = max(z, 0);
    light: float;
    if lighting.headlight || lighting.world_ambient < 31 {
        at := min(z * 4, LIGHT_RAMP_COUNT - 1.0);
        i := cast(int) at;
        step := lerp(ramp[i], ramp[min(i + 1, LIGHT_RAMP_COUNT - 1)], at - i);
        light = max(31 - (step + lighting.world_ambient), 0);
    }
    light = max(light, cast(float) lighting.sector_ambient);
    light -= z * (3.0 / 32.0);
    light = max(light, lighting.sector_ambient * 0.875);
    return light + lighting.light_offset / 65536.0;
}

// The light ramp without its steps. The ramp holds whole levels, each repeated over three or
// four entries, so read as it is the headlamp's light stays flat for most of a unit and then
// drops a level: rings around the player. Smoothed, it runs straight through the middle of
// each run of equal entries, which is about where the whole numbers were rounded from. The
// first run, full light around the player, is kept to its end.
smooth_light_ramp :: (ramp: [LIGHT_RAMP_COUNT] u8) -> [LIGHT_RAMP_COUNT] float {
    // The knots: each run's middle (the first run's end), with its value.
    at, value: [LIGHT_RAMP_COUNT] float;
    count := 0;
    start := 0;
    for i: 1..LIGHT_RAMP_COUNT {
        if i < LIGHT_RAMP_COUNT && ramp[i] == ramp[start] continue;
        at[count] = ifx start == 0 then cast(float) (i - 1) else (start + i - 1) * 0.5;
        value[count] = cast(float) ramp[start];
        count += 1;
        start = i;
    }
    result: [LIGHT_RAMP_COUNT] float;
    k := 0;
    for i: 0..LIGHT_RAMP_COUNT-1 {
        x := cast(float) i;
        while k + 1 < count && at[k + 1] <= x  k += 1;
        if x <= at[0]           result[i] = value[0];
        else if k + 1 >= count  result[i] = value[count - 1];
        else                    result[i] = lerp(value[k], value[k + 1], (x - at[k]) / (at[k + 1] - at[k]));
    }
    return result;
}

// The colormap's lighting as curves on colors, for Enhanced drawing: for each palette entry,
// the color the colormap gives it at each light level, in linear light, smoothed across the
// levels against the palette's rounding (where the colormap holds an entry for two levels and
// then jumps two). Level 31 is the entry itself, as the original skips the colormap from 31
// up. Drawing reads an entry's curve at a fractional level, so the light falls smoothly and
// colors needn't snap to the palette, while each entry keeps the colormap's own hues: Talay's
// peach walls go burnt orange in the dark, greys stay grey.
//
// A single scale per level, the same for every color, fits no worse overall, but it keeps the
// peach and only darkens it; a scale per channel tints greys toward the palette's colored
// ramps. The single scale is kept for the light-only view, a neutral picture of the light.
Light_Fit :: struct {
    curves: [LIGHT_LEVELS][256] Vector3;
    scale:  [LIGHT_LEVELS] float;   // The light-only view's: one for all colors, level 31 1.
    ramp:   [LIGHT_RAMP_COUNT] float;   // smooth_light_ramp of the colormap's.
}

fit_light :: (palette: *Palette, colormap: *Colormap) -> Light_Fit {
    fit: Light_Fit;
    colors: [256] Vector3;
    for palette.colors  colors[it_index] = .{srgb_to_linear(it.r / 255.0), srgb_to_linear(it.g / 255.0), srgb_to_linear(it.b / 255.0)};

    // Each entry's colors by level, then a [1 2 1] filter across levels 0-30, the ends held
    // (level 0's darkest neighbour is itself; level 31 stays the entry).
    exact: [LIGHT_LEVELS][256] Vector3;
    for level: 0..LIGHT_LEVELS-2  for i: 0..255  exact[level][i] = colors[colormap.levels[level][i]];
    exact[LIGHT_LEVELS - 1] = colors;
    for level: 0..LIGHT_LEVELS-1  for i: 0..255 {
        if level == LIGHT_LEVELS - 1 { fit.curves[level][i] = exact[level][i]; continue; }
        below := exact[max(level - 1, 0)][i];
        above := exact[level + 1][i];
        fit.curves[level][i] = (below + exact[level][i] * 2 + above) * 0.25;
    }

    // The single scale, from the entries the colormap darkens: those every level keeps as
    // they are (light panels, lasers) would only pull it toward 1. Row 31 is never used.
    for level: 0..LIGHT_LEVELS-1 {
        fit.scale[level] = 1;
        if level == LIGHT_LEVELS - 1 continue;
        xy, x2: float64;
        for i: 0..255 {
            if is_full_bright(colormap, i) continue;
            x := colors[i];
            y := colors[colormap.levels[level][i]];
            xy += x.x * y.x + x.y * y.y + x.z * y.z;
            x2 += x.x * x.x + x.y * x.y + x.z * x.z;
        }
        if x2 > 0  fit.scale[level] = xx (xy / x2);
    }
    fit.ramp = smooth_light_ramp(colormap.light_ramp);
    return fit;
}

// Kept as it is at every level the original uses.
is_full_bright :: (colormap: *Colormap, index: int) -> bool {
    for level: 0..LIGHT_LEVELS-2  if colormap.levels[level][index] != index return false;
    return true;
}

// The directional lights that shade 3D objects: three fixed directions in the world, turned
// with the camera's yaw only (the original has no true pitch), each pointing back at the
// surface. Brightness 1 each (0x4fff0).
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

// One light level for a FLAT or TEXTURE polygon (DARK.EXE 0x5f654 and 0x5f7cc): the directional
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
#import "Math";
#import "engine/dfImage";
