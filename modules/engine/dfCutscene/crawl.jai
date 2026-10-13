// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The opening text crawl (scene 30): the "textcraw" DELT laid flat and seen in perspective
// over rows 30 to 198, scrolled by the actor's y and darkened with distance toward the
// palette's index 224. The math is the original's, in 16.16 fixed point.

Crawl :: struct {
    actor:  *Actor;
    bitmap: [] u8;
    width, height: s32;
    rows: [CRAWL_ROWS] Crawl_Row;
}

#scope_module

open_crawl :: (crawl: *Crawl, actor: *Actor) {
    close_crawl(crawl);
    delt := actor.frames[0];
    left, top, right, bottom := get_delt_bounds(delt);
    crawl.actor  = actor;
    crawl.width  = right - left + 1;
    crawl.height = bottom - top + 1;
    crawl.bitmap = NewArray(crawl.width * crawl.height, u8);
    draw_delt_flat(crawl, delt);
    build_rows(crawl);
}

close_crawl :: (crawl: *Crawl) {
    array_free(crawl.bitmap);
    crawl.* = .{};
}

// The scroll for this frame, in 16.16 bitmap rows. Drawing the crawl moves it along first
// when frames run long, as the original does.
get_crawl_offset :: (crawl: *Crawl, a: *Actor) -> s32 {
    catch_up(a);
    return ((200 - a.y) << 14) - (430 << 16);
}

draw_crawl_rows :: (crawl: *Crawl, canvas: [] u8, offset: s32) {
    for index: 0..CRAWL_DRAWN_ROWS-1 {
        row := *crawl.rows[index];
        v := round16(row.offset + offset);
        if v < 0 || v >= crawl.height continue;
        at := row.clipped_x_start;
        out := canvas.data + (CRAWL_TOP + index) * CANVAS_WIDTH;
        source := v * crawl.width;
        for x: row.first..row.last {
            i := source + round16(at);
            at += row.scale;
            if i < 0 || i >= crawl.bitmap.count continue;
            color := cast(s32) crawl.bitmap[i];
            if color  out[x] = cast(u8) max(CRAWL_DARKEST, color - row.fade);
        }
    }
}

CRAWL_TOP     :: 30;
CRAWL_BOTTOM  :: 199;
CRAWL_ROWS    :: CRAWL_BOTTOM - CRAWL_TOP + 1;
CRAWL_DRAWN_ROWS :: CRAWL_ROWS - 1;   // The original stops before row 199.
CRAWL_DARKEST :: 224;

Crawl_Row :: struct {
    offset:  s32;   // Bitmap row at scroll 0, 16.16.
    scale:   s32;   // Bitmap pixels per screen pixel, 16.16.
    x_start: s32;   // Bitmap x at the row's first pixel, 16.16.
    start:   s32;   // First screen x.
    width:   s32;
    fade:    s32;   // Color indices to darken by.
    // The row cut to the canvas: its screen pixels and the bitmap x at the first.
    first, last: s32;
    clipped_x_start: s32;
}

#scope_file


EYE_HEIGHT     : s32 : 60 << 16;
VIEW_DISTANCE  : s32 : 210 << 16;
HALF_WIDTH     : s32 : 1010 << 16;  // Of the 2020-unit plane.
PIXEL_SIZE     : s32 : 0xE666;      // 0.9
FADE_START     : s32 : 100 << 16;
FADE_PER_UNIT  : s32 : 0x1999;      // 0.1

build_rows :: (crawl: *Crawl) {
    numerator := mul16(EYE_HEIGHT, VIEW_DISTANCE);
    for * row: crawl.rows {
        sy := CRAWL_TOP + cast(s32) it_index;
        z := div16(div16(numerator, (sy - (CRAWL_TOP - 1)) << 16), PIXEL_SIZE);
        row.offset = (crawl.height << 16) - z;
        xl := div16(mul16(-HALF_WIDTH, VIEW_DISTANCE), z);
        xr := div16(mul16(HALF_WIDTH, VIEW_DISTANCE), z);
        row.width = round16(xr - xl);
        row.start = round16(xl) + CANVAS_WIDTH / 2;
        row.scale = div16((crawl.width - 1) << 16, xr - xl + 0x10000);
        row.x_start = mul16((round16(xl) << 16) - xl, row.scale);
        row.fade = ifx z > FADE_START then round16(mul16(FADE_PER_UNIT, z - FADE_START)) else 0;

        row.first = row.start;
        row.last  = row.start + row.width - 1;
        row.clipped_x_start = row.x_start;
        if row.first < 0 {
            row.clipped_x_start += mul16(row.scale, (-row.first) << 16);
            row.first = 0;
        }
        if row.last >= CANVAS_WIDTH  row.last = CANVAS_WIDTH - 1;
    }
}

// The original makes up for frames that ran long: the ticks past the frame delay pile up in
// the actor's y fraction, and once they come to more than a frame, with more than 10 cells
// left, the crawl skips cells to catch up. Only the excess of a single frame is divided,
// though, so with frames a tick or two long nothing is ever skipped, and the pile instead
// moves the crawl a pixel each time it passes 256.
catch_up :: (a: *Actor) {
    delay := cut.frame_delay;
    excess := cut.clock.last_frame_ticks - delay;
    if excess <= 0 return;
    a.y_fract = cast(s32) cast,trunc(s16) (a.y_fract + excess);
    if delay < a.y_fract && cut.film.cell_count - cut.film.cell > 10 {
        n := excess / delay;
        a.y += a.y_vel * n;
        cut.film.cell += n;
        a.y_fract -= delay * n;
    }
}

// The DELT's lines into the bitmap, at their own coordinates.
draw_delt_flat :: (crawl: *Crawl, delt: [] u8) {
    at := 8;
    while true {
        header := get_u16(delt, at);
        if header == 0 break;
        x := get_s16(delt, at + 2);
        y := get_s16(delt, at + 4);
        at += 6;
        count := cast(s32) (header >> 1);
        put :: (value: u8) #expand {
            if x >= 0 && x < crawl.width && y >= 0 && y < crawl.height  crawl.bitmap[y * crawl.width + x] = value;
            x += 1;
        }
        if !(header & 1) {
            for 0..count-1  put(delt[at + it]);
            at += count;
            continue;
        }
        while count > 0 {
            code := delt[at];
            run := cast(s32) (code >> 1);
            at += 1;
            if code & 1 {
                value := delt[at];
                at += 1;
                for 0..run-1  put(value);
            } else {
                for 0..run-1  put(delt[at + it]);
                at += run;
            }
            count -= run;
        }
    }
}

// 16.16 helpers as the original computes them: products shifted down (rounding toward minus
// infinity), quotients from a 64-bit division (toward zero), rounding by adding a half.
mul16 :: (a: s32, b: s32) -> s32 {
    x, y: s64 = a, b;
    return cast,trunc(s32) ((x * y) >> 16);
}

div16 :: (a: s32, b: s32) -> s32 {
    x, y: s64 = a, b;
    return cast,trunc(s32) ((x << 16) / y);
}

round16 :: (a: s32) -> s32 {
    return (a + 0x8000) >> 16;
}

#scope_module

// Enhanced draws the crawl's text from a signed distance field, so its outlines are smooth and
// crisp at every distance down the plane. The glyphs' coverage is their brightness up the text's
// ramp, which runs evenly from black at CRAWL_DARKEST to the text's brightest index, so their
// darker pixels are their anti-aliasing. It's interpolated CRAWL_FIELD_SCALE times finer
// (interpolate_field) and cut at CRAWL_FIELD_CUT; the field is each texel's distance to the
// cut, in field texels, positive outside. Texels on the cut (a neighbour on its other side) take
// it from the smooth coverage, (cut - coverage) over its slope, which places the outline to a
// fraction of a texel: the near rows magnify a texel some 25 times, and the cut
// alone showed as steps. The rest take the exact Euclidean distance to the cut. As 16-bit
// values, 0.5 on the outline, reaching CRAWL_FIELD_SPREAD texels either way.
CRAWL_FIELD_SCALE  :: 4;
CRAWL_FIELD_SPREAD :: 16.0;
// Most of each stroke is gradient: the opening's text has some 25,000 pixels spread evenly up
// the ramp to 9,700 at its top. Cut at one half, the glyphs came out bold, their counters small,
// letters running together; higher, thin strokes thin out further (0.7 breaks them).
CRAWL_FIELD_CUT    :: 0.55;

build_crawl_field :: (crawl: *Crawl) -> values: [] u16, width: s32, height: s32 {
    w, h := crawl.width, crawl.height;
    if w <= 0 || h <= 0 return .[], 0, 0;
    brightest: u8;
    for crawl.bitmap  brightest = max(brightest, it);
    steps := cast(float) max(cast(s32) brightest - CRAWL_DARKEST, 1);
    coverage := NewArray(w * h, float,, temp);
    for crawl.bitmap  if it  coverage[it_index] = clamp((cast(s32) it - CRAWL_DARKEST) / steps, 0, 1);

    F :: CRAWL_FIELD_SCALE;
    fw, fh := w * F, h * F;
    // Across, then down. Field texel j's middle is at (j + 0.5) / F - 0.5 in text texels, whose
    // middles are at whole numbers.
    across := NewArray(fw * h, float,, temp);
    for y: 0..h-1  for x: 0..fw-1 {
        across[y * fw + x] = interpolate_field(coverage.data + y * w, w, 1, (x + 0.5) / F - 0.5);
    }
    fine := NewArray(fw * fh, float,, temp);
    inside := NewArray(fw * fh, bool,, temp);
    for y: 0..fh-1  for x: 0..fw-1 {
        c := interpolate_field(across.data + x, h, fw, (y + 0.5) / F - 0.5);
        fine[y * fw + x] = c;
        inside[y * fw + x] = c > CRAWL_FIELD_CUT;
    }
    get_fine :: (x: s32, y: s32) -> float #expand {
        return fine[clamp(y, 0, fh - 1) * fw + clamp(x, 0, fw - 1)];
    }
    is_inside :: (x: s32, y: s32) -> bool #expand {
        if x < 0 || y < 0 || x >= fw || y >= fh return false;
        return inside[y * fw + x];
    }

    to_inside  := get_squared_distances(inside, fw, fh, true);
    to_outside := get_squared_distances(inside, fw, fh, false);
    values := NewArray(fw * fh, u16);
    for y: 0..fh-1  for x: 0..fw-1 {
        i := y * fw + x;
        // Texel middles are half a texel from the cut between them.
        d := ifx inside[i] then -(sqrt(to_outside[i]) - 0.5) else sqrt(to_inside[i]) - 0.5;
        on_cut := is_inside(x - 1, y) != inside[i] || is_inside(x + 1, y) != inside[i] || is_inside(x, y - 1) != inside[i] || is_inside(x, y + 1) != inside[i];
        if on_cut {
            slope := Vector2.{get_fine(x + 1, y) - get_fine(x - 1, y), get_fine(x, y + 1) - get_fine(x, y - 1)} * 0.5;
            steepness := length(slope);
            if steepness > 0.0001  d = clamp((CRAWL_FIELD_CUT - fine[i]) / steepness, -1.5, 1.5);
        }
        values[i] = cast(u16) (clamp(0.5 + d / (2 * CRAWL_FIELD_SPREAD), 0, 1) * 65535 + 0.5);
    }
    return values, fw, fh;
}

#scope_file

// Half a cubic B-spline, half Catmull-Rom. The B-spline alone rounds the glyphs best but
// approximates: it takes a stroke a pixel wide down to two thirds of its brightness, and the cut
// pinched the font's thin parts (where the h's arc leaves its stem, the t in "station").
// Catmull-Rom alone keeps them but follows the pixels, its outlines lumpy. Half of each keeps
// most of a thin stroke and most of the smoothness, at a cut a little lower than the B-spline's
// 0.6.
interpolate_field :: (values: *float, count: s32, stride: s32, at: float) -> float {
    return 0.5 * (interpolate_bspline(values, count, stride, at) + interpolate_catmull_rom(values, count, stride, at));
}

// Catmull-Rom through 'count' values 'stride' apart, at 'at', clamped to the two values it
// falls between, so it passes through every value and never rings; nothing outside.
interpolate_catmull_rom :: (values: *float, count: s32, stride: s32, at: float) -> float {
    f := floor(at);
    t := at - f;
    t2 := t * t;
    t3 := t2 * t;
    w := float.[-t3 + 2 * t2 - t, 3 * t3 - 5 * t2 + 2, -3 * t3 + 4 * t2 + t, t3 - t2];
    first := cast(s32) f - 1;
    get :: (k: s32) -> float #expand { return ifx k < 0 || k >= count then 0.0 else values[k * stride]; }
    sum: float;
    for i: 0..3  sum += w[i] * get(first + cast(s32) i);
    sum *= 0.5;
    a, b := get(first + 1), get(first + 2);
    return clamp(sum, min(a, b), max(a, b));
}

// A cubic B-spline through 'count' values 'stride' apart, at 'at' (values' middles at whole
// numbers); nothing outside.
interpolate_bspline :: (values: *float, count: s32, stride: s32, at: float) -> float {
    f := floor(at);
    t := at - f;
    s := 1 - t;
    w := float.[s * s * s, 3 * t * t * t - 6 * t * t + 4, -3 * t * t * t + 3 * t * t + 3 * t + 1, t * t * t];
    first := cast(s32) f - 1;
    sum: float;
    for i: 0..3 {
        k := first + i;
        if k < 0 || k >= count continue;
        sum += w[i] * values[k * stride];
    }
    return sum / 6;
}

// For every texel, the squared distance to the nearest texel that is ('to_inside') or isn't
// inside, by Felzenszwalb and Huttenlocher's exact transform: down each column, then across
// each row.
get_squared_distances :: (inside: [] bool, w: s32, h: s32, to_inside: bool) -> [] float {
    FAR :: 1.0e20;
    d := NewArray(w * h, float,, temp);
    for inside  d[it_index] = ifx it == to_inside then 0.0 else FAR;
    n := max(w, h);
    line   := NewArray(n, float,, temp);
    result := NewArray(n, float,, temp);
    v := NewArray(n, s32,, temp);
    z := NewArray(n + 1, float,, temp);
    transform :: (count: s32) #expand {
        k := 0;
        v[0] = 0;
        z[0], z[1] = -FAR, FAR;
        get_crossing :: (q: s32, p: s32) -> float #expand {
            return ((line[q] + cast(float) q * q) - (line[p] + cast(float) p * p)) / (2.0 * (q - p));
        }
        // The lower envelope of the parabolas rooted at each texel; z[0] is far below any
        // crossing, so k never goes under 0.
        for q: 1..count-1 {
            s := get_crossing(q, v[k]);
            while s <= z[k] {
                k -= 1;
                s = get_crossing(q, v[k]);
            }
            k += 1;
            v[k] = q;
            z[k] = s;
            z[k + 1] = FAR;
        }
        k = 0;
        for q: 0..count-1 {
            while z[k + 1] < cast(float) q  k += 1;
            p := v[k];
            result[q] = (cast(float) q - p) * (q - p) + line[p];
        }
    }
    for x: 0..w-1 {
        for y: 0..h-1  line[y] = d[y * w + x];
        transform(h);
        for y: 0..h-1  d[y * w + x] = result[y];
    }
    for y: 0..h-1 {
        for x: 0..w-1  line[x] = d[y * w + x];
        transform(w);
        for x: 0..w-1  d[y * w + x] = result[x];
    }
    return d;
}

#import "Basic";
#import "Math";
