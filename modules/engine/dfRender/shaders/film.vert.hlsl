// SPDX-License-Identifier: GPL-2.0-or-later

// One rectangle of a cutscene image, in its pixels, with texture coordinates in texels. Built
// from the vertex id: two triangles, no vertex buffer.

cbuffer Quad : register(b0, space1) {
    float4 rect;        // Left, top, right, bottom, in target pixels.
    float4 uv;          // Texels at the left-top and right-bottom corners.
    float4 target_size; // Width, height.
};

struct Output {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

static const uint CORNERS[6] = { 0, 1, 2, 2, 1, 3 };  // Bit 0 right, bit 1 bottom.

Output main(uint id : SV_VertexID) {
    uint corner = CORNERS[id];
    float2 c = float2(corner & 1, corner >> 1);
    float2 p = lerp(rect.xy, rect.zw, c);
    Output output;
    output.position = float4(p.x / target_size.x * 2.0 - 1.0, 1.0 - p.y / target_size.y * 2.0, 0.0, 1.0);
    output.uv = lerp(uv.xy, uv.zw, c);
    return output;
}
