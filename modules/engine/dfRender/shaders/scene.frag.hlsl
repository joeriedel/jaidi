// SPDX-License-Identifier: GPL-2.0-or-later

// Writes palette indices, lit through the level's colormap the way the original's software
// renderer lights them, plus one: 0 is left for where nothing was drawn. The palette is
// applied later, by resolve.frag.hlsl.
//
// SDL_GPU can't sample integer textures, so indices travel in normalized ones (images and the
// target 16-bit, the colormap 8-bit) and are rounded back here; both ways are exact.
//
// color: palette index in bits 0-7 (untextured modes), the mode in bits 8-11, bit 12 makes
// index 0 of a texture see-through, bit 13 addresses the texture as a floor does. Texels of
// 0x100 are never drawn (DELT gaps).
//
// RGB (built with RGB), for Enhanced: the same drawing, but each pixel takes its palette
// entry's color at a fractional light level from the colormap's curves (Light_Fit in
// lighting.jai), in linear light, written into RGBA16F. The light table: rows 0-31 each
// entry's color at that level, row 31 the palette itself; row 32 the light-only view's scale
// by level (red of columns 0-31) and the smoothed light ramp (blue of 0-127). With
// light_only, lit drawing is white at the level's scale, the light without the art.

#define MODE_FLAT          0   // Color, one light level per polygon (light >= 31: no colormap).
#define MODE_SHADED        1   // Color, light interpolated from the vertices, 0 to 31.
#define MODE_TEXTURE_FLAT  2   // Texture, one light level (sprites, flat textured polygons).
#define MODE_TEXTURE_SHADED 3  // Texture, light interpolated from the vertices.
#define MODE_TEXTURE_DEPTH 4   // Texture, lit per pixel by distance (walls, floors, PLANE).
#define MODE_TEXTURE_RAW   5   // Texture, no lighting (2D art, previews).
#define MODE_COLOR_RAW     6   // Color, no lighting.
#define MODE_SKY           7   // Texture placed by the pixel's direction from the camera, unlit.

#define TRANSPARENT_BIT 0x1000
#define FLAT_BIT        0x2000
#define NO_PIXEL        0x100

Texture2D<float> image    : register(t0, space2);
Texture2D<float> colormap : register(t1, space2);   // 256 x 33: 32 light levels, then the ramp.
#ifdef RGB
Texture2D<float4> table   : register(t2, space2);   // 256 x 33: the light table, above.
#define OUTPUT float4
#else
#define OUTPUT float
#endif

uint load_texel(int2 at) {
    return uint(round(image.Load(int3(at, 0)) * 65535.0));
}

uint load_colormap(uint index, int row) {
    return uint(round(colormap.Load(int3(index, row, 0)) * 255.0));
}

float to_target(uint index) {
    return float(index + 1) / 65535.0;
}

cbuffer Lighting : register(b0, space3) {
    int sector_ambient;     // 0..31; 31 or more turns the colormap off.
    int scaled_ambient;     // sector_ambient * 7/8, rounded down the original's way.
    int world_ambient;      // 31 - the level's light; 31 when the level is fully lit.
    int headlight;          // Headlight or weapon flash on.
    int light_offset;       // 16.16, added after the fade (wall light, flashes).
    int light_only;         // RGB: lit drawing white, to show the light alone.
    int2 pad;
    // The sky's texel at a pixel: across, u + atan((x - center_x) * inv_focal) in parallax
    // texels per turn (the original's table is built for 1024); down, v + y * row_scale, the
    // rows of a 200-line screen.
    float sky_u, sky_v, sky_center_x, sky_inv_focal;
    float sky_row_scale, sky_pad0, sky_pad1, sky_pad2;
};

struct Input {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float  light    : TEXCOORD1;
    float  depth    : TEXCOORD2;
    nointerpolation uint color : TEXCOORD3;
};

// The original's distance lighting for walls, floors and textured 3D polygons, in its integer
// math: z is 16.16 world units. Returns a light level; 31 or more means no colormap.
int light_by_depth(float depth) {
    if (sector_ambient > 30) return 31;
    int z = max(int(depth * 65536.0), 0);
    int light = 0;
    if (headlight != 0 || world_ambient < 31) {
        int ramp = load_colormap(min(z >> 14, 127), 32);
        int source = 31 - (ramp + world_ambient);
        if (source > 0) light = source;
    }
    light = max(light, sector_ambient);
    light -= (z >> 20) + (z >> 21);
    light = max(light, scaled_ambient);
    if (light_offset != 0) light += (light_offset + 0x8000) >> 16;
    return light;
}

#ifdef RGB

// light_by_depth in floating point, z in world units: the same curve without the integer
// steps, and the ramp smoothed (smooth_light_ramp). Keep it in step with
// get_light_by_depth_smooth in lighting.jai.
float light_by_depth_smooth(float depth) {
    if (sector_ambient > 30) return 31.0;
    float z = max(depth, 0.0);
    float light = 0.0;
    if (headlight != 0 || world_ambient < 31) {
        float at = min(z * 4.0, 127.0);
        int i = int(at);
        float ramp = lerp(table.Load(int3(i, 32, 0)).b, table.Load(int3(min(i + 1, 127), 32, 0)).b, at - i);
        light = max(31.0 - (ramp + world_ambient), 0.0);
    }
    light = max(light, float(sector_ambient));
    light -= z * (3.0 / 32.0);
    light = max(light, sector_ambient * 0.875);
    return light + light_offset / 65536.0;
}

float4 to_unlit(uint index) {
    return float4(table.Load(int3(index, 31, 0)).rgb, 1.0);
}

// Catmull-Rom through the levels around, held between the two it falls between so it never
// overshoots them.
float3 interpolate_levels(float3 p0, float3 p1, float3 p2, float3 p3, float f) {
    float3 c = p1 + 0.5 * f * (p2 - p0 + f * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + f * (3.0 * (p1 - p2) + p3 - p0)));
    return clamp(c, min(p1, p2), max(p1, p2));
}

// An entry's curve at a fractional level; from 31 up, the entry as it is.
float4 to_lit(uint index, float light) {
    if (light >= 31.0) return light_only != 0 ? float4(1.0, 1.0, 1.0, 1.0) : to_unlit(index);
    float level = max(light, 0.0);
    int i = min(int(level), 30);
    float f = level - i;
    if (light_only != 0) {
        float p0 = table.Load(int3(max(i - 1, 0), 32, 0)).r;
        float p1 = table.Load(int3(i, 32, 0)).r;
        float p2 = table.Load(int3(i + 1, 32, 0)).r;
        float p3 = table.Load(int3(min(i + 2, 31), 32, 0)).r;
        return float4(interpolate_levels(p0.xxx, p1.xxx, p2.xxx, p3.xxx, f), 1.0);
    }
    float3 p0 = table.Load(int3(index, max(i - 1, 0), 0)).rgb;
    float3 p1 = table.Load(int3(index, i, 0)).rgb;
    float3 p2 = table.Load(int3(index, i + 1, 0)).rgb;
    float3 p3 = table.Load(int3(index, min(i + 2, 31), 0)).rgb;
    return float4(interpolate_levels(p0, p1, p2, p3, f), 1.0);
}

#else

float to_unlit(uint index) {
    return to_target(index);
}

#endif

OUTPUT main(Input input) : SV_Target0 {
    uint mode = (input.color >> 8) & 15;
    uint index = input.color & 255;

    if (mode == MODE_SKY) {
        uint width, height;
        image.GetDimensions(width, height);
        int2 size = int2(width, height);
        float turn = atan((input.position.x - sky_center_x) * sky_inv_focal) / 6.28318530718;
        int2 texel = int2(floor(float2(sky_u + turn * 1024.0, sky_v + input.position.y * sky_row_scale)));
        texel = ((texel % size) + size) % size;
        return to_unlit(load_texel(texel));
    }

    if (mode == MODE_TEXTURE_FLAT || mode == MODE_TEXTURE_SHADED || mode == MODE_TEXTURE_DEPTH || mode == MODE_TEXTURE_RAW) {
        uint width, height;
        image.GetDimensions(width, height);
        int2 size = int2(width, height);
        int2 texel = int2(floor(input.uv));
        if ((input.color & FLAT_BIT) != 0) {
            // The original's flat filler addresses every texture as 64 x 64 columns of its
            // column-major texels (bottom to top), whatever its size: u picks the column, v
            // the texel up it. Images here are rows from the top.
            int at = (((texel.x & 63) << 6) + (texel.y & 63)) & (size.x * size.y - 1);
            texel = int2(at / size.y, size.y - 1 - at % size.y);
        } else {
            texel = ((texel % size) + size) % size;
        }
        index = load_texel(texel);
        if (index == NO_PIXEL || ((input.color & TRANSPARENT_BIT) != 0 && index == 0)) discard;
    }

    if (mode == MODE_TEXTURE_RAW || mode == MODE_COLOR_RAW) return to_unlit(index);
#ifdef RGB
    if (mode == MODE_TEXTURE_DEPTH) return to_lit(index, light_by_depth_smooth(input.depth));
    if (mode == MODE_SHADED || mode == MODE_TEXTURE_SHADED) return to_lit(index, clamp(input.light, 0.0, 31.0));
    return to_lit(index, input.light);
#else
    int light;
    if (mode == MODE_TEXTURE_DEPTH) {
        light = light_by_depth(input.depth);
    } else if (mode == MODE_SHADED || mode == MODE_TEXTURE_SHADED) {
        // Interpolated 16.16 intensity, clamped 0..31: always through the colormap.
        light = clamp(int(floor(input.light)), 0, 31);
        return to_target(load_colormap(index, light));
    } else {
        // A whole level, the same at every corner, but interpolation can still bring it in a
        // hair under (23.9999 on a steep polygon), so round rather than truncate.
        light = int(round(input.light));
    }
    if (light > 30) return to_target(index);
    return to_target(load_colormap(index, max(light, 0)));
#endif
}
