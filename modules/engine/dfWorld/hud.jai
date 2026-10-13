// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The status display and the message line, as DARK.EXE draws them over the 3D view.
//
// Two panels, STATUSLF.BM at the left (lives, health, shields) and STATUSRT.BM at the right
// (the headlamp, ammo), stand at the bottom of the 320x200 screen and slide away and back
// through four heights (0x1ad7b). The numbers are drawn in the HUD's fonts. The bars aren't
// art: the panels paint them in palette entries 24 to 31, which the game sets from the
// shields, health and battery each frame (dark green to green, red, the battery's five pips).
// Index 0 of the panels shows the view through.
//
// Messages come from TEXT.MSG by number: one shows at a time, in GLOWING.FNT at the top
// left, for 8 seconds at priority 0 or 1 and 3 at the others; a message replaces the one
// shown only if its priority is as high or higher, which lower numbers are (0x1b874).

// The message shown, for tests.
world_get_hud_message :: () -> string { return world.hud.message; }

#scope_module

Hud :: struct {
    loaded: bool;
    left, right, light_on, light_off: Gpu_Image;
    fonts: [Hud_Font.COUNT] Hud_Text_Font;
    messages: Msg_File;

    // The panels' place in the slide table, and where they're going (0 shown, 3 hidden).
    left_row, left_target: s32;
    right_row, right_target: s32;

    // Palette entries 24 to 31 as the HUD sets them, 6-bit DAC values. The original's
    // starts as all ones; what it never writes stays so.
    colors: [24] u8;
    battery_shown: s32 = -1;

    // The message shown.
    message: string;
    message_until: s32;
    message_priority: s32 = 9;
}

Hud_Font :: enum u8 { AMMO; SUPERCHARGED; ARMOR; HEALTH; GLOWING; COUNT; }

Hud_Text_Font :: struct {
    font: Font;
    glyphs: [..] Gpu_Image;
}

load_hud :: () {
    h := *world.hud;
    h.* = .{};
    for * h.colors  it.* = 1;
    h.left      = load_hud_image("STATUSLF.BM");
    h.right     = load_hud_image("STATUSRT.BM");
    h.light_on  = load_hud_image("LIGHTON.BM");
    h.light_off = load_hud_image("LIGHTOFF.BM");
    FONT_NAMES :: string.["AMONUM.FNT", "SUPERWEP.FNT", "ARMNUM.FNT", "HELNUM.FNT", "GLOWING.FNT"];
    for name, i: FONT_NAMES {
        data, found := gob_find(name);
        if !found continue;
        font, ok := fnt_parse(data);
        if !ok continue;
        f := *h.fonts[i];
        f.font = font;
        for font.glyphs  array_add(*f.glyphs, render_upload_image(it));
    }
    data, found := gob_find("TEXT.MSG");
    if found {
        messages, ok := msg_parse(cast(string) data);
        if ok  h.messages = messages;
        else log_error("Couldn't read TEXT.MSG.");
    }
    h.loaded = true;
}

unload_hud :: () {
    h := *world.hud;
    render_release_image(*h.left);
    render_release_image(*h.right);
    render_release_image(*h.light_on);
    render_release_image(*h.light_off);
    for * f: h.fonts {
        for * f.glyphs  render_release_image(it);
        array_free(f.glyphs);
        font_free(*f.font);
    }
    msg_free(*h.messages);
    h.* = .{};
}

// Shows a TEXT.MSG message if its priority allows (0x1b874).
send_message :: (id: s32) {
    h := *world.hud;
    message := msg_find(*h.messages, id);
    if !message || message.priority > h.message_priority || !message.text return;
    h.message = message.text;
    h.message_until = world.clock.tick + ifx message.priority < 2 then cast(s32) 1165 else 436;
    h.message_priority = message.priority;
}

// Once a frame (0x1ad7b, 0x1bb43): the bar colors, the panels' slide, the message's time.
update_hud :: () {
    h := *world.hud;
    a := *agent;

    // The battery's five pips, a step of 20 percent each, the last lit by what's left over
    // (the original also writes a sixth, past the end of the table, into its record of the
    // shields shown; that only makes it redraw them).
    percent := (a.battery * 100 / 2 + 0x8000) >> 16;
    if percent != h.battery_shown {
        h.battery_shown = percent;
        left := percent;
        for pip: 0..4 {
            green := (pip + 3) * 3 + 1;
            if left < 21 {
                h.colors[green] = cast(u8) (8 + ((left * 5) >> 1));
                left = 0;
            } else {
                h.colors[green] = 58;
                left -= 20;
            }
        }
    }

    // Shields: the outer arc (24) for what's over 100, the inner (25) up to 100, both bright
    // under the super shield. Health: 26, red to orange.
    if world.player_state.invincible == -1 {
        h.colors[0], h.colors[1] = 55, 55;
        h.colors[3], h.colors[4] = 55, 55;
    } else {
        h.colors[0] = 0;
        h.colors[1] = cast(u8) (8 + ((max(a.shields, 100) - 100) >> 1));
        h.colors[3] = 0;
        h.colors[4] = cast(u8) (8 + (min(a.shields, 100) >> 1));
    }
    health := min(a.health, 100);
    h.colors[6] = cast(u8) (8 + (health >> 1));
    h.colors[7] = cast(u8) ((health * 63) / 400);

    slide :: (row: *s32, target: s32) {
        if row.* > target       row.* -= 1;
        else if row.* < target  row.* += 1;
    }
    slide(*h.right_row, h.right_target);
    slide(*h.left_row, h.left_target);

    if h.message && h.message_until < world.clock.tick {
        h.message = "";
        h.message_priority = 9;
    }
}

// Shows or hides the panels (0x1ac1f, 0x1acd7).
show_hud :: (show: bool) {
    h := *world.hud;
    target: s32 = ifx show then 0 else 3;
    h.left_target, h.right_target = target, target;
}

// The palette with the HUD's colors in entries 24 to 31.
apply_hud_colors :: (palette: *Palette) {
    h := *world.hud;
    for 0..7 {
        palette.colors[24 + it] = .{expand_6_bit(h.colors[it * 3]), expand_6_bit(h.colors[it * 3 + 1]), expand_6_bit(h.colors[it * 3 + 2])};
    }
}

// Draws the panels and the message over the view, in 320x200 pixels (0x4eb80, 0x1bb43);
// screen_left and screen_right are where the view's edges are in them (0 and 320 in the
// original's view, beyond them on a wider one), which the panels and the message keep to.
draw_hud :: (screen_left := 0.0, screen_right := 320.0) {
    h := *world.hud;
    if !h.loaded return;
    a := *agent;
    s := *world.player_state;

    left_x := screen_left;
    left_y := SLIDE_ROWS[h.left_row];
    if h.left.texture {
        draw_hud_image(*h.left, left_x, left_y);
        draw_hud_text(.HEALTH, left_x + 52, left_y + 26, tprint("%", a.lives % 10));
        shields := ifx s.invincible == -1 then "200" else tprint("%", formatInt(a.shields, minimum_digits = 3));
        draw_hud_text(.ARMOR, left_x + 15, left_y + 26, shields);
        draw_hud_text(.HEALTH, left_x + 33, left_y + 26, tprint("%", formatInt(a.health, minimum_digits = 3)));
    }

    // The original's 260 of 320 columns: as far in from the right edge as there.
    right_x := screen_right - 60;
    right_y := SLIDE_ROWS[h.right_row];
    if h.right.texture {
        draw_hud_image(*h.right, right_x, right_y);
        lamp := ifx s.headlamp then *h.light_on else *h.light_off;
        draw_hud_image(lamp, right_x + 19, right_y);
        // The weapon's ammo; none for the fists.
        weapon := *world.weapon.weapons[world.weapon.current];
        primary := ifx weapon.ammo >= 0 then tprint("%", formatInt(a.ammo[weapon.ammo], minimum_digits = 3)) else ":::";
        draw_hud_text(.AMMO, right_x + 12, right_y + 21, primary);
        secondary := ifx weapon.secondary_ammo >= 0 then tprint("%", formatInt(a.ammo[weapon.secondary_ammo], minimum_digits = 2)) else "::";
        draw_hud_text(.ARMOR, right_x + 25, right_y + 12, secondary);
    }

    if h.message  draw_hud_text(.GLOWING, screen_left + 4, 10, h.message);
}

#scope_file

SLIDE_ROWS :: s32.[160, 170, 185, 200];

load_hud_image :: (name: string) -> Gpu_Image {
    image: Gpu_Image;
    data, found := gob_find(name);
    if !found return image;
    texture, ok := bm_parse(data);
    defer texture_free(*texture);
    if !ok || !texture.frames return image;
    return render_upload_image(texture.frames[0]);
}

draw_hud_image :: (image: *Gpu_Image, x: float, y: s32) {
    if !image.texture return;
    render_set_image(image);
    render_add_quad(.{x, xx y, 0}, .{x + image.width, xx (y + image.height), 0},
                    .{0, 0}, .{xx image.width, xx image.height}, 31, 0, render_pack_color(.TEXTURE_RAW, transparent = true));
}

// Text as the original's font blitter lays it out (0x4ea10): each glyph its width and the
// font's spacing along, a space the font's space width, a line break down by the height and
// gap; characters the font lacks take no room.
draw_hud_text :: (which: Hud_Font, x: float, y: s32, text: string) {
    f := *world.hud.fonts[which];
    font := *f.font;
    if !f.glyphs return;
    cx, cy := x, y;
    for 0..text.count-1 {
        c := text[it];
        if c == #char "\n" {
            cy += font.line_gap + font.height;
            cx = x;
            continue;
        }
        if is_space(c) {
            cx += font.space_width;
            continue;
        }
        if c < font.first || c >= font.first + f.glyphs.count continue;
        glyph := *f.glyphs[c - font.first];
        draw_hud_image(glyph, cx, cy);
        cx += glyph.width + font.spacing;
    }
}

is_space :: (c: u8) -> bool {
    return c == #char " " || c == #char "\t" || c == #char "\r" || c == 0x0B || c == 0x0C;
}
