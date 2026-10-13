// SPDX-License-Identifier: GPL-2.0-or-later

// Palette indices to colors, as the VGA DAC did. The scene target holds index + 1, with 0
// where nothing was drawn, which shows the background.

Texture2D<float>  indices : register(t0, space2);   // 16-bit normalized.
Texture2D<float4> palette : register(t1, space2);   // 256 x 1.

cbuffer Background : register(b0, space3) {
    float4 background;
};

float4 main(float4 position : SV_Position) : SV_Target0 {
    uint index = uint(round(indices.Load(int3(int2(position.xy), 0)) * 65535.0));
    return index == 0 ? background : palette.Load(int3(index - 1, 0, 0));
}
