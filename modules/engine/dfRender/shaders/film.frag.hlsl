// SPDX-License-Identifier: GPL-2.0-or-later

// The cutscene uber-shader. Every cutscene image is drawn through it, one mode per kind of
// drawing, so effects grow here in one place. One source, four builds:
//
// Indexed drawing (the default build), for the exact path: outputs palette index plus one,
// the renderer's target format, 0 left for nothing drawn.
// RGB (built with RGB), for Enhanced: outputs linear color, premultiplied, into RGBA16F.
// Images may be drawn at any size of the 320x200 screen, scaled separately across and down;
// texels are sampled nearest.
// DELT:  a DELT frame. Indexed: texels of 0x100 are the gaps between its lines. RGB: its
//        colors baked through a palette, sRGB (decoded to linear by the sampler), alpha 0 in
//        the gaps.
// CRAWL: the opening's text crawl, rows 30 to 198, from the original's per-row 16.16 tables
//        in its integer math, each pixel computed on its own rather than stepped along the
//        row. Index 0 of the text is see-through. The tables come in a texture, too big for
//        a uniform buffer: per row, 8 ints as 16-bit halves (low, high) over 4 RGBA texels.
//        RGB: the index found goes through the palette.
// RGB DELTs are magnified by a Catmull-Rom filter, clamped to the middle four texels against
//        ringing. They can take FSR 1's edge-adaptive upscaling (sample_easu, written from
//        AMD's published algorithm), bilinear, nearest or a pixel-art edge filter
//        (sample_edges) instead, for comparing; EASU smeared small detail, reading a stroke's
//        inner shading as edges. The output pass can sharpen the finished picture with FSR
//        1's contrast-adaptive sharpening (sharpen_rcas), off by default. Outlines come from
//        a smooth coverage field instead (sample_outline), as text is drawn from a distance
//        field.
// DELT_TWEEN (RGB only): between two frames of an ANIM whose whole picture moves from one to
//        the next by a zoom and a shift (found on the CPU): frame A carried forward part of
//        the way, frame B carried back the rest, blended by how far along.
// CRAWL_SMOOTH (RGB only): the crawl at full resolution. Each output pixel takes its exact
//        place on the screen, and the original's plane (eye height 60, view distance 210,
//        pixels 0.9, as in its tables) is solved in floating point. Its width is the
//        original's too: half width times view distance, 1010 x 210, wraps in its 32-bit
//        16.16 math to 15492. The text
//        comes baked to colors like a DELT and is filtered in linear color: bilinear where
//        it's magnified, supersampled by its footprint where it's squeezed into the distance.
//        The darkening with distance is a color operation: the original stepped down the
//        text's palette ramp, which runs evenly in DAC values from black to the text's full
//        color, so it subtracts fade / steps of that color in gamma space, held at black.
//
// Resolving (built with RESOLVE), for the exact path: indices into colors through a palette,
// or two blended by a color fade.
//
// Output (built with OUTPUT), for Enhanced: one or two linear images into the 8-bit sRGB
// image shown, with a color fade applied in gamma space as the original's DAC fades were:
// the first image toward black, black toward the second, or the first toward the second
// (each drawn through its own palette). An ordered dither while fading. Or a screen wipe:
// the second (the new picture) inside a rectangle over the first (the old).

#define MODE_DELT         0
#define MODE_CRAWL        1
#define MODE_CRAWL_SMOOTH 2
#define MODE_DELT_TWEEN   3

#define FADE_NONE      0    // The source palette as it is.
#define FADE_TO_MONO   1    // Source toward black.
#define FADE_FROM_MONO 2    // Black toward the destination.
#define FADE_PALETTE   3    // Source toward destination.

#define CRAWL_TOP     30
#define CRAWL_ROWS    169
#define CRAWL_DARKEST 224
#define CRAWL_HALF_WIDTH 15492.0   // 1010 x 210, as the original's math wraps it.

static const float BAYER[16] = {  0,  8,  2, 10, 12,  4, 14,  6,
                                  3, 11,  1,  9, 15,  7, 13,  5 };

// Less than half a step of 8 bits either way, by position.
float get_dither(float2 position) {
    int2 p = int2(position) & 3;
    return ((BAYER[p.y * 4 + p.x] + 0.5) / 16.0 - 0.5) / 255.0;
}

float3 to_linear(float3 c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

float3 to_srgb(float3 c) {
    c = saturate(c);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

#if defined(RESOLVE)

Texture2D<float>  indices     : register(t0, space2);  // 16-bit normalized, index + 1.
Texture2D<float4> source      : register(t1, space2);  // 256 x 1.
Texture2D<float4> destination : register(t2, space2);  // 256 x 1.

cbuffer Resolve : register(b0, space3) {
    int4   resolve_params;  // Fade mode, dither on.
    float4 fraction;        // How far the fade has come, 0 to 1.
};

float4 main(float4 position : SV_Position) : SV_Target0 {
    uint index = uint(round(indices.Load(int3(int2(position.xy), 0)) * 65535.0));
    if (index == 0) return float4(0, 0, 0, 1);
    int3 at = int3(index - 1, 0, 0);
    float f = fraction.x;
    float3 color = source.Load(at).rgb;
    if      (resolve_params.x == FADE_TO_MONO)   color = color * (1.0 - f);
    else if (resolve_params.x == FADE_FROM_MONO) color = destination.Load(at).rgb * f;
    else if (resolve_params.x == FADE_PALETTE)   color = lerp(color, destination.Load(at).rgb, f);
    if (resolve_params.y != 0) color += get_dither(position.xy);
    return float4(color, 1);
}

#elif defined(OUTPUT)

Texture2D<float4> first  : register(t0, space2);   // Linear, RGBA16F.
Texture2D<float4> second : register(t1, space2);

cbuffer Output : register(b0, space3) {
    int4   output_params;   // Fade mode, dither on, sharpen on, wiping.
    float4 fraction;        // How far the fade has come, 0 to 1; how much to sharpen, in stops
                            // below full (0 sharpest).
    float4 wipe;            // Wiping: where the second shows, in output pixels,
    float4 shift;           // moved by this.
};

// FSR 1's contrast-adaptive sharpening (RCAS), in gamma space: the pixel pushed away from its
// four neighbours by a negative lobe, as much as can be without leaving the range their
// minimum and maximum allow, so it never overshoots; 'stops' weakens it.
float3 sharpen_rcas(Texture2D<float4> image, int2 at, float stops) {
    float3 b = to_srgb(image.Load(int3(at + int2(0, -1), 0)).rgb);
    float3 d = to_srgb(image.Load(int3(at + int2(-1, 0), 0)).rgb);
    float3 e = to_srgb(image.Load(int3(at, 0)).rgb);
    float3 f = to_srgb(image.Load(int3(at + int2(1, 0), 0)).rgb);
    float3 h = to_srgb(image.Load(int3(at + int2(0, 1), 0)).rgb);
    float3 low  = min(min(b, d), min(f, h));
    float3 high = max(max(b, d), max(f, h));
    float3 hit_low  = low / (4.0 * high + 1e-5);
    float3 hit_high = (1.0 - high) / (4.0 * low - 4.0 - 1e-5);
    float3 lobe3 = max(-hit_low, hit_high);
    float lobe = max(-0.1875, min(max(lobe3.r, max(lobe3.g, lobe3.b)), 0.0)) * exp2(-stops);
    return saturate((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0));
}

float3 load_output(Texture2D<float4> image, int2 at) {
    if (output_params.z != 0) return sharpen_rcas(image, at, fraction.y);
    return to_srgb(image.Load(int3(at, 0)).rgb);
}

float4 main(float4 position : SV_Position) : SV_Target0 {
    int2 at = int2(position.xy);
    float f = fraction.x;
    float3 color = load_output(first, at);
    if (output_params.w != 0) {
        // The new picture over the old, its edges softened over one output pixel, as they
        // move by fractions of one; then the fade, both drawn through its palette.
        float2 p = position.xy;
        float inside = saturate(min(min(p.x - wipe.x, wipe.z - p.x), min(p.y - wipe.y, wipe.w - p.y)) + 0.5);
        if (inside > 0) color = lerp(color, load_output(second, int2(floor(p - shift.xy))), inside);
        if      (output_params.x == FADE_TO_MONO)   color *= 1.0 - f;
        else if (output_params.x == FADE_FROM_MONO) color *= f;
    }
    else if (output_params.x == FADE_TO_MONO)   color = color * (1.0 - f);
    else if (output_params.x == FADE_FROM_MONO) color = load_output(second, at) * f;
    else if (output_params.x == FADE_PALETTE)   color = lerp(color, load_output(second, at), f);
    if (output_params.y != 0) color += get_dither(position.xy);
    return float4(color, 1);
}

#else

#ifdef RGB
Texture2D<float4> image   : register(t0, space2);  // DELT: sRGB colors; CRAWL: 16-bit indices.
#else
Texture2D<float>  image   : register(t0, space2);  // 16-bit normalized indices.
#endif
Texture2D<float4> table   : register(t1, space2);  // CRAWL: the row tables; DELT_TWEEN: frame B.
#ifdef RGB
Texture2D<float4> palette : register(t2, space2);  // CRAWL: 256 x 1, sRGB.
#endif

cbuffer Film : register(b0, space3) {
    int4   params;      // Mode; DELT, DELT_TWEEN: the filter (sample_outline); CRAWL: scroll offset (16.16), text width, height.
    float4 params_f;    // The image's scale of the 320x200 screen, across and down; CRAWL_SMOOTH:
                        // how far the image reaches past the screen's left edge.
    float4 params_g;    // CRAWL_SMOOTH: the text's full color (sRGB), the steps down to black.
    float4 params_h;    // DELT_TWEEN: see draw_delt_tween.
    float4 params_i;
};


uint load_index(int2 at) {
#ifdef RGB
    return uint(round(image.Load(int3(at, 0)).r * 65535.0));
#else
    return uint(round(image.Load(int3(at, 0)) * 65535.0));
#endif
}

float to_target(uint index) {
    return float(index + 1) / 65535.0;
}

// Two ints from a texel of 16-bit halves.
int2 load_pair(int x, int y) {
    uint4 h = uint4(round(table.Load(int3(x, y, 0)) * 65535.0));
    return asint(uint2(h.x | (h.y << 16), h.z | (h.w << 16)));
}

// Per row: offset, scale, x at the first pixel, first pixel; then last pixel, fade. Returns
// the palette index at the pixel.
uint find_crawl_index(float4 position) {
    int x = int(floor(position.x / params_f.x));
    int y = int(floor(position.y / params_f.y)) - CRAWL_TOP;
    if (y < 0 || y >= CRAWL_ROWS) discard;
    int4 a = int4(load_pair(0, y), load_pair(1, y));
    int4 b = int4(load_pair(2, y), load_pair(3, y));
    int width = params.z, height = params.w;
    int v = (a.x + params.y + 0x8000) >> 16;
    if (v < 0 || v >= height) discard;
    if (x < a.w || x > b.x) discard;
    int at = a.z + a.y * (x - a.w);
    int i = v * width + ((at + 0x8000) >> 16);
    if (i < 0 || i >= width * height) discard;
    int color = int(load_index(int2(i % width, i / width)));
    if (color == 0) discard;
    return uint(max(CRAWL_DARKEST, color - b.y));
}

#ifdef RGB

// A texel of a color image (linear, premultiplied); nothing outside it.
float4 load_texel(Texture2D<float4> tex, int2 at, int2 size) {
    if (at.x < 0 || at.y < 0 || at.x >= size.x || at.y >= size.y) return 0;
    return tex.Load(int3(at, 0));
}

// FSR 1's edge-adaptive upscaling (EASU), sampling the image at 'p' (texels; texel k covers k
// to k + 1). Twelve texels around the point (the 2x2 it falls in, and two beyond each side of
// it) give the local edge: each of the middle four contributes its gradient direction and a
// measure of how much of an edge it sits on, weighted bilinearly. The texels are then filtered
// by a Lanczos-like kernel turned along that edge and stretched along it the more distinct the
// edge is (diagonals more than straight edges), so edges stay sharp across and smooth along.
// The result is held within the middle four's range, so the kernel's negative lobe can't
// ring. Brightness for the analysis is taken in gamma space, as FSR expects; the filtering is
// on linear, premultiplied color.
float easu_luma(float4 c) {
    float3 g = to_srgb(c.rgb);
    return g.b * 0.5 + (g.r * 0.5 + g.g);
}

void easu_add_direction(inout float2 direction, inout float edge, float w, float lA, float lB, float lC, float lD, float lE) {
    // Across: B to D through C.
    float dc = lD - lC;
    float cb = lC - lB;
    float len_x = max(abs(dc), abs(cb));
    len_x = len_x > 0 ? 1.0 / len_x : 0;
    float dir_x = lD - lB;
    direction.x += dir_x * w;
    len_x = saturate(abs(dir_x) * len_x);
    edge += len_x * len_x * w;
    // Down: A to E through C.
    float ec = lE - lC;
    float ca = lC - lA;
    float len_y = max(abs(ec), abs(ca));
    len_y = len_y > 0 ? 1.0 / len_y : 0;
    float dir_y = lE - lA;
    direction.y += dir_y * w;
    len_y = saturate(abs(dir_y) * len_y);
    edge += len_y * len_y * w;
}

void easu_tap(inout float4 sum, inout float total, float2 offset, float2 direction, float2 stretch, float lobe, float clip, float4 color) {
    // Turned along the edge, then stretched.
    float2 v = float2(offset.x * direction.x + offset.y * direction.y, offset.x * -direction.y + offset.y * direction.x) * stretch;
    float d2 = min(dot(v, v), clip);
    // A cheap Lanczos-2: (25/16 (2/5 d2 - 1)^2 - (25/16 - 1)) times (lobe d2 - 1)^2.
    float wb = 2.0 / 5.0 * d2 - 1.0;
    float wa = lobe * d2 - 1.0;
    wb *= wb;
    wa *= wa;
    wb = 25.0 / 16.0 * wb - (25.0 / 16.0 - 1.0);
    float w = wb * wa;
    sum += color * w;
    total += w;
}

float4 sample_easu(Texture2D<float4> tex, float2 p, int2 size) {
    float2 pp = p - 0.5;            // Texel middles at whole numbers.
    int2 o = int2(floor(pp));
    float2 t = pp - o;
    //     b c
    //   e f g h
    //   i j k l
    //     n o      (f at o)
    float4 b = load_texel(tex, o + int2(0, -1), size), c = load_texel(tex, o + int2(1, -1), size);
    float4 e = load_texel(tex, o + int2(-1, 0), size), f = load_texel(tex, o, size);
    float4 g = load_texel(tex, o + int2(1, 0), size),  h = load_texel(tex, o + int2(2, 0), size);
    float4 i = load_texel(tex, o + int2(-1, 1), size), j = load_texel(tex, o + int2(0, 1), size);
    float4 k = load_texel(tex, o + int2(1, 1), size),  l = load_texel(tex, o + int2(2, 1), size);
    float4 n = load_texel(tex, o + int2(0, 2), size),  q = load_texel(tex, o + int2(1, 2), size);
    float lb = easu_luma(b), lc = easu_luma(c), le = easu_luma(e), lf = easu_luma(f), lg = easu_luma(g), lh = easu_luma(h);
    float li = easu_luma(i), lj = easu_luma(j), lk = easu_luma(k), ll = easu_luma(l), ln = easu_luma(n), lo = easu_luma(q);

    float2 direction = 0;
    float edge = 0;
    easu_add_direction(direction, edge, (1 - t.x) * (1 - t.y), lb, le, lf, lg, lj);
    easu_add_direction(direction, edge, t.x * (1 - t.y),       lc, lf, lg, lh, lk);
    easu_add_direction(direction, edge, (1 - t.x) * t.y,       lf, li, lj, lk, ln);
    easu_add_direction(direction, edge, t.x * t.y,             lg, lj, lk, ll, lo);

    float r = dot(direction, direction);
    if (r < 1.0 / 32768.0) direction = float2(1, 0);
    else                    direction *= rsqrt(r);
    edge = edge * 0.5;
    edge *= edge;
    // 1 for an edge along an axis, up to sqrt 2 for a diagonal.
    float along = dot(direction, direction) / max(abs(direction.x), abs(direction.y));
    float2 stretch = float2(1.0 + (along - 1.0) * edge, 1.0 - 0.5 * edge);
    float lobe = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * edge;
    float clip = 1.0 / lobe;

    float4 sum = 0;
    float total = 0;
    easu_tap(sum, total, float2( 0, -1) - t, direction, stretch, lobe, clip, b);
    easu_tap(sum, total, float2( 1, -1) - t, direction, stretch, lobe, clip, c);
    easu_tap(sum, total, float2(-1,  1) - t, direction, stretch, lobe, clip, i);
    easu_tap(sum, total, float2( 0,  1) - t, direction, stretch, lobe, clip, j);
    easu_tap(sum, total, float2( 0,  0) - t, direction, stretch, lobe, clip, f);
    easu_tap(sum, total, float2(-1,  0) - t, direction, stretch, lobe, clip, e);
    easu_tap(sum, total, float2( 1,  1) - t, direction, stretch, lobe, clip, k);
    easu_tap(sum, total, float2( 2,  1) - t, direction, stretch, lobe, clip, l);
    easu_tap(sum, total, float2( 2,  0) - t, direction, stretch, lobe, clip, h);
    easu_tap(sum, total, float2( 1,  0) - t, direction, stretch, lobe, clip, g);
    easu_tap(sum, total, float2( 1,  2) - t, direction, stretch, lobe, clip, q);
    easu_tap(sum, total, float2( 0,  2) - t, direction, stretch, lobe, clip, n);
    float4 color = sum / total;
    float4 low  = min(min(f, g), min(j, k));
    float4 high = max(max(f, g), max(j, k));
    return clamp(color, low, high);
}

// How different two texels look: their colors in gamma space (closer to how they're seen),
// weighted for brightness, and whether there's anything there at all, which counts most.
float get_difference(float4 a, float4 b) {
    float3 ga = a.a > 0 ? to_srgb(a.rgb / a.a) : 0;
    float3 gb = b.a > 0 ? to_srgb(b.rgb / b.a) : 0;
    return dot(abs(ga - gb), float3(0.299, 0.587, 0.114)) + 2.0 * abs(a.a - b.a);
}

// The image at 'p' (texels; texel k covers k to k + 1), magnified with its diagonal edges
// followed. Each output pixel looks at the corner of its texel E it lies toward: E's
// neighbours F across and H down that way, I between them, and the ring beyond. When the
// line through F and H is more continuous than the one through E and I (differences summed
// along each, the middle pair counted four times) and E differs from both, an edge cuts E's
// corner off: past the line halfway across the corner, the pixel takes whichever of F and H
// is nearer E's color. 'soft' is how many texels an output pixel spans, for smoothing the
// line by one output pixel.
float4 sample_edges(Texture2D<float4> tex, float2 p, int2 size, float2 soft) {
    int2 e = int2(floor(p));
    float2 f = p - e - 0.5;
    int2 s = int2(f.x < 0 ? -1 : 1, f.y < 0 ? -1 : 1);
    float2 q = abs(f);                              // 0 at the texel's middle, 0.5 at its edge.
    float4 E = load_texel(tex, e, size);
    float4 F = load_texel(tex, e + int2(s.x, 0), size);
    float4 H = load_texel(tex, e + int2(0, s.y), size);
    float4 I = load_texel(tex, e + s, size);
    float dEF = get_difference(E, F), dEH = get_difference(E, H);
    if (dEF <= 0.0 || dEH <= 0.0) return E;
    // Named as if toward the bottom right; the others are mirror images.
    float4 B  = load_texel(tex, e + int2(0, -s.y), size);
    float4 D  = load_texel(tex, e + int2(-s.x, 0), size);
    float4 C  = load_texel(tex, e + int2(s.x, -s.y), size);
    float4 G  = load_texel(tex, e + int2(-s.x, s.y), size);
    float4 F4 = load_texel(tex, e + int2(2 * s.x, 0), size);
    float4 I4 = load_texel(tex, e + int2(2 * s.x, s.y), size);
    float4 H5 = load_texel(tex, e + int2(0, 2 * s.y), size);
    float4 I5 = load_texel(tex, e + int2(s.x, 2 * s.y), size);
    float along_fh = get_difference(E, C) + get_difference(E, G) + get_difference(I, F4) + get_difference(I, H5) + 4.0 * get_difference(H, F);
    float along_ei = get_difference(H, D) + get_difference(H, I5) + get_difference(F, I4) + get_difference(F, B) + 4.0 * get_difference(E, I);
    if (along_fh >= along_ei) return E;
    float4 corner = dEF <= dEH ? F : H;
    float width = max(dot(soft, 0.5), 0.001);
    float cut = smoothstep(0.5 - width, 0.5 + width, q.x + q.y);
    return lerp(E, corner, cut);
}

// The text at a point on the screen (320x200 units, pixel centers at +0.5), its edges
// followed; 'pixel' is the output pixel's size in screen pixels.
// Catmull-Rom weights for the four texels around a point t of the way between the middle two,
// and their slopes. It passes through each texel's own value, so a lone pixel or a line one
// pixel wide keeps its size at the half cut (a B-spline smooths a lone pixel to 0.44, under it:
// stars vanished).
float4 get_catmull_rom(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-t3 + 2.0 * t2 - t, 3.0 * t3 - 5.0 * t2 + 2.0, -3.0 * t3 + 4.0 * t2 + t, t3 - t2) * 0.5;
}

float4 get_catmull_rom_slope(float t) {
    float t2 = t * t;
    return float4(-3.0 * t2 + 4.0 * t - 1.0, 9.0 * t2 - 10.0 * t, -9.0 * t2 + 8.0 * t + 1.0, 3.0 * t2 - 2.0 * t) * 0.5;
}

// The picture with smooth outlines. Coverage (whether a texel is drawn) filtered by a cubic is
// a smooth, rounded field, a distance field in effect, made as it's drawn; the outline is where
// it crosses one half, softened over one output pixel ('footprint' is texels per output pixel),
// so it's as crisp at any size. Inside, the color is EASU's.
// 'filter' picks the color inside, while the filters are compared: 0 EASU, 1 Catmull-Rom,
// 2 bilinear, 3 nearest, 4 sample_edges.
float4 sample_outline(Texture2D<float4> tex, float2 p, int2 size, float2 footprint, int filter) {
    float2 pp = p - 0.5;
    float2 f = floor(pp);
    float2 t = pp - f;
    int2 o = int2(f) - 1;
    float4 wx = get_catmull_rom(t.x), wy = get_catmull_rom(t.y);
    float4 sx = get_catmull_rom_slope(t.x), sy = get_catmull_rom_slope(t.y);
    float coverage = 0;
    float2 slope = 0;
    float4 sum = 0;
    // Whether coverage changes only across x, or only down y: a straight edge along the texels.
    bool across = true, down = true;
    float first_row[4];
    float first_column = 0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float4 c = load_texel(tex, o + int2(i, j), size);
            float k = c.a;
            coverage += wx[i] * wy[j] * k;
            slope += float2(sx[i] * wy[j], wx[i] * sy[j]) * k;
            sum += wx[i] * wy[j] * c;
            if (j == 0) first_row[i] = k;
            else if (k != first_row[i]) across = false;
            if (i == 0) first_column = k;
            else if (k != first_column) down = false;
        }
    }
    float soft = 0.5 * length(slope * footprint) + 0.0001;
    float edge = saturate((coverage - 0.5) / (2.0 * soft) + 0.5);
    // A straight edge along the texels is kept hard, cut at the texel boundary, as the
    // original draws it: that's where a patch meets the art it was cut from (a talking head
    // on its body), and two edges softened there both let through what's behind.
    if ((across || down) && coverage > 0.0001 && coverage < 0.9999) {
        edge = load_texel(tex, int2(floor(p)), size).a > 0.5 ? 1.0 : 0.0;
    }
    if (edge <= 0) return 0;
    float4 e;
    if (filter == 0) {
        e = sample_easu(tex, p, size);
    } else if (filter == 1) {
        // Clamped to the middle four, as EASU is, against the cubic's ringing.
        float4 f0 = load_texel(tex, o + int2(1, 1), size), f1 = load_texel(tex, o + int2(2, 1), size);
        float4 f2 = load_texel(tex, o + int2(1, 2), size), f3 = load_texel(tex, o + int2(2, 2), size);
        e = clamp(sum, min(min(f0, f1), min(f2, f3)), max(max(f0, f1), max(f2, f3)));
    } else if (filter == 2) {
        float4 f0 = load_texel(tex, o + int2(1, 1), size), f1 = load_texel(tex, o + int2(2, 1), size);
        float4 f2 = load_texel(tex, o + int2(1, 2), size), f3 = load_texel(tex, o + int2(2, 2), size);
        e = lerp(lerp(f0, f1, t.x), lerp(f2, f3, t.x), t.y);
    } else if (filter == 4) {
        e = sample_edges(tex, p, size, footprint);
    } else {
        e = load_texel(tex, int2(floor(p)), size);
    }
    float3 rgb = e.a > 0.5 ? e.rgb / e.a : max(sum.rgb, 0) / max(sum.a, 0.0001);
    return float4(rgb * edge, edge);
}

#define CRAWL_FIELD_SPREAD 16.0   // Field texels either way of the outline (crawl.jai).

// A texel of the crawl's distance field, in field texels, positive outside; far outside past
// its edges.
float load_field(int2 at, int2 size) {
    if (at.x < 0 || at.y < 0 || at.x >= size.x || at.y >= size.y) return CRAWL_FIELD_SPREAD;
    return (image.Load(int3(at, 0)).r - 0.5) * 2.0 * CRAWL_FIELD_SPREAD;
}

// CRAWL_SMOOTH: each output pixel solved on the original's plane, the text drawn from its
// signed distance field. The outline is softened over one output pixel, from how many field
// texels the pixel spans across and down there and the field's slope, so it's as crisp in the
// nearest rows as in the far ones; the field is filtered bilinearly, which distances take
// cleanly.
float4 draw_crawl_smooth(float4 position) {
    float2 scale = params_f.xy;
    float2 screen = position.xy / scale - float2(params_f.z, 0);
    if (screen.y < CRAWL_TOP || screen.y >= CRAWL_TOP + CRAWL_ROWS) discard;
    float y = screen.y - 0.5 - (CRAWL_TOP - 1);                 // Rows from the eye's horizon.
    float z = 60.0 * 210.0 / (y * 0.9);
    float half_width = CRAWL_HALF_WIDTH / z;
    float across = (params.z - 1) / (2.0 * half_width + 1.0);  // Text pixels per screen pixel.
    float down = z / y;                                         // Text rows per screen row.
    float u = (screen.x - 0.5 - 160.0 + half_width) * across;
    float v = params.w - z + params.y / 65536.0;
    // Text texel k's middle is at k (the original rounds); field texel j's at (j + 0.5) / F - 0.5.
    float F = params_f.w;
    float2 p = (float2(u, v) + 0.5) * F - 0.5;
    float2 f = floor(p);
    float2 t = p - f;
    int2 o = int2(f);
    int2 size = int2(params.z, params.w) * int(F);
    float d00 = load_field(o, size), d10 = load_field(o + int2(1, 0), size);
    float d01 = load_field(o + int2(0, 1), size), d11 = load_field(o + int2(1, 1), size);
    float d = lerp(lerp(d00, d10, t.x), lerp(d01, d11, t.x), t.y);
    float2 slope = float2(lerp(d10 - d00, d11 - d01, t.y), lerp(d01 - d00, d11 - d10, t.x));
    float2 footprint = float2(across, down) / scale * F;       // Field texels per output pixel.
    float soft = 0.5 * length(slope * footprint) + 0.0001;
    float a = saturate(0.5 - d / (2.0 * soft));
    if (a <= 0) discard;
    float fade = z > 100.0 ? 0.1 * (z - 100.0) : 0.0;
    float3 g = params_g.rgb - fade / params_g.w * params_g.rgb;
    return float4(to_linear(max(g, 0)) * a, a);
}

// The motion takes a point x of frame A to s x + d in frame B (actor-local pixels). Part t of
// the way it is s^t x + d_t, with d_t keeping the same fixed point, so a zoom goes at an even
// rate. An output pixel at local point x shows A at the point that motion brings to x, and B
// at where the rest of it takes that point, blended by t.
//   params_f: target pixel of the actor's origin, target pixels per local pixel (x, y)
//   params_g: s^t, d_t, t      params_h: s, d      params_i: A's and B's top-left (local)
float4 draw_delt_tween(float4 position) {
    float2 local = (position.xy - params_f.xy) / params_f.zw;
    float2 a = (local - params_g.yz) / params_g.x;
    float2 b = params_h.x * a + params_h.yz;
    uint aw, ah, bw, bh;
    image.GetDimensions(aw, ah);
    table.GetDimensions(bw, bh);
    float2 footprint = 1.0 / params_f.zw;
    float4 ca = sample_outline(image, a - params_i.xy, int2(aw, ah), footprint / params_g.x, params.y);
    float4 cb = sample_outline(table, b - params_i.zw, int2(bw, bh), footprint * params_h.x / params_g.x, params.y);
    float4 color = lerp(ca, cb, params_g.w);
    if (color.a <= 0) discard;
    return color;
}

float4 main(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target0 {
    if (params.x == MODE_DELT_TWEEN) return draw_delt_tween(position);
    if (params.x == MODE_CRAWL_SMOOTH) return draw_crawl_smooth(position);
    if (params.x == MODE_CRAWL) return float4(palette.Load(int3(find_crawl_index(position), 0, 0)).rgb, 1);
    uint width, height;
    image.GetDimensions(width, height);
    float4 color = sample_outline(image, uv, int2(width, height), fwidth(uv), params.y);
    if (color.a <= 0) discard;
    return color;
}

#else

float main(float4 position : SV_Position, float2 uv : TEXCOORD0) : SV_Target0 {
    if (params.x == MODE_CRAWL) return to_target(find_crawl_index(position));
    uint index = load_index(int2(floor(uv)));
    if (index == 0x100) discard;
    return to_target(index);
}

#endif
#endif
