// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Menu screens as the original's Landru draws them (DARK.EXE's view loop 0xb380b): the
// agent menu with the mission list (agent_menu.jai), the mission briefing (briefing.jai),
// the Esc menu with its dialogs (esc_menu.jai) and the PDA (pda.jai).
//
// A menu is an ANIM from an LFD: one frame its background, pairs of frames its buttons (up
// and pressed), in a PLTT. Each menu frame polls the input, lets the buttons act, draws what
// changed into a 320x200 canvas of palette indices, and shows it with the mouse cursor over
// it; then it waits out the Landru frame delay. Drawing is by invalidation: the background
// is drawn once, and a button only when it changes, over whatever was there.
//
// The caller passes the time, the keys (Landru's codes: the character, or the scan code
// times 256 for keys without one) and the mouse at 320x200, shows menu_get_video through
// menu_get_palette, and reads the result once the menu has one.

MENU_NO_RESULT :: -1;

KEY_ENTER  :: 13;
KEY_ESCAPE :: 27;
KEY_UP     :: 0x4800;
KEY_DOWN   :: 0x5000;
KEY_PAGE_UP   :: 0x4900;
KEY_PAGE_DOWN :: 0x5100;
KEY_LEFT   :: 0x4b00;
KEY_RIGHT  :: 0x4d00;
KEY_DELETE :: 0x5300;
KEY_BACKSPACE :: 8;
KEY_TAB    :: 9;

// Reads what every menu uses: HOTKEYS.MSG, which the buttons take their keys from; the
// font, MENU.LFD's font8 (0x9c3b7); and from DARK.EXE the colors text is drawn in, matched to
// each menu's palette (0xf95b4).
menu_init :: (dark_dir: string) -> bool {
    text, found := gob_find("HOTKEYS.MSG");
    if !found return false;
    file, ok := msg_parse(cast(string) text);
    if !ok return false;
    msg_free(*hotkeys);
    hotkeys = file;

    archive, opened := archive_open(tprint("%/LFD/MENU.LFD", dark_dir));
    if opened {
        entry := archive_find(archive, "FONT8.FONT");
        if entry  font = lfd_font_parse(entry.data);
        archive_close(archive);
    }
    image, mapped := dark_exe_map(dark_dir);
    if mapped {
        for * reference_colors  it.* = .{lx_read_u8(image, ADDRESS_REFERENCE_COLORS + it_index * 3), lx_read_u8(image, ADDRESS_REFERENCE_COLORS + it_index * 3 + 1), lx_read_u8(image, ADDRESS_REFERENCE_COLORS + it_index * 3 + 2)};
    }
    return font.widths.count > 0 && mapped;
}

menu_shutdown :: () {
    menu_close();
    array_free(menu.keys);
    none: [..] s32;
    menu.keys = none;
    msg_free(*hotkeys);
    lfd_font_free(*font);
}

// A key pressed, for the next menu frame; key repeats come as more presses.
menu_press_key :: (code: s32) {
    array_add(*menu.keys, code);
}

// The mouse, each host frame: where it is on the 320x200 screen and whether a button is
// down. Presses between menu frames count, however short.
menu_move_mouse :: (x: s32, y: s32, down: bool) {
    menu.mouse_x = clamp(x, 0, MENU_WIDTH - 1);
    menu.mouse_y = clamp(y, 0, MENU_HEIGHT - 1);
    if down {
        menu.mouse_down_since_frame = true;
        menu.press_x, menu.press_y = menu.mouse_x, menu.mouse_y;
    }
}

menu_is_open :: () -> bool { return menu.open; }

menu_close :: () {
    if menu.dialog.open  close_menu_dialog();
    if menu.screen.close  menu.screen.close();
    if menu.archive  archive_close(menu.archive);
    anim_free(*menu.anim);
    delt_free(*menu.cursor);
    array_free(menu.buttons);
    // The mouse stays where it was, and keys not yet read wait in the buffer, as in the
    // original between menus.
    x, y, keys := menu.mouse_x, menu.mouse_y, menu.keys;
    menu = .{};
    menu.mouse_x, menu.mouse_y, menu.keys = x, y, keys;
}

// Runs the menu's frames up to now (nanoseconds); its result once it has one, MENU_NO_RESULT
// till then.
menu_update :: (now: u64) -> s32 {
    while menu.open {
        if !menu.started {
            menu.started = true;
            menu.next_ns = now;
        }
        if now < menu.next_ns break;
        menu.now_ns = now;
        // The loop's test comes first: the frame a result is set in is still drawn and shown.
        if menu.result != MENU_NO_RESULT {
            // A screen may go on to another (the Esc menu's dialogs).
            if menu.screen.on_result && menu.screen.on_result(menu.result) continue;
            return menu.result;
        }
        if !menu.first_ns  menu.first_ns = now;
        run_frame();
        // The wait (0xc8519) spins on the game's clock, counted twice a tick, until the delay
        // has passed, and drops the rest.
        ticks := (menu.frame_delay + 1) / 2;
        menu.next_ns += cast(u64) (ticks * 1_000_000_000.0 / GAME_TICKS_PER_SECOND);
        if now > menu.next_ns + 250_000_000  menu.next_ns = now;
    }
    return MENU_NO_RESULT;
}

// The canvas with the cursor over it: palette indices, 320 x 200, top row first; covered
// says where something is drawn, for a menu over the game.
menu_get_video :: () -> [] u8, [] bool {
    memcpy(menu.video.data, menu.canvas.data, menu.canvas.count);
    memcpy(menu.video_covered.data, menu.covered.data, menu.covered.count);
    if menu.cursor.image.pixels {
        c := *menu.cursor;
        // The cursor's hot spot is its top-left; it is cut to 16 by 16, index 0 see-through.
        for y: 0..min(c.image.height, 16)-1  for x: 0..min(c.image.width, 16)-1 {
            if !c.opaque[y * c.image.width + x] continue;
            v := c.image.pixels[y * c.image.width + x];
            if v == 0 continue;
            sx, sy := menu.mouse_x + c.x + x, menu.mouse_y + c.y + y;
            if sx < 0 || sy < 0 || sx >= MENU_WIDTH || sy >= MENU_HEIGHT continue;
            menu.video[sy * MENU_WIDTH + sx] = v;
            menu.video_covered[sy * MENU_WIDTH + sx] = true;
        }
    }
    return menu.video, menu.video_covered;
}

menu_get_palette :: () -> Palette { return menu.palette; }

MENU_WIDTH  :: 320;    // The screen, as mode 13h.
MENU_HEIGHT :: 200;

#scope_module

GAME_TICKS_PER_SECOND :: 1193182.0 / 8192.0;

// Rectangles as Landru's: right and bottom exclusive.
Rect :: struct { left, top, right, bottom: s32; }

is_inside :: (r: Rect, x: s32, y: s32) -> bool {
    return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
}

Button_Kind :: enum u8 {
    PUSH;               // Acts on a release over it.
    REPEAT;             // Also acts every frame from the fourth it's held (0xb2f7a).
    RADIO;              // One of a group, the chosen one drawn pressed.
}

Button :: struct {
    id: s32;
    up, down: s32;              // ANIM frames.
    kind: Button_Kind;
    hotkey: string;             // From HOTKEYS.MSG: characters, <NNN> for a code.
    enabled := true;
    pressed: bool;
    flash: s32;                 // A hotkey's press shows for one frame (0xb2d3c): 1, 2, 0.
    invalid := true;
    held_frames: s32;
}

// What a menu does when a button acts, and what it draws besides its buttons.
Menu_Screen :: struct {
    on_button: (id: s32);
    on_key: (code: s32) -> bool;        // Before the buttons; true when taken.
    on_press: (x: s32, y: s32);         // A mouse press on no button.
    on_frame: (frame: s32);             // Every frame, after the input (the objects' callbacks).
    draw: ();                           // Its own drawing, after the background.
    close: ();
    on_result: (result: s32) -> bool;   // True when it has opened another menu in its place.
}

// A dialog over a menu (0xb4b21): its own ANIM from the menu's LFD, background and buttons;
// the menu stands still under it, and what it covered comes back when it closes.
Dialog :: struct {
    open: bool;
    anim: Anim;
    result: s32;                        // 1 for a yes, -1 for a no, 0 while open.
    saved_buttons: [..] Button;
    saved_screen: Menu_Screen;
    saved_background: s32;
    saved_canvas: [MENU_WIDTH * MENU_HEIGHT] u8;
    saved_covered: [MENU_WIDTH * MENU_HEIGHT] bool;
}

menu: struct {
    open: bool;
    started: bool;
    archive: *Archive;
    anim: Anim;
    palette: Palette;
    cursor: Delt;
    background: s32 = -1;              // The ANIM frame, or -1 when the screen draws its own.
    buttons: [..] Button;
    screen: Menu_Screen;
    result: s32 = MENU_NO_RESULT;
    frame_delay: s32 = 20;
    next_ns: u64;
    now_ns, first_ns: u64;
    frame: s32;                        // Frames since it opened.
    refresh := true;                   // The first frame draws everything.
    remap: [REFERENCE_COLORS] u8;      // The text colors in this palette (0xb26e6).
    dialog: Dialog;

    canvas: [MENU_WIDTH * MENU_HEIGHT] u8;
    covered: [MENU_WIDTH * MENU_HEIGHT] bool;
    video: [MENU_WIDTH * MENU_HEIGHT] u8;
    video_covered: [MENU_WIDTH * MENU_HEIGHT] bool;

    keys: [..] s32;
    mouse_x, mouse_y: s32;
    mouse_down_since_frame: bool;
    press_x, press_y: s32;
    mouse_was_down: bool;
    captured: *Button;
};

hotkeys: Msg_File;
font: Lfd_Font;

REFERENCE_COLORS :: 37;
ADDRESS_REFERENCE_COLORS :: 0xf95b4;
reference_colors: [REFERENCE_COLORS] struct { r, g, b: u8; };

// Opens an LFD's ANIM and PLTT as a menu (0xa1196); frame_delay in Landru ticks.
open_menu :: (lfd: string, anim: string, pltt: string, frame_delay: s32) -> bool {
    menu_close();
    dark, _ := find_dark_data_dir();
    archive, ok := archive_open(tprint("%/LFD/%", dark, to_upper_copy(lfd,, temp)));
    if !ok return false;
    menu.archive = archive;
    data := find_resource(anim, "ANIM");
    parsed, anim_ok := anim_parse(data);
    if !anim_ok { menu_close(); return false; }
    menu.anim = parsed;
    // PLTT values are 8 bits, cut to the DAC's 6.
    palette_data := find_resource(pltt, "PLTT");
    if palette_data.count >= 2 {
        first, last := cast(s32) palette_data[0], cast(s32) palette_data[1];
        for i: first..last {
            at := 2 + (i - first) * 3;
            if at + 2 >= palette_data.count break;
            menu.palette.colors[i] = .{expand_6_bit(palette_data[at] >> 2), expand_6_bit(palette_data[at + 1] >> 2), expand_6_bit(palette_data[at + 2] >> 2)};
        }
    }
    cursor_data := find_resource("cursor", "DELT");
    if cursor_data  menu.cursor = delt_parse(cursor_data);
    match_colors();
    menu.frame_delay = frame_delay;
    menu.open = true;
    return true;
}


to_upper_copy :: (s: string) -> string {
    result := copy_string(s);
    to_upper_in_place(result);
    return result;
}

find_resource :: (name: string, type: string) -> [] u8 {
    entry := archive_find(menu.archive, tprint("%.%", to_upper_copy(name,, temp), type));
    if !entry return .[];
    return entry.data;
}

// A button from its id, frames and kind; its keys from HOTKEYS.MSG by its id (0xb3446).
add_button :: (id: s32, up: s32, down: s32, kind := Button_Kind.PUSH) -> *Button {
    b := array_add(*menu.buttons);
    b.id, b.up, b.down, b.kind = id, up, down, kind;
    b.hotkey = msg_get_text(*hotkeys, id);
    return b;
}

find_button :: (id: s32) -> *Button {
    for * menu.buttons  if it.id == id return it;
    return null;
}

// The ANIM drawn from: the dialog's while one is up.
get_anim :: () -> *Anim { return ifx menu.dialog.open then *menu.dialog.anim else *menu.anim; }

// The rectangle a frame covers; a button's is its up frame's (0xa9fef).
get_frame_rect :: (frame: s32) -> Rect {
    anim := get_anim();
    if frame < 0 || frame >= anim.frames.count return .{};
    d := *anim.frames[frame];
    return .{d.x, d.y, d.x + d.image.width, d.y + d.image.height};
}

draw_frame :: (frame: s32, clip := Rect.{0, 0, MENU_WIDTH, MENU_HEIGHT}, dx: s32 = 0, dy: s32 = 0) {
    anim := get_anim();
    if frame < 0 || frame >= anim.frames.count return;
    draw_delt(*anim.frames[frame], dx, dy, clip);
}

fill_rect :: (r: Rect, color: u8) {
    for y: max(r.top, 0)..min(r.bottom, MENU_HEIGHT)-1  for x: max(r.left, 0)..min(r.right, MENU_WIDTH)-1 {
        menu.canvas[y * MENU_WIDTH + x] = color;
        menu.covered[y * MENU_WIDTH + x] = true;
    }
}

// Text in the font, its pen at the top-left of the first character (0xd0b38): each set bit
// of a row in the color, clear bits left alone, the whole byte drawn even past the
// character's width; each character then advances its width and one more. Codes 1 and 2 pick
// the normal and the highlight color (0x33); 0 ends it.
draw_text :: (text: string, x: s32, y: s32, color: u8, clip: Rect) {
    pen := x;
    c := color;
    for byte: cast([] u8) text {
        if byte == 0 break;
        if byte == 1 { c = color; continue; }
        if byte == 2 { c = 0x33; continue; }
        i := cast(s32) byte - font.first;
        if i < 0 || i >= font.widths.count continue;
        width: s32 = font.widths[i];
        if !width continue;
        bits := ((width + 7) / 8) * 8;
        for row: 0..font.height-1 {
            sy := y + row;
            if sy < clip.top || sy >= clip.bottom continue;
            line := font.rows[i * font.height + row];
            for b: 0..min(bits, 16)-1 {
                if !(line & (0x8000 >> b)) continue;
                sx := pen + b;
                if sx < clip.left || sx >= clip.right continue;
                menu.canvas[sy * MENU_WIDTH + sx] = c;
                menu.covered[sy * MENU_WIDTH + sx] = true;
            }
        }
        pen += width + FONT_SPACING;
    }
}

// The widths and one between each two (0xb8993).
get_text_width :: (text: string) -> s32 {
    total, count: s32;
    for byte: cast([] u8) text {
        if byte == 0 break;
        i := cast(s32) byte - font.first;
        if byte < 3 || i < 0 || i >= font.widths.count continue;
        total += font.widths[i];
        count += 1;
    }
    return total + max(count - 1, 0);
}

FONT_SPACING :: 1;

// Landru's clock: 1193182 / 4096 ticks a second since the menu opened.
get_landru_ticks :: () -> s64 {
    return cast(s64) ((menu.now_ns - menu.first_ns) * (1193182.0 / 4096.0) / 1_000_000_000.0);
}

// A dialog over the menu, from the LFD's ANIM; its background frame drawn at its place.
open_menu_dialog :: (anim: string, background: s32) -> bool {
    d := *menu.dialog;
    parsed, ok := anim_parse(find_resource(anim, "ANIM"));
    if !ok return false;
    d.anim = parsed;
    d.saved_buttons = menu.buttons;
    d.saved_screen = menu.screen;
    d.saved_background = menu.background;
    memcpy(d.saved_canvas.data, menu.canvas.data, menu.canvas.count);
    memcpy(d.saved_covered.data, menu.covered.data, menu.covered.count);
    none: [..] Button;
    menu.buttons = none;
    menu.screen = .{};
    menu.background = background;
    menu.captured = null;
    menu.refresh = true;
    d.result = 0;
    d.open = true;
    return true;
}

// Back to the menu as it was under the dialog.
close_menu_dialog :: () {
    d := *menu.dialog;
    if !d.open return;
    if menu.screen.close  menu.screen.close();
    array_free(menu.buttons);
    anim_free(*d.anim);
    menu.buttons = d.saved_buttons;
    menu.screen = d.saved_screen;
    menu.background = d.saved_background;
    memcpy(menu.canvas.data, d.saved_canvas.data, menu.canvas.count);
    memcpy(menu.covered.data, d.saved_covered.data, menu.covered.count);
    menu.captured = null;
    d.open = false;
}

draw_delt :: (d: *Delt, x: s32, y: s32, clip: Rect) {
    for row: 0..d.image.height-1 {
        sy := d.y + y + row;
        if sy < clip.top || sy >= clip.bottom continue;
        for col: 0..d.image.width-1 {
            sx := d.x + x + col;
            if sx < clip.left || sx >= clip.right continue;
            i := row * d.image.width + col;
            if !d.opaque[i] continue;
            menu.canvas[sy * MENU_WIDTH + sx] = d.image.pixels[i];
            menu.covered[sy * MENU_WIDTH + sx] = true;
        }
    }
}

// The radio group's choice: the chosen button stays drawn pressed (0xa57b1).
choose_radio :: (id: s32) {
    for * menu.buttons {
        if it.kind != .RADIO continue;
        chosen := it.id == id;
        if it.pressed != chosen  it.invalid = true;
        it.pressed = chosen;
    }
}

// The key buffer emptied, as the briefing does after a scroll key.
flush_keys :: () { array_reset(*menu.keys); }

get_radio_choice :: () -> s32 {
    for menu.buttons  if it.kind == .RADIO && it.pressed return it.id;
    return -1;
}

// A hotkey press: the button acts and shows pressed at once (0xb2d3c). A button that opens
// a dialog shows it when the dialog is gone, as the original's runs within the press.
press_by_key :: (b: *Button) {
    had_dialog := menu.dialog.open;
    act(b);
    if !(menu.dialog.open && !had_dialog)  draw_button(b, true);
    b.flash = 1;
    b.invalid = true;
}

#scope_file

run_frame :: () {
    read_input();
    if menu.screen.on_frame  menu.screen.on_frame(menu.frame);
    draw();
    menu.refresh = false;
    menu.frame += 1;
}

// Each of the 37 colors as the nearest of the palette's, by the sum of the squares of the
// 6-bit differences; the first of equals, and the color's own number when none is nearer
// than 0xfff (0xb26e6).
match_colors :: () {
    for ref, n: reference_colors {
        r, g, b := cast(s32) (ref.r >> 2), cast(s32) (ref.g >> 2), cast(s32) (ref.b >> 2);
        best, best_index: s32 = 0xfff, xx n;
        for menu.palette.colors {
            dr, dg, db := r - (it.r >> 2), g - (it.g >> 2), b - (it.b >> 2);
            d := (dr * dr + dg * dg + db * db) & 0xFFFF;
            if d < best { best = d; best_index = xx it_index; }
        }
        menu.remap[n] = cast(u8) best_index;
    }
}

// One key a frame, and only with no mouse button down or just let go (0xa010f); then the
// mouse.
read_input :: () {
    down := menu.mouse_down_since_frame;
    menu.mouse_down_since_frame = false;
    x, y := menu.mouse_x, menu.mouse_y;
    if down  x, y = menu.press_x, menu.press_y;

    if !down && !menu.mouse_was_down && menu.keys {
        key := menu.keys[0];
        array_ordered_remove_by_index(*menu.keys, 0);
        handle_key(key);
    }

    if down && !menu.mouse_was_down       press_mouse(x, y);
    else if down && menu.mouse_was_down   hold_mouse(x, y);
    else if !down && menu.mouse_was_down  release_mouse(x, y);
    menu.mouse_was_down = down;
}

handle_key :: (code: s32) {
    if menu.screen.on_key && menu.screen.on_key(code) return;
    for * b: menu.buttons {
        if !b.enabled || !matches_hotkey(b.hotkey, code) continue;
        press_by_key(b);
        return;
    }
}

// Characters as themselves, <NNN> for a code; case counts (0xb2de5).
matches_hotkey :: (hotkey: string, code: s32) -> bool {
    s := hotkey;
    while s {
        c: s32 = s[0];
        advance(*s);
        if c == #char "<" {
            n: s32;
            while s && s[0] != #char ">" {
                if s[0] >= #char "0" && s[0] <= #char "9"  n = n * 10 + (s[0] - #char "0");
                advance(*s);
            }
            if s  advance(*s);
            c = n;
        }
        if c == code return true;
    }
    return false;
}

act :: (b: *Button) {
    if b.kind == .RADIO  choose_radio(b.id);
    if menu.screen.on_button  menu.screen.on_button(b.id);
}

// A press goes to the button under it, which then gets the mouse until it's let go; a press
// on anything else (the briefing's text takes it) stays with nothing.
press_mouse :: (x: s32, y: s32) {
    menu.captured = null;
    for < * b: menu.buttons {
        if !b.enabled || !is_inside(get_frame_rect(b.up), x, y) continue;
        menu.captured = b;
        set_pressed(b, true);
        b.held_frames = 0;
        return;
    }
    if menu.screen.on_press  menu.screen.on_press(x, y);
}

hold_mouse :: (x: s32, y: s32) {
    b := menu.captured;
    if !b return;
    set_pressed(b, is_inside(get_frame_rect(b.up), x, y));
    if b.kind == .REPEAT {
        b.held_frames += 1;
        if b.held_frames >= 4  act(b);
    }
}

release_mouse :: (x: s32, y: s32) {
    b := menu.captured;
    menu.captured = null;
    if !b return;
    inside := is_inside(get_frame_rect(b.up), x, y);
    // A radio button keeps its choice drawn; pressed and dragged off, it shows up until
    // chosen again, as in the original.
    set_pressed(b, false);
    if inside  act(b);
}

set_pressed :: (b: *Button, pressed: bool) {
    if b.pressed == pressed return;
    b.pressed = pressed;
    b.invalid = true;
}

draw :: () {
    if menu.refresh && menu.background >= 0  draw_frame(menu.background);
    if menu.screen.draw  menu.screen.draw();
    for * b: menu.buttons {
        if !b.enabled continue;
        if !(menu.refresh || b.invalid || b.flash) continue;
        draw_button(b, b.pressed || b.flash == 1);
        if b.flash == 1       b.flash = 2;
        else if b.flash == 2  b.flash = 0;
        b.invalid = false;
    }
}

// Over what's there: the background isn't drawn again under it.
draw_button :: (b: *Button, pressed: bool) {
    draw_frame(ifx pressed then b.down else b.up);
}

#load "agent_menu.jai";
#load "briefing.jai";
#load "esc_menu.jai";
#load "pda.jai";

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/dfLandru";
#import "engine/dfMessage";
