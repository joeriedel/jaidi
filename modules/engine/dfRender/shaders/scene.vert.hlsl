// SPDX-License-Identifier: GPL-2.0-or-later

// Scene vertices come already transformed to view space (x right, y down, z forward, world
// units), the way the original transforms them on the CPU; this only projects them. With
// perspective, x and y are divided by z; without, they are taken as they are (2D drawing).
// The 3D view's perspective keeps near / z as depth (reversed, 1 at the near plane, toward 0
// far away), which is affine in screen space, so depth interpolates exactly across the
// level's large walls and floors, and float depth keeps its precision far off.

cbuffer Projection : register(b0, space1) {
    float4 scale_offset;    // x and y scale to clip space, then the center's offset.
    float4 depth_range;     // Near, far, then 0 for 2D, 1 for perspective, 2 for the 3D
                            // view's reversed depth; w 1 puts everything at the far plane.
};

// A plane in view space that cuts away what's behind it: a sector seen through an opening
// shows only what's past the opening (see dfWorld/draw.jai). (0, 0, 0, 1) cuts nothing.
cbuffer Clip : register(b1, space1) {
    float4 clip_plane;
};

struct Input {
    float3 position : TEXCOORD0;
    float2 uv       : TEXCOORD1;
    float  light    : TEXCOORD2;
    float  depth    : TEXCOORD3;
    uint   color    : TEXCOORD4;
};

struct Output {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float  light    : TEXCOORD1;
    float  depth    : TEXCOORD2;
    nointerpolation uint color : TEXCOORD3;
    float  clip     : SV_ClipDistance0;
#ifdef POINTS
    [[vk::builtin("PointSize")]] float point_size : PSIZE;
#endif
};

Output main(Input input) {
    Output output;
    float3 p = input.position;
    float near = depth_range.x, far = depth_range.y;
    if (depth_range.z > 1.5) {
        float w = p.z;
        output.position = float4(p.x * scale_offset.x + scale_offset.z * w,
                                 -p.y * scale_offset.y + scale_offset.w * w,
                                 depth_range.w > 0.5 ? 0.0 : near, w);
    } else if (depth_range.z != 0.0) {
        float w = p.z;
        output.position = float4(p.x * scale_offset.x + scale_offset.z * w,
                                 -p.y * scale_offset.y + scale_offset.w * w,
                                 (p.z - near) / (far - near) * w, w);
    } else {
        output.position = float4(p.x * scale_offset.x + scale_offset.z,
                                 -p.y * scale_offset.y + scale_offset.w,
                                 saturate((p.z - near) / (far - near)), 1.0);
    }
    output.uv    = input.uv;
    output.light = input.light;
    output.depth = input.depth;
    output.color = input.color;
    output.clip  = dot(clip_plane.xyz, p) + clip_plane.w;
#ifdef POINTS
    output.point_size = 1.0;
#endif
    return output;
}
