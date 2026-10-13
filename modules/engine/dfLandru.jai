// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Landru, the LucasArts system the game's cutscenes, menus and briefings are drawn with: its
// resources in the LFDs. DELT is a 2D image coded as runs of lines, ANIM a list of DELTs (the
// frames of an animation), FONT a 1-bit font. Palettes (PLTT) are in dfImage.
//
// A DELT draws only its lines' pixels; everything else shows what is behind it. The decoded
// image keeps that as a mask beside the palette indices, since index 0 is a real color here.

Delt :: struct {
    x, y:   s32;                // Screen position of the image's top-left corner.
    image:  Image;
    opaque: [] bool;            // Per pixel: drawn by a line.
}

delt_free :: (delt: *Delt) {
    image_free(*delt.image);
    array_free(delt.opaque);
    delt.* = .{};
}

delt_parse :: (data: [] u8) -> Delt, bool {
    delt: Delt;
    ok := parse_delt(*delt, data);
    if !ok delt_free(*delt);
    return delt, ok;
}

Anim :: struct {
    frames: [..] Delt;
}

anim_free :: (anim: *Anim) {
    for * anim.frames delt_free(it);
    array_free(anim.frames);
    anim.* = .{};
}

// A count, then each DELT with its size before it.
anim_parse :: (data: [] u8) -> Anim, bool {
    anim: Anim;
    if data.count < 2 return anim, false;
    count := get_s16(data, 0);
    at := 2;
    for 0..count-1 {
        if at + 4 > data.count { anim_free(*anim); return anim, false; }
        size: s64 = get_s32(data, at);
        at += 4;
        if size < 0 || at + size > data.count { anim_free(*anim); return anim, false; }
        delt, ok := delt_parse(array_view(data, at, size));
        if !ok { anim_free(*anim); return anim, false; }
        array_add(*anim.frames, delt);
        at += size;
    }
    return anim, count >= 0;
}

// FONT: the first character, the character count, the bitmap row width in bits (8 or 16), the
// height, two unknown words; then each character's advance width, then each character's rows,
// top to bottom, most significant bit leftmost.
Lfd_Font :: struct {
    first:  s32;
    height: s32;
    widths: [..] u8;
    rows:   [..] u16;           // height rows per character, the leftmost pixel in bit 15.
}

lfd_font_free :: (font: *Lfd_Font) {
    array_free(font.widths);
    array_free(font.rows);
    font.* = .{};
}

lfd_font_parse :: (data: [] u8) -> Lfd_Font, bool {
    font: Lfd_Font;
    if data.count < 12 return font, false;
    font.first  = get_s16(data, 0);
    count      := get_s16(data, 2);
    bits       := get_s16(data, 4);
    font.height = get_s16(data, 6);
    row_bytes  := (bits + 7) / 8;
    if count < 0 || font.height < 0 || row_bytes < 1 || row_bytes > 2 return font, false;
    if 12 + count + count * font.height * row_bytes > data.count return font, false;

    for 0..count-1  array_add(*font.widths, data[12 + it]);
    at := 12 + count;
    for 0..count * font.height - 1 {
        row: u16 = (cast(u16) data[at]) << 8;
        if row_bytes == 2  row |= data[at + 1];
        array_add(*font.rows, row);
        at += row_bytes;
    }
    return font, true;
}

#scope_file

// A header with the bounding rectangle (left, top, right, bottom, inclusive), then lines: a
// word whose bit 0 says the line is run-length coded and whose other bits count its pixels,
// then the line's x and y, in the same space as the rectangle. A zero word ends the list.
// Coded lines are a series of runs: a byte whose bit 0 is clear copies the next (byte >> 1)
// bytes; set, it repeats the next byte (byte >> 1) times.
parse_delt :: (delt: *Delt, data: [] u8) -> bool {
    if data.count < 8 return false;
    left   := get_s16(data, 0);
    top    := get_s16(data, 2);
    right  := get_s16(data, 4);
    bottom := get_s16(data, 6);
    // CURSORS.ANIM in STANDARD.LFD has an empty frame whose rectangle is inside out.
    width  := max(right - left + 1, 0);
    height := max(bottom - top + 1, 0);
    if width > 4096 || height > 4096 return false;

    delt.x = left;
    delt.y = top;
    delt.image.width  = width;
    delt.image.height = height;
    delt.image.pixels = NewArray(width * height, u8);
    delt.opaque       = NewArray(width * height, bool);

    at := 8;
    while true {
        if at + 2 > data.count return false;
        header := get_u16(data, at);
        if header == 0 break;
        if at + 6 > data.count return false;
        x := get_s16(data, at + 2) - left;
        y := get_s16(data, at + 4) - top;
        at += 6;
        count := header >> 1;

        if !(header & 1) {
            if at + count > data.count return false;
            for 0..count-1  put_pixel(delt, x + it, y, data[at + it]);
            at += count;
            x += count;
            continue;
        }
        while count > 0 {
            if at >= data.count return false;
            code := data[at];
            run: s32 = code >> 1;
            at += 1;
            if code & 1 {
                if at >= data.count return false;
                for 0..run-1  put_pixel(delt, x + it, y, data[at]);
                at += 1;
            } else {
                if at + run > data.count return false;
                for 0..run-1  put_pixel(delt, x + it, y, data[at + it]);
                at += run;
            }
            x += run;
            count -= run;
        }
    }
    return true;
}

// Lines past the rectangle are clipped; the game draws them unclipped.
put_pixel :: (delt: *Delt, x: s32, y: s32, value: u8) {
    if x < 0 || y < 0 || x >= delt.image.width || y >= delt.image.height return;
    i := y * delt.image.width + x;
    delt.image.pixels[i] = value;
    delt.opaque[i] = true;
}

get_u16 :: (data: [] u8, at: s64) -> s32 {
    return (cast(s32) data[at]) | ((cast(s32) data[at + 1]) << 8);
}

get_s16 :: (data: [] u8, at: s64) -> s32 {
    return cast(s32) cast,trunc(s16) get_u16(data, at);
}

get_s32 :: (data: [] u8, at: s64) -> s32 {
    v := (cast(u32) data[at]) | ((cast(u32) data[at + 1]) << 8) | ((cast(u32) data[at + 2]) << 16) | ((cast(u32) data[at + 3]) << 24);
    return cast,no_check(s32) v;
}

#import "Basic";
#import "engine/dfImage";
