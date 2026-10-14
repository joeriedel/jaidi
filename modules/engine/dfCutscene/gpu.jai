// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The GPU presenter. It shows a cutscene one of two ways.
//
// Exact: it replays the draw commands (draw.jai) in a canvas and a video image of its own,
// through the renderer's film operations and its uber-shader, and resolves the video image
// through the screen palette. This matches the CPU's video buffer pixel for pixel;
// `--cutscene-diff` checks that.
//
// Smooth (Enhanced): it draws each display frame itself, in linear color, at the size it is
// shown. The player computes the next frame's canvas right after showing one, then waits; the
// presenter keeps the drawing of the frame on screen and of the one waiting, and moves each
// actor between the two by the time passed, fractions of a pixel included. Actors a POS moved
// don't move between frames, nor do they across scenes. The art is drawn from colors baked
// through the palette it's shown in, one bake per palette. A color fade draws the picture
// through its source palette, its destination, or both, and the output blends them by the
// time since the fade started, in gamma space as the original's DAC fades went, with an
// ordered dither. A held snap fade (the original keeps the old picture up until halfway, then
// puts the new one up at once) draws the drawing that was on screen before the blit until the
// CPU's fade reaches that step. While a wipe or slide runs, the exact image is shown.
// The text crawl is drawn at full resolution and filtered (the CRAWL_SMOOTH mode).
//
// Wide (Enhanced): the picture takes the window's shape, from 4:3 to 16:9. The films were
// framed for 320 pixels, so only what can honestly extend does: star-field backgrounds wrap
// around into the margins, which fills them seamlessly and moves with them; the crawl's plane
// simply goes on; actors that at some point span the screen's whole width (1E's planet once it
// has risen, the Star Wars logo at the start of its zoom) are drawn larger about the middle for
// their whole life, keeping their shape, so the screen's edges meet the view's (growing them
// only when they span made them zoom oddly as it started and stopped); everything else stays in the 4:3 area its clips keep it
// to, the margins black, as the films' own background is. A star field is told apart by
// itself, through the palette it's shown in, when its colors are first made (is_star_field),
// so cutscenes of any origin are handled with no list of names.
//
// Each DELT is decoded once at the extent of its lines, which may reach past its rectangle,
// and uploaded as indices for the exact path and as colors per palette for the smooth one.
// Textures of a scene that has ended are released once no drawing kept for the smooth path
// uses them and the frames that drew with them are on the GPU.

// Records this frame's drawing and returns the texture it fills, null when the renderer isn't
// running, and the shape to show it at (width over height). 'now' is on the clock
// cutscene_update gets. Smooth, the texture is width x height, the size it will be shown at,
// in the shape 'aspect' (4:3 for the original's framing, up to 16:9 wide); otherwise the
// screen's 320 x 200, at 4:3.
cutscene_present_gpu :: (now: u64, smooth: bool, width: s32, height: s32, aspect: float = 4.0 / 3.0) -> *SDL_GPUTexture, float {
    if !ensure_gpu() return null, 0;
    g := *cut_gpu;
    g.frame += 1;
    release_retired();
    if !smooth || !cut.scene {
        palette := cutscene_get_palette();
        render_film_resolve(*g.video, *g.output, *palette);
        return g.output.color, 4.0 / 3.0;
    }

    seconds := cast(float64) (now - cut.start_ns) / 1_000_000_000.0;
    fade := get_fade_state(seconds);
    // A wipe that fades one palette into another (none does) shows the exact image.
    if is_wiping() && fade.mode == .PALETTE {
        source, destination := widen_palette(fade.first), widen_palette(fade.second);
        render_film_resolve_fade(*g.video, *g.output, *source, *destination, fade.mode, fade.fraction, fade.dither);
        return g.output.color, 4.0 / 3.0;
    }
    size_smooth_images(max(width, CANVAS_WIDTH), max(height, CANVAS_HEIGHT));
    collect_motions();
    // In the screen's pixels: 200 down, and 320 across at 4:3, so 240 x aspect across.
    view_width := 240 * clamp(aspect, 4.0 / 3.0, 16.0 / 9.0);
    if is_wiping() {
        // The old picture, and the new one inside the wipe's rectangle over it, both through
        // the palette a fade to or from black goes through.
        palette := find_palette(ifx fade.mode == .FROM_MONO then fade.second else fade.first);
        draw_in_between(*g.smooth_second, g.previous, false, palette, seconds, view_width);
        draw_in_between(*g.smooth, g.shown, false, palette, seconds, view_width);
        wipe, shift := get_wipe_rect(seconds, view_width, g.smooth.width, g.smooth.height);
        render_film_output(*g.smooth_second, *g.smooth, *g.smooth_output, fade.mode, fade.fraction, fade.dither, sharpen = true, wiping = true, wipe = wipe, shift = shift);
        return g.smooth_output.color, view_width / 240;
    }
    // A held snap shows the old picture until its midpoint.
    old := is_holding_old_picture();
    drawings := ifx old then g.previous else g.shown;
    draw_in_between(*g.smooth, drawings, !old, find_palette(fade.first), seconds, view_width);
    second := *g.smooth;
    if fade.mode == .FROM_MONO || fade.mode == .PALETTE {
        draw_in_between(*g.smooth_second, drawings, !old, find_palette(fade.second), seconds, view_width);
        second = *g.smooth_second;
    }
    render_film_output(*g.smooth, second, *g.smooth_output, fade.mode, fade.fraction, fade.dither, sharpen = true);
    return g.smooth_output.color, view_width / 240;
}

// The GPU video image's indices plus one, read back. Call after the frame is submitted.
cutscene_read_gpu_video :: () -> [] u16 {
    if !cut_gpu.ready return .[];
    return render_read_film_image(*cut_gpu.video);
}

cutscene_release_gpu :: () {
    g := *cut_gpu;
    if !g.ready return;
    array_reset(*g.shown);
    array_reset(*g.waiting);
    array_reset(*g.previous);
    retire_gpu_textures();
    for * g.retired  release_retired_entry(it);
    array_free(g.retired);
    array_free(g.textures);
    for * g.palettes  render_release_film_palette(*it.film);
    array_free(g.palettes);
    render_release_film_image(*g.canvas);
    render_release_film_image(*g.video);
    render_release_film_image(*g.smooth);
    render_release_film_image(*g.smooth_second);
    render_release_film_output(*g.output);
    render_release_film_output(*g.smooth_output);
    g.* = .{};
}

#scope_module

record_gpu_command :: (c: Draw_Command) {
    if !ensure_gpu() return;
    g := *cut_gpu;
    if c.kind == {
      case .CLEAR_CANVAS;
        render_film_clear(*g.canvas, c.index);
        array_reset_keeping_memory(*g.waiting);
      case .CLEAR_VIDEO;
        render_film_clear(*g.video, c.index);
      case .DELT;
        texture := get_delt_texture(c.delt);
        if !texture.indexed.texture return;
        x := get_delt_left(c, texture.extent, cast(float) c.x);
        render_film_draw(*g.canvas, *texture.indexed, x, xx (c.y + texture.extent.top), c.flip, to_floats(c.clip));
        array_add(*g.waiting, .{command = c, texture = texture});
      case .CRAWL;
        upload_crawl();
        render_film_crawl(*g.canvas, *g.crawl_text, *g.crawl_rows, c.crawl_offset);
        array_add(*g.waiting, .{command = c, texture = g.crawl_colors, crawl_text = g.crawl_text, crawl_field = g.crawl_field, rows = g.crawl_rows});
      case .COPY;
        from, to := get_copy_rects(c.source, c.x, c.y);
        if is_empty(to) return;
        render_film_copy(*g.canvas, .[from.left, from.top, from.right, from.bottom], *g.video, to.left, to.top);
    }
}

// The canvas that was waiting goes on screen; a color fade starting with it starts now.
note_gpu_blit :: () {
    g := *cut_gpu;
    if !g.ready return;
    array_reset_keeping_memory(*g.previous);
    array_add(*g.previous, ..g.shown);
    array_reset_keeping_memory(*g.shown);
    array_add(*g.shown, ..g.waiting);
    array_reset_keeping_memory(*g.waiting);
    g.shown_at = cut.clock.event;
    // The color fade this picture goes up with, as it is now: the next cell's records, run
    // while this picture waits, ask for its own and may change the palettes.
    f := *cut.fade;
    g.fade = .{};
    if f.color != .NONE && f.color_length > 0 {
        g.fade = .{color = f.color, step = f.color_step, length = f.color_length, locked = f.color_locked,
                   started = cut.clock.event, source = cut.palette.source, dest = cut.palette.dest};
    }
}

// A scene ended: its DELTs go away with its LFD.
retire_gpu_textures :: () {
    g := *cut_gpu;
    for g.textures  array_add(*g.retired, .{texture = it, frame = g.frame});
    array_reset_keeping_memory(*g.textures);
    retire_crawl();
}


// A background covering the whole screen whose outer 20 columns either side are dark but for
// a few lone points: stars, which have no direction and can be repeated. Measured on the
// retail cutscenes, star fields light under 3% of those pixels, 85% or more of them alone;
// scenes (rooms, holograms, ships up close) light 7% to 97%, almost none alone.
is_star_field :: (e: Rect, pixels: [] u8, drawn: [] bool, palette: *Palette) -> bool {
    if e.left > 0 || e.top > 0 || e.right < CANVAS_WIDTH || e.bottom < CANVAS_HEIGHT return false;
    EDGE :: 20;
    width := e.right - e.left;
    is_lit :: (x: s32, y: s32) -> bool #expand {
        i := (y - e.top) * width + (x - e.left);
        if !drawn[i] return false;
        c := palette.colors[pixels[i]];
        return max(c.r, c.g, c.b) > 40;
    }
    lit, alone := 0, 0;
    for y: 0..CANVAS_HEIGHT-1 {
        for column: 0..EDGE*2-1 {
            x := ifx column < EDGE then cast(s32) column else cast(s32) (CANVAS_WIDTH - EDGE * 2 + column);
            if !is_lit(x, xx y) continue;
            lit += 1;
            neighbours := (x > 0 && is_lit(x - 1, xx y)) || (x < CANVAS_WIDTH - 1 && is_lit(x + 1, xx y)) ||
                          (y > 0 && is_lit(x, xx (y - 1))) || (y < CANVAS_HEIGHT - 1 && is_lit(x, xx (y + 1)));
            if !neighbours  alone += 1;
        }
    }
    total := EDGE * 2 * CANVAS_HEIGHT;
    return lit * 20 < total && (lit == 0 || alone * 10 > lit * 6);
}

widen_palette :: (colors: [256] Rgb) -> Palette {
    palette: Palette;
    for colors  palette.colors[it_index] = .{expand_6_bit(it.r), expand_6_bit(it.g), expand_6_bit(it.b)};
    return palette;
}

cut_gpu: struct {
    ready: bool;
    frame: int;                 // Presented frames, for knowing when textures are free.
    canvas, video: Film_Image;
    output: Film_Output;
    smooth, smooth_second: Film_Image;  // Linear color; the second for two-palette fades.
    smooth_output: Film_Output;
    textures: [..] *Delt_Texture;
    retired:  [..] Retired;
    palettes: [..] Known_Palette;
    crawl_text:   Gpu_Image;
    crawl_rows:   Film_Table;
    crawl_field:  Gpu_Image;    // The text's distance field, for drawing it smooth.
    crawl_colors: *Delt_Texture;   // The text again, for its brightest index.
    crawl_bitmap: *u8;          // Which crawl the textures hold.

    shown, waiting: [..] Drawing;   // The frame on screen; the one computed and waiting.
    previous: [..] Drawing;         // The one before shown, for snap fades holding it up.
    shown_at: float64;              // When the shown frame went up, in seconds.
    fade: struct {                  // The shown picture's color fade, if any (color NONE).
        color:   Color_Fade;
        step, length: s32;          // Where it was when the picture went up, of how many.
        locked:  bool;              // All its steps in this blit, one a retrace.
        started: float64;           // When this picture went up, in seconds.
        source, dest: [256] Rgb;
    };
};

#scope_file

// A DELT decoded at the extent of its lines (or the crawl's text): its indices and drawn
// pixels, uploaded as indices, and baked to colors through each palette it's been shown in.
Delt_Texture :: struct {
    delt:    *u8;           // The DELT's data, for finding it again while its LFD is open.
    extent:  Rect;
    pixels:  [] u8;
    drawn:   [] bool;
    indexed: Gpu_Image;
    bakes:   [..] Bake;
    brightest: u8;          // The crawl's text: its brightest index, the top of its ramp.
}

Bake :: struct {
    palette: s32;           // Index into cut_gpu.palettes.
    image:   Gpu_Image;
    stars:   bool;          // A full-screen star field: wrapped into wide margins.
}

Known_Palette :: struct {
    colors: [256] Rgb;
    film:   Film_Palette;   // For the crawl.
}

Drawing :: struct {
    command:     Draw_Command;
    texture:     *Delt_Texture;  // DELT.
    crawl_text:  Gpu_Image;      // CRAWL.
    crawl_field: Gpu_Image;
    rows:        Film_Table;
}

Retired :: struct {
    texture:     *Delt_Texture;
    crawl_text:  Gpu_Image;      // The field goes with the text.
    crawl_field: Gpu_Image;
    rows:        Film_Table;
    frame:       int;
}

// The color fade as the output applies it: through which palettes, how, how far.
Fade_State :: struct {
    first, second: [256] Rgb;
    mode: Film_Fade;
    fraction: float;
    dither: bool;
}

ensure_gpu :: () -> bool {
    g := *cut_gpu;
    if g.ready return true;
    if !render_is_ready() return false;
    g.canvas = render_create_film_image(CANVAS_WIDTH, CANVAS_HEIGHT);
    g.video  = render_create_film_image(CANVAS_WIDTH, CANVAS_HEIGHT);
    g.output = render_create_film_output(CANVAS_WIDTH, CANVAS_HEIGHT);
    g.ready  = true;
    return true;
}

// Made again when the size it's shown at changes.
size_smooth_images :: (width: s32, height: s32) {
    g := *cut_gpu;
    if g.smooth.texture && g.smooth.width == width && g.smooth.height == height return;
    render_release_film_image(*g.smooth);
    render_release_film_image(*g.smooth_second);
    render_release_film_output(*g.smooth_output);
    g.smooth        = render_create_film_image(width, height, color = true);
    g.smooth_second = render_create_film_image(width, height, color = true);
    g.smooth_output = render_create_film_output(width, height);
}

// Flipped, a line's pixel at x runs to mirror - x: the image's right edge goes left.
get_delt_left :: (c: Draw_Command, e: Rect, x: float) -> float {
    if c.flip return c.mirror + x - (e.right - 1);
    return x + e.left;
}

to_floats :: (r: Rect) -> [4] float {
    return .[xx r.left, xx r.top, xx r.right, xx r.bottom];
}

// Snap fades that hold the old image until halfway, and wipes, slides and center fades,
// which show parts of both, while their blit runs.
is_wiping :: () -> bool {
    f := *cut.fade;
    if cut.clock.phase != .BLIT || f.type == .NONE return false;
    return f.type > .LONG_SNAP && f.type <= .THICK_SLICE;
}

// Where a wipe shows the new picture, in output pixels, and how far it's moved there (slides):
// the original's rectangle (copy_fade) taken over the whole wide view, its edges at the
// screen's edges at the view's, and moved on smoothly between its steps, one a retrace.
get_wipe_rect :: (seconds: float64, view_width: float, width: s32, height: s32) -> [4] float, [2] float {
    f := *cut.fade;
    // The pass at f.step comes at the next event; the one before is on screen.
    ahead := clamp((cut.clock.event - seconds) * RETRACES_PER_SECOND, 0, 1);
    p := cast(float) clamp((f.step - ahead) / f.length, 0, 1);
    margin := (view_width - CANVAS_WIDTH) / 2;
    left, top, right, bottom := -margin, 0.0, CANVAS_WIDTH + margin, cast(float) CANVAS_HEIGHT;
    w, h := right - left, bottom - top;
    grow_w, grow_h := w * p, h * p;
    back := 1 - p;
    r := float.[left, top, right, bottom];
    x, y := left, top;
    if f.type == {
      case .SLIDE_LEFT;   r[0] = right - grow_w;
      case .SLIDE_RIGHT;  r[2] = left + grow_w;  x = right - (r[2] - r[0]);
      case .SLIDE_UP;     r[3] = top + grow_h;   y = bottom - (r[3] - r[1]);
      case .SLIDE_DOWN;   r[1] = bottom - grow_h;
      case .SLIDE_TOP_LEFT;
        r[1] = bottom - grow_h;  r[2] = left + grow_w;  x = right - (r[2] - r[0]);
      case .SLIDE_TOP_RIGHT;
        r[1] = bottom - grow_h;  r[0] = right - grow_w;
      case .SLIDE_BOTTOM_LEFT;
        r[3] = top + grow_h;  r[2] = left + grow_w;  x = right - (r[2] - r[0]);  y = bottom - (r[3] - r[1]);
      case .SLIDE_BOTTOM_RIGHT;
        r[3] = top + grow_h;  r[0] = right - grow_w;  y = bottom - (r[3] - r[1]);
      case .WIPE_LEFT;    r[2] = left + grow_w;
      case .WIPE_RIGHT;   r[0] = right - grow_w;  x = r[0];
      case .WIPE_UP;      r[1] = bottom - grow_h;  y = r[1];
      case .WIPE_DOWN;    r[3] = top + grow_h;
      case .WIPE_TOP_LEFT;
        r[1] = bottom - grow_h;  r[2] = left + grow_w;  y = r[1];
      case .WIPE_TOP_RIGHT;
        r[1] = bottom - grow_h;  r[0] = right - grow_w;  x = r[0];  y = r[1];
      case .WIPE_BOTTOM_LEFT;
        r[3] = top + grow_h;  r[2] = left + grow_w;
      case .WIPE_BOTTOM_RIGHT;
        r[3] = top + grow_h;  r[0] = right - grow_w;  x = r[0];
      case .VERTICAL_CENTER;
        v := h / 2 * back;
        r[1] = top + v;  r[3] = bottom - v;  y = r[1];
      case .HORIZONTAL_CENTER;
        v := w / 2 * back;
        r[0] = left + v;  r[2] = right - v;  x = r[0];
      case .CENTER;
        v := h / 2 * back;
        r[1] = top + v;  r[3] = bottom - v;  y = r[1];
        v = w / 2 * back;
        r[0] = left + v;  r[2] = right - v;  x = r[0];
      case;
        // The slices copy nothing: the old picture stays.
        return .[0, 0, 0, 0], .[0, 0];
    }
    // Shown at (x, y), the rectangle's picture moves by (x, y) less its corner.
    sx, sy := width / view_width, height / cast(float) CANVAS_HEIGHT;
    to_output :: (px: float, py: float) -> float, float #expand { return (px + margin) * sx, py * sy; }
    l, t := to_output(x, y);
    rr, b := to_output(x + r[2] - r[0], y + r[3] - r[1]);
    return .[l, t, rr, b], .[(x - r[0]) * sx, (y - r[1]) * sy];
}

// A held snap fade before its midpoint step, where the original copies the new picture over.
is_holding_old_picture :: () -> bool {
    f := *cut.fade;
    if cut.clock.phase != .BLIT || !f.locked return false;
    if f.type != .SHORT_SNAP && f.type != .LONG_SNAP return false;
    return f.step <= f.length >> 1;
}

// The screen palette, or a color fade's palettes and how far it has come by the time since it
// started: one step per retrace, as the original's passes go.
get_fade_state :: (seconds: float64) -> Fade_State {
    g := *cut_gpu;
    f := *g.fade;
    state: Fade_State;
    state.first = cut.palette.screen;
    state.second = cut.palette.screen;
    if f.color == .NONE return state;

    // Locked, the blit runs every step, one a retrace; otherwise one step a frame, taken as
    // the picture goes up.
    steps := ifx f.locked then (seconds - f.started) * RETRACES_PER_SECOND else cast(float64) f.step + 1;
    if f.color == .SNAP {
        // The new palette from its middle step on, the first pass's for a one-step snap (a
        // palette change with no fade of the film's): before, the new picture would show
        // through the old shot's palette until that pass's retrace.
        middle := f.length >> 1;
        switched := ifx f.locked then steps >= cast(float64) middle else f.step >= middle;
        state.first = ifx switched then f.dest else f.source;
        state.second = state.first;
        return state;
    }
    fraction := cast(float) clamp(steps / f.length, 0, 1);
    state.first  = f.source;
    state.second = f.dest;
    if f.color == {
      case .TO_MONO;    state.mode = .TO_MONO;
      case .FROM_MONO;  state.mode = .FROM_MONO;
      case .PALETTE;    state.mode = .PALETTE;
      case .MONO;
        // Down to black in the first half, up to the new palette in the second.
        if fraction < 0.5 { state.mode = .TO_MONO; fraction *= 2; }
        else              { state.mode = .FROM_MONO; fraction = fraction * 2 - 1; }
    }
    state.fraction = fraction;
    state.dither = true;
    return state;
}

find_palette :: (colors: [256] Rgb) -> s32 {
    g := *cut_gpu;
    for * g.palettes  if memcmp(it.colors.data, colors.data, size_of(type_of(colors))) == 0  return xx it_index;
    known := array_add(*g.palettes);
    known.colors = colors;
    wide := widen_palette(colors);
    known.film = render_upload_film_palette(*wide);
    return xx (g.palettes.count - 1);
}

// The shown frame's drawing, each actor moved toward where the waiting frame has it, into a
// color image through one palette. 'view_width' is in the screen's pixels: 320 for 4:3, more
// for wide, centered on the original's.
draw_in_between :: (target: *Film_Image, drawings: [] Drawing, interpolate: bool, palette: s32, seconds: float64, view_width: float) {
    g := *cut_gpu;
    t: float;
    if interpolate && cut.clock.phase == .WAIT && g.waiting && cut.clock.event > g.shown_at {
        t = cast(float) clamp((seconds - g.shown_at) / (cut.clock.event - g.shown_at), 0, 1);
    }
    // Across and down apart: the screen's pixels are taller than wide.
    scale := Vector2.{target.width / view_width, cast(float) target.height / CANVAS_HEIGHT};
    margin := (view_width - CANVAS_WIDTH) / 2;
    render_film_clear(target);

    // Star fields wrap into the wide view's margins, behind everything: only where nothing
    // the film draws reaches. The margins show the field's far edges, which don't meet what
    // they touch, so no seam shows (a mirror would put each star opposite its twin).
    if margin > 0  for * drawing: drawings {
        c := *drawing.command;
        if c.kind != .DELT continue;
        bake := get_bake(drawing.texture, palette);
        if !bake.stars continue;
        x, y, clip := get_drawn_place(drawing, ifx interpolate then find_next(c) else null, t);
        e := drawing.texture.extent;
        left := get_delt_left(c, e, x) + margin;
        top := y + e.top;
        width := cast(float) (e.right - e.left);
        whole := float.[0, clip[1], view_width, clip[3]];
        render_film_draw(target, *bake.image, left - width, top, c.flip, whole, scale);
        render_film_draw(target, *bake.image, left + width, top, c.flip, whole, scale);
    }

    for * drawing: drawings {
        c := *drawing.command;
        next := ifx interpolate then find_next(c) else null;
        if c.kind == .CRAWL {
            offset := c.crawl_offset;
            if next  offset += cast(s32) ((next.command.crawl_offset - c.crawl_offset) * t);
            // The original darkens by stepping down the text's palette ramp, from its brightest
            // index to the darkest; as a color: that many steps down from the full color.
            text := drawing.texture;
            full := widen_palette(g.palettes[palette].colors).colors[text.brightest];
            steps := cast(float) max(cast(s32) text.brightest - CRAWL_DARKEST, 1);
            ramp := Vector4.{full.r / 255.0, full.g / 255.0, full.b / 255.0, steps};
            render_film_crawl(target, *drawing.crawl_text, *drawing.rows, offset, scale, smooth = true, full = ramp, margin = margin, field = *drawing.crawl_field, field_scale = CRAWL_FIELD_SCALE);
            continue;
        }
        x, y, clip := get_drawn_place(drawing, next, t);
        bake := get_bake(drawing.texture, palette);
        colors := *bake.image;
        e := drawing.texture.extent;

        // Where the screen's pixels go in the target: (p + offset) * size. Across the wide
        // view's margin. Actors shown with one that spans the screen or has its art cut off by
        // its edge (Actor.grown) are drawn larger about the middle, the screen's edges on the
        // view's, so the cut never shows and patches stay on what they're drawn over; not star
        // fields, which wrap (told again here by the palette they're shown in). Otherwise,
        // where it's clipped only by the screen's edge, it's drawn on into the margin: its art
        // goes on past the screen's edge there (a ship crossing it, a field's next tile), and
        // the original's screen hid it. A pillarboxed film's actors keep to the screen, between
        // bars, while its star fields still wrap.
        offset := Vector2.{margin, 0};
        size := scale;
        if margin > 0 && !bake.stars && c.actor.grown {
            grow := view_width / CANVAS_WIDTH;
            offset = .{(margin + CANVAS_WIDTH / 2) / grow - CANVAS_WIDTH / 2, (CANVAS_HEIGHT / 2) / grow - CANVAS_HEIGHT / 2};
            size = .{scale.x * grow, scale.y * grow};
        } else if margin > 0 && (bake.stars || !c.actor.pillarboxed) {
            // Each side on its own: a film may wipe by moving one edge of a clip in from the
            // other (kflyby's Executor shot).
            if c.clip.left <= 0             clip[0] = -margin;
            if c.clip.right >= CANVAS_WIDTH  clip[2] = CANVAS_WIDTH + margin;
        }
        for * clip  it.* += ifx it_index % 2 == 0 then offset.x else offset.y;

        if next && t > 0 && is_tweened(drawing, next) {
            motion := get_motion(drawing.texture.delt, next.texture.delt);
            if motion && motion.fitted && !motion.held {
                // The fit is in the actor's own pixels; on the screen each frame sits at its
                // command's position. A crossfade is the same with no zoom or shift of its own.
                zoom, local_shift := 1.0, Vector2.{};
                if motion.good  zoom, local_shift = motion.zoom, motion.shift;
                n := *next.command;
                from := Vector2.{c.x + c.x_fract / 256.0, c.y + c.y_fract / 256.0};
                to   := Vector2.{n.x + n.x_fract / 256.0, n.y + n.y_fract / 256.0};
                ne := next.texture.extent;
                shift := local_shift + to - from * zoom;
                after := get_bake(next.texture, palette);
                render_film_tween(target, colors, *after.image, from + Vector2.{xx e.left, xx e.top}, to + Vector2.{xx ne.left, xx ne.top},
                                  zoom, shift, t, clip, offset, size);
                continue;
            }
        }

        left := get_delt_left(c, e, x) + offset.x;
        top := y + e.top + offset.y;
        render_film_draw(target, colors, left, top, c.flip, clip, size);
    }
}

// Where a drawing is, moved part of the way to where the waiting frame has it: its position
// and its clip, in the screen's pixels.
get_drawn_place :: (drawing: *Drawing, next: *Drawing, t: float) -> x: float, y: float, clip: [4] float {
    c := *drawing.command;
    x := c.x + c.x_fract / 256.0;
    y := c.y + c.y_fract / 256.0;
    clip := to_floats(c.clip);
    if next && !next.command.jumped && next.command.flip == c.flip {
        n := *next.command;
        x = lerp(x, n.x + n.x_fract / 256.0, t);
        y = lerp(y, n.y + n.y_fract / 256.0, t);
        next_clip := to_floats(n.clip);
        for * clip  it.* = lerp(it.*, next_clip[it_index], t);
    }
    return x, y, clip;
}

// An actor's next frame is another of its pictures, which might have moved there.
is_tweened :: (from: Drawing, to: Drawing) -> bool {
    a, b := *from.command, *to.command;
    if a.kind != .DELT || b.kind != .DELT || a.actor != b.actor || b.jumped return false;
    return from.texture != to.texture && !a.flip && !b.flip;
}

// The waiting frame's drawing by the same actor.
find_next :: (c: *Draw_Command) -> *Drawing {
    for * cut_gpu.waiting  if it.command.actor == c.actor && it.command.kind == c.kind  return it;
    return null;
}

// The DELT's colors through the palette: sRGB, premultiplied, alpha 0 where it isn't drawn.
get_bake :: (texture: *Delt_Texture, palette: s32) -> *Bake {
    for * texture.bakes  if it.palette == palette  return it;
    wide := widen_palette(cut_gpu.palettes[palette].colors);
    pixels := NewArray(texture.pixels.count, u32,, temp);
    for texture.pixels {
        if !texture.drawn[it_index] continue;
        c := wide.colors[it];
        pixels[it_index] = 0xFF000000 | ((cast(u32) c.b) << 16) | ((cast(u32) c.g) << 8) | c.r;
    }
    bake := array_add(*texture.bakes);
    bake.palette = palette;
    bake.image = render_upload_film_colors(texture.indexed.width, texture.indexed.height, pixels);
    bake.stars = is_star_field(texture.extent, texture.pixels, texture.drawn, *wide);
    return bake;
}

upload_crawl :: () {
    g := *cut_gpu;
    crawl := *cut.crawl;
    if g.crawl_bitmap == crawl.bitmap.data return;
    retire_crawl();
    text := Image.{crawl.width, crawl.height, crawl.bitmap};
    g.crawl_text = render_upload_image(text);
    rows: [CRAWL_DRAWN_ROWS] [FILM_TABLE_WIDTH] s32;
    for * rows {
        row := crawl.rows[it_index];
        it.* = .[row.offset, row.scale, row.clipped_x_start, row.first, row.last, row.fade, 0, 0];
    }
    g.crawl_rows = render_upload_film_table(rows);
    g.crawl_bitmap = crawl.bitmap.data;
    // Built on the fitting thread, queued when the cutscene started; kept there.
    values, width, height := get_crawl_field(cut.archive, crawl);
    g.crawl_field = render_upload_film_field(width, height, values);

    t := New(Delt_Texture);
    t.pixels = array_copy(crawl.bitmap);
    t.drawn  = NewArray(crawl.bitmap.count, bool);
    for crawl.bitmap {
        t.drawn[it_index] = it != 0;
        t.brightest = max(t.brightest, it);
    }
    t.indexed = g.crawl_text;   // Owned by the crawl, released with it.
    g.crawl_colors = t;
}

retire_crawl :: () {
    g := *cut_gpu;
    if g.crawl_colors  g.crawl_colors.indexed = .{};
    if g.crawl_text.texture || g.crawl_rows.texture  array_add(*g.retired, .{texture = g.crawl_colors, crawl_text = g.crawl_text, crawl_field = g.crawl_field, rows = g.crawl_rows, frame = g.frame});
    g.crawl_colors = null;
    g.crawl_text = .{};
    g.crawl_field = .{};
    g.crawl_rows = .{};
    g.crawl_bitmap = null;
}

// Once two frames have been presented since, and no kept drawing uses it.
release_retired :: () {
    g := *cut_gpu;
    i := 0;
    while i < g.retired.count {
        r := *g.retired[i];
        if g.frame - r.frame < 2 || is_in_use(r) { i += 1; continue; }
        release_retired_entry(r);
        array_unordered_remove_by_index(*g.retired, i);
    }
}

is_in_use :: (r: *Retired) -> bool {
    for cut_gpu.previous {
        if r.texture && it.texture == r.texture  return true;
        if r.crawl_text.texture && it.crawl_text.texture == r.crawl_text.texture  return true;
    }
    for cut_gpu.shown {
        if r.texture && it.texture == r.texture  return true;
        if r.crawl_text.texture && it.crawl_text.texture == r.crawl_text.texture  return true;
    }
    for cut_gpu.waiting {
        if r.texture && it.texture == r.texture  return true;
        if r.crawl_text.texture && it.crawl_text.texture == r.crawl_text.texture  return true;
    }
    return false;
}

release_retired_entry :: (r: *Retired) {
    if r.texture {
        t := r.texture;
        render_release_image(*t.indexed);
        for * t.bakes  render_release_image(*it.image);
        array_free(t.bakes);
        array_free(t.pixels);
        array_free(t.drawn);
        free(t);
    }
    render_release_image(*r.crawl_text);
    render_release_image(*r.crawl_field);
    render_release_film_table(*r.rows);
}

get_delt_texture :: (delt: [] u8) -> *Delt_Texture {
    g := *cut_gpu;
    for g.textures  if it.delt == delt.data  return it;
    t := New(Delt_Texture);
    array_add(*g.textures, t);
    t.delt = delt.data;
    t.extent = get_delt_extent(delt);
    e := t.extent;
    if is_empty(e) return t;
    width, height := e.right - e.left, e.bottom - e.top;
    t.pixels = NewArray(width * height, u8);
    t.drawn  = NewArray(width * height, bool);
    draw_delt(t.pixels, delt, -e.left, -e.top, .{0, 0, width, height}, width = width, drawn = t.drawn);
    t.indexed = render_upload_image(.{width, height, t.pixels}, t.drawn);
    return t;
}

#import "Math";
#import "engine/dfRender";
#import "engine/vendor/SDL3";
