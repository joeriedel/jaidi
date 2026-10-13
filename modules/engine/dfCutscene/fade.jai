// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The blit and its fades. Landru keeps three palettes besides the one on screen: the source
// and destination of a palette change, and a working copy that fade steps build into before
// it goes to the DAC. A screen fade picks which part of the canvas reaches the video buffer
// at each step; a color fade moves the palette from source to destination, through the fade
// color (black) or not.
//
// A blit runs passes from its first frame to its last (just one without a held fade). Each
// pass steps the color fade, puts the working palette on screen if it changed (waiting for a
// retrace), then copies to video.

Fade_Type :: enum s16 {
    NONE        :: 0;
    SNAP        :: 1;
    SHORT_SNAP  :: 2;
    LONG_SNAP   :: 3;
    SLIDE_LEFT  :: 4;  SLIDE_RIGHT  :: 5;  SLIDE_UP  :: 6;  SLIDE_DOWN  :: 7;
    SLIDE_TOP_LEFT :: 8;  SLIDE_TOP_RIGHT :: 9;  SLIDE_BOTTOM_LEFT :: 10;  SLIDE_BOTTOM_RIGHT :: 11;
    WIPE_LEFT   :: 12; WIPE_RIGHT   :: 13; WIPE_UP   :: 14; WIPE_DOWN   :: 15;
    WIPE_TOP_LEFT  :: 16; WIPE_TOP_RIGHT  :: 17; WIPE_BOTTOM_LEFT  :: 18; WIPE_BOTTOM_RIGHT  :: 19;
    HORIZONTAL_CENTER :: 20;
    VERTICAL_CENTER   :: 21;
    CENTER            :: 22;
    THIN_SLICE :: 23;  SLICE :: 24;  THICK_SLICE :: 25;
}

Color_Fade :: enum s16 {
    NONE      :: 0;
    SNAP      :: 1;     // Switch to the new palette halfway through.
    MONO      :: 2;     // To the fade color, then to the new palette.
    TO_MONO   :: 3;     // To the fade color.
    FROM_MONO :: 4;     // From the fade color to the new palette.
    PALETTE   :: 5;     // From the old palette to the new.
}

Fade_State :: struct {
    // The film's request, started once the cell's records have run.
    film_type:  Fade_Type;
    film_color: Color_Fade;

    type:   Fade_Type;
    step, length: s32;
    locked: bool;

    color:  Color_Fade;
    color_step, color_length: s32;
    color_locked: bool;

    // The blit: frames first to last, the one at hand, and whether its palette is waiting
    // for the retrace.
    first, last, at: s32;
    palette_waiting: bool;
}

#scope_module

set_film_fade :: (type: Fade_Type, color: Color_Fade) {
    cut.fade.film_type  = type;
    cut.fade.film_color = color;
}

// Whether a screen fade still holds the palette. Snap types don't count.
is_fade_active :: () -> bool {
    return cut.fade.type > .LONG_SNAP;
}

// After a cell's records: a palette they changed goes on screen through the film's fade if it
// asked for one, or else a one-step snap.
resolve_palette :: () {
    f := *cut.fade;
    changed := memcmp(cut.palette.source.data, cut.palette.dest.data, size_of(type_of(cut.palette.dest))) != 0;
    has_film_fade := f.film_type != .NONE || f.film_color != .NONE;
    if changed {
        if has_film_fade              start_film_fade(true);
        else if !is_fade_active()     start_color_fade(.SNAP, true, 1, true);
        else                          cut.palette.screen = cut.palette.dest;
    } else if has_film_fade {
        start_film_fade(false);
    }
}

// The fade a key's skip ends a scene with: to black and back up over the cleared canvas.
start_cleanup_fade :: () {
    start_fade(.SHORT_SNAP, .MONO, false, true);
    start_blit();
}

start_blit :: () {
    note_gpu_blit();
    f := *cut.fade;
    f.first = cut.time;
    f.last  = cut.time;
    if f.type != .NONE && f.locked  f.last = cut.time + f.length;
    f.at = f.first;
    f.palette_waiting = false;
}

is_blit_done :: () -> bool {
    return cut.fade.at > cut.fade.last;
}

// One pass. Returns false when it must wait for the retrace first; call again then.
run_blit_pass :: () -> bool {
    f := *cut.fade;
    time := f.at;
    if !f.palette_waiting {
        cut.palette.working = cut.palette.screen;
        step_color_fade(time);
        if memcmp(cut.palette.working.data, cut.palette.screen.data, size_of(type_of(cut.palette.screen))) != 0 {
            f.palette_waiting = true;
            return false;
        }
    } else {
        cut.palette.screen = cut.palette.working;
        f.palette_waiting = false;
    }

    if f.type != .NONE && (time == f.first || f.locked) {
        copy_fade(f.type, f.step, f.length, time != f.last);
        f.step += 1;
        if f.step > f.length  f.type = .NONE;
    } else {
        emit_copy(CANVAS_RECT, 0, 0);
    }
    f.at += 1;
    return true;
}

#scope_file

start_film_fade :: (palette_changed: bool) {
    f := *cut.fade;
    locked := !(f.film_color == .PALETTE && f.film_type <= .LONG_SNAP);
    start_fade(f.film_type, f.film_color, palette_changed, locked);
    f.film_type  = .NONE;
    f.film_color = .NONE;
}

start_fade :: (type: Fade_Type, color: Color_Fade, palette_changed: bool, locked: bool) {
    f := *cut.fade;
    f.type   = type;
    f.length = get_fade_length(type);
    f.step   = 0;
    f.locked = locked;
    start_color_fade(color, palette_changed, f.length, locked);
}

start_color_fade :: (type: Color_Fade, palette_changed: bool, length: s32, locked: bool) {
    if type == .NONE return;
    f := *cut.fade;
    f.color = type;
    cut.palette.source = cut.palette.screen;
    if !palette_changed  cut.palette.dest = cut.palette.screen;
    f.color_length = length;
    f.color_step   = 0;
    f.color_locked = locked;
}

// Types past the last named one (LOGO's film asks for 26 and 27) take the long length.
get_fade_length :: (type: Fade_Type) -> s32 {
    if type == {
        case .SNAP;       return 1;
        case .SHORT_SNAP; return 16;
    }
    return 32;
}

// Builds this step's palette into the working copy.
step_color_fade :: (time: s32) {
    f := *cut.fade;
    if f.color == .NONE || !(time == f.first || f.color_locked) return;
    step := f.color_step;
    length := f.color_length;
    middle := length >> 1;
    if f.color == {
      case .SNAP;
        if step == middle  cut.palette.working = cut.palette.dest;
      case .MONO;
        if step < middle  blend_to_black((step << 8) / middle);
        else              blend_from_black((step - middle) * 256 / (length - middle));
      case .TO_MONO;
        blend_to_black((step << 8) / length);
      case .FROM_MONO;
        blend_from_black((step << 8) / length);
      case .PALETTE;
        fraction := (step << 8) / length;
        for i: 0..255 {
            from, to := cut.palette.source[i], cut.palette.dest[i];
            cut.palette.working[i] = .{blend(from.r, to.r, fraction), blend(from.g, to.g, fraction), blend(from.b, to.b, fraction)};
        }
    }
    f.color_step += 1;
    if f.color_step > f.color_length  f.color = .NONE;
}

blend_to_black :: (fraction: s32) {
    for i: 0..255 {
        from := cut.palette.source[i];
        cut.palette.working[i] = .{blend(from.r, 0, fraction), blend(from.g, 0, fraction), blend(from.b, 0, fraction)};
    }
}

blend_from_black :: (fraction: s32) {
    for i: 0..255 {
        to := cut.palette.dest[i];
        cut.palette.working[i] = .{blend(0, to.r, fraction), blend(0, to.g, fraction), blend(0, to.b, fraction)};
    }
}

blend :: (from: u8, to: u8, fraction: s32) -> u8 {
    d := (cast(s32) to - cast(s32) from) * fraction / 256;
    return cast,trunc(u8) (from + d);
}

// Copies the part of the canvas a screen fade shows at this step. Snap fades that hold copy
// only halfway through; the slices draw nothing.
copy_fade :: (type: Fade_Type, step: s32, length: s32, holding: bool) {
    frame := CANVAS_RECT;
    r := frame;
    x, y := frame.left, frame.top;
    w := frame.right - frame.left;
    h := frame.bottom - frame.top;
    grow_w := w * step / length;
    grow_h := h * step / length;
    back := length - step;
    if type == {
      case .SHORT_SNAP; #through;
      case .LONG_SNAP;
        if step != length >> 1 && holding  return;
      case .SLIDE_LEFT;   r.left = frame.right - grow_w;
      case .SLIDE_RIGHT;  r.right = frame.left + grow_w;  x = frame.right - (r.right - r.left);
      case .SLIDE_UP;     r.bottom = frame.top + grow_h;  y = frame.bottom - (r.bottom - r.top);
      case .SLIDE_DOWN;   r.top = frame.bottom - grow_h;
      case .SLIDE_TOP_LEFT;
        r.top = frame.bottom - grow_h;  r.right = frame.left + grow_w;  x = frame.right - (r.right - r.left);
      case .SLIDE_TOP_RIGHT;
        r.top = frame.bottom - grow_h;  r.left = frame.right - grow_w;
      case .SLIDE_BOTTOM_LEFT;
        r.bottom = frame.top + grow_h;  r.right = frame.left + grow_w;
        x = frame.right - (r.right - r.left);  y = frame.bottom - (r.bottom - r.top);
      case .SLIDE_BOTTOM_RIGHT;
        r.bottom = frame.top + grow_h;  r.left = frame.right - grow_w;  y = frame.bottom - (r.bottom - r.top);
      case .WIPE_LEFT;    r.right = frame.left + grow_w;
      case .WIPE_RIGHT;   r.left = frame.right - grow_w;  x = r.left;
      case .WIPE_UP;      r.top = frame.bottom - grow_h;  y = r.top;
      case .WIPE_DOWN;    r.bottom = frame.top + grow_h;
      case .WIPE_TOP_LEFT;
        r.top = frame.bottom - grow_h;  r.right = frame.left + grow_w;  y = r.top;
      case .WIPE_TOP_RIGHT;
        r.top = frame.bottom - grow_h;  r.left = frame.right - grow_w;  x = r.left;  y = r.top;
      case .WIPE_BOTTOM_LEFT;
        r.bottom = frame.top + grow_h;  r.right = frame.left + grow_w;
      case .WIPE_BOTTOM_RIGHT;
        r.bottom = frame.top + grow_h;  r.left = frame.right - grow_w;  x = r.left;
      case .VERTICAL_CENTER;
        v := ((h >> 1) * back) / length;
        r.top = frame.top + v;  r.bottom = frame.bottom - v;  y = r.top;
      case .HORIZONTAL_CENTER;
        v := ((w >> 1) * back) / length;
        r.left = frame.left + v;  r.right = frame.right - v;  x = r.left;
      case .CENTER;
        v := ((h >> 1) * back) / length;
        r.top = frame.top + v;  r.bottom = frame.bottom - v;  y = r.top;
        v = ((w >> 1) * back) / length;
        r.left = frame.left + v;  r.right = frame.right - v;  x = r.left;
      case .THIN_SLICE; #through;
      case .SLICE; #through;
      case .THICK_SLICE;
        return;
    }
    if is_empty(r) return;
    emit_copy(r, x, y);
}

#import "Basic";
