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
    int3 pad;
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

float main(Input input) : SV_Target0 {
    uint mode = (input.color >> 8) & 15;
    uint index = input.color & 255;

    if (mode == MODE_SKY) {
        uint width, height;
        image.GetDimensions(width, height);
        int2 size = int2(width, height);
        float turn = atan((input.position.x - sky_center_x) * sky_inv_focal) / 6.28318530718;
        int2 texel = int2(floor(float2(sky_u + turn * 1024.0, sky_v + input.position.y * sky_row_scale)));
        texel = ((texel % size) + size) % size;
        return to_target(load_texel(texel));
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

    int light;
    if (mode == MODE_TEXTURE_RAW || mode == MODE_COLOR_RAW) return to_target(index);
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
}
