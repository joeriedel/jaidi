// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Landru's 320x200 canvas and its DELT blitter. Pixels are palette indices; actors draw into
// the canvas, and fades copy it to the video buffer, which is what's shown.
//
// Drawing goes through commands, the original's own operations in its order: clear, draw a
// DELT, draw the crawl, copy a rectangle to video. The CPU runs each at once into the canvas
// and video buffers; the GPU presenter (gpu.jai) records the same ones and replays them in its
// own images, so the two can be compared pixel for pixel.

CANVAS_WIDTH  :: 320;
CANVAS_HEIGHT :: 200;

// Left and top inclusive, right and bottom exclusive.
Rect :: struct {
    left, top, right, bottom: s32;
}

CANVAS_RECT :: Rect.{0, 0, CANVAS_WIDTH, CANVAS_HEIGHT};

is_empty :: (r: Rect) -> bool {
    return r.left >= r.right || r.top >= r.bottom;
}

get_intersection :: (a: Rect, b: Rect) -> Rect {
    return .{max(a.left, b.left), max(a.top, b.top), min(a.right, b.right), min(a.bottom, b.bottom)};
}

// Draws a DELT's lines at (x, y) plus their own coordinates, within 'clip'. With 'flip', lines
// run leftwards from 'mirror' minus their x. A DELT is its rectangle (left, top, right,
// bottom, inclusive) then lines: a word whose bit 0 marks a run-length coded line and whose
// other bits count its pixels, the line's x and y, then its bytes; a zero word ends the list.
// Coded lines are runs: a byte with bit 0 clear copies the next (byte >> 1) bytes, set
// repeats the next byte (byte >> 1) times. The data is trusted: check it with is_valid_delt.
// 'clip' must lie within the canvas, rows 'width' wide; 'drawn', when given, marks the pixels
// drawn.
draw_delt :: (canvas: [] u8, delt: [] u8, x: s32, y: s32, clip: Rect, flip := false, mirror: s32 = 0, width: s32 = CANVAS_WIDTH, drawn: [] bool = .[]) {
    at := 8;
    while true {
        header := get_u16(delt, at);
        if header == 0 break;
        line_x := get_s16(delt, at + 2);
        cy := get_s16(delt, at + 4) + y;
        at += 6;
        cx := ifx flip then mirror - line_x + x else line_x + x;
        step: s32 = ifx flip then cast(s32) -1 else 1;
        visible := cy >= clip.top && cy < clip.bottom;
        row := cy * width;
        count := cast(s32) (header >> 1);

        put :: (value: u8) #expand {
            if visible && cx >= clip.left && cx < clip.right {
                canvas[row + cx] = value;
                if drawn  drawn[row + cx] = true;
            }
            cx += step;
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

// The DELT's rectangle: left, top, right and bottom, inclusive.
get_delt_bounds :: (delt: [] u8) -> left: s32, top: s32, right: s32, bottom: s32 {
    return get_s16(delt, 0), get_s16(delt, 2), get_s16(delt, 4), get_s16(delt, 6);
}

// Walks the lines the way draw_delt does, checking every read against the data.
is_valid_delt :: (delt: [] u8) -> bool {
    if delt.count < 8 return false;
    at := 8;
    while true {
        if at + 2 > delt.count return false;
        header := get_u16(delt, at);
        if header == 0 return true;
        if at + 6 > delt.count return false;
        at += 6;
        count := cast(s32) (header >> 1);
        if !(header & 1) {
            at += count;
            if at > delt.count return false;
            continue;
        }
        while count > 0 {
            if at >= delt.count return false;
            code := delt[at];
            run := cast(s32) (code >> 1);
            if !run return false;   // Would never finish the line.
            at += ifx code & 1 then 2 else 1 + run;
            if at > delt.count return false;
            count -= run;
        }
    }
    return true;
}

#scope_module

Draw_Kind :: enum u8 {
    CLEAR_CANVAS;   // To index.
    CLEAR_VIDEO;    // To index.
    DELT;           // delt at (x, y) within clip; flipped about mirror.
    CRAWL;          // The text crawl at crawl_offset.
    COPY;           // The canvas inside source to the video buffer at (x, y).
}

Draw_Command :: struct {
    kind:   Draw_Kind;
    index:  u8;
    delt:   [] u8;
    x, y:   s32;
    clip:   Rect;
    flip:   bool;
    mirror: s32;
    source: Rect;
    crawl_offset: s32;
    // For the GPU presenter's in-betweens: whose drawing this is, its fractions of a pixel,
    // and whether it moved by POS this cell.
    actor:  *Actor;
    x_fract, y_fract: s32;
    jumped: bool;
}

emit :: (c: Draw_Command) {
    run_command(c);
    record_gpu_command(c);
}

emit_clear_canvas :: () { emit(.{kind = .CLEAR_CANVAS}); }
emit_clear_video  :: () { emit(.{kind = .CLEAR_VIDEO}); }

emit_copy :: (source: Rect, x: s32, y: s32) {
    emit(.{kind = .COPY, source = source, x = x, y = y});
}

// The CPU executor.
run_command :: (c: Draw_Command) {
    if c.kind == {
        case .CLEAR_CANVAS; memset(cut.canvas.data, c.index, cut.canvas.count);
        case .CLEAR_VIDEO;  memset(cut.video.data, c.index, cut.video.count);
        case .DELT;         draw_delt(cut.canvas, c.delt, c.x, c.y, c.clip, c.flip, c.mirror);
        case .CRAWL;        draw_crawl_rows(*cut.crawl, cut.canvas, c.crawl_offset);
        case .COPY;         copy_to_video(c.source, c.x, c.y);
    }
}

// Copies the canvas inside 'source' to the video buffer with its top-left corner at (x, y),
// clipped on both sides.
copy_to_video :: (source: Rect, x: s32, y: s32) {
    s, d := get_copy_rects(source, x, y);
    if is_empty(d) return;
    for row: 0..d.bottom-d.top-1 {
        memcpy(cut.video.data + (d.top + row) * CANVAS_WIDTH + d.left, cut.canvas.data + (s.top + row) * CANVAS_WIDTH + s.left, d.right - d.left);
    }
}

// The rectangles a copy reads and writes, both inside the canvas, or empty.
get_copy_rects :: (source: Rect, x: s32, y: s32) -> from: Rect, to: Rect {
    s := get_intersection(source, CANVAS_RECT);
    if is_empty(s) return .{}, .{};
    d := Rect.{s.left + x - source.left, s.top + y - source.top, 0, 0};
    d.right  = d.left + (s.right - s.left);
    d.bottom = d.top + (s.bottom - s.top);
    c := get_intersection(d, CANVAS_RECT);
    if is_empty(c) return .{}, .{};
    from := Rect.{s.left + (c.left - d.left), s.top + (c.top - d.top), 0, 0};
    from.right  = from.left + (c.right - c.left);
    from.bottom = from.top + (c.bottom - c.top);
    return from, c;
}

// The extent of a DELT's lines, which may reach past its rectangle: left and top inclusive,
// right and bottom exclusive. Empty for a DELT without lines.
get_delt_extent :: (delt: [] u8) -> Rect {
    r := Rect.{S32_MAX, S32_MAX, S32_MIN, S32_MIN};
    at := 8;
    while true {
        header := get_u16(delt, at);
        if header == 0 break;
        x := get_s16(delt, at + 2);
        y := get_s16(delt, at + 4);
        count := cast(s32) (header >> 1);
        at += 6;
        if header & 1 {
            // The last run may go past the count; the blitter draws all of it.
            drawn: s32;
            while drawn < count {
                code := delt[at];
                run := cast(s32) (code >> 1);
                at += ifx code & 1 then 2 else 1 + run;
                drawn += run;
            }
            count = drawn;
        } else {
            at += count;
        }
        if !count continue;
        r.left   = min(r.left, x);
        r.top    = min(r.top, y);
        r.right  = max(r.right, x + count);
        r.bottom = max(r.bottom, y + 1);
    }
    if r.left > r.right return .{};
    return r;
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
