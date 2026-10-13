// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The PDA in a mission (DARK.EXE 0x19f88, 0x936e0): MENU.LFD's pda ANIM, a display in the
// middle and five pages chosen by the buttons under it: the map, the weapons and the items
// the agent has, the mission's goals with the secrets found, and the briefing's text. The
// map has buttons to pan, zoom and change layer; the briefing, to scroll. What it shows
// comes from DFBRIEF.LFD, read every time it opens: the level's goals ANIM and briefing
// DELT, the guns and items ANIMs.
//
// The caller fades the game out first and back in after (0x199e6, 0x19a6d), as for the
// Esc menu, and passes what the level knows: see Pda_Source.

Pda_Source :: struct {
    level: string;                                  // JEDI.LVL's name.
    is_goal_done: (goal: s32) -> bool;
    secrets_percent: s32;
    // The guns frames shown: the pistol, rifle, detonators, repeater, fusion cutter, mines,
    // mortar, concussion rifle, assault cannon (0x2f880).
    weapons: [9] bool;
    // The items frames shown (0x2f940): the keys, goggles, cleats, mask, plans, phrik,
    // nava card, datatape, an unused slot, the DT weapon, codes 1 to 5.
    items: [17] bool;
    draw_map: (pixels: [] u8, width: s32, height: s32);
    send_map_message: (message: s32);
}

// The map's messages the PDA sends (see dfWorld's Automap_Message).
PDA_MAP_CENTER     :: 1;
PDA_MAP_ALL_LAYERS :: 12;

// The result, once the PDA is left, is 0.
menu_open_pda :: (source: Pda_Source, frame_delay: s32) -> bool {
    pda = .{source = source};
    source.send_map_message(PDA_MAP_CENTER);
    if !open_menu("menu.lfd", "pda", "menu", frame_delay) return false;

    dark, _ := find_dark_data_dir();
    archive, ok := archive_open(tprint("%/LFD/DFBRIEF.LFD", dark));
    if !ok { menu_close(); return false; }
    defer archive_close(archive);
    name := to_upper_copy(source.level,, temp);
    load_anim :: (archive: *Archive, name: string) -> Anim {
        entry := archive_find(archive, tprint("%.ANIM", name));
        if !entry return .{};
        anim, _ := anim_parse(entry.data);
        return anim;
    }
    pda.goals = load_anim(archive, name);
    pda.guns  = load_anim(archive, "GUNS");
    pda.items = load_anim(archive, "ITEMS");
    entry := archive_find(archive, tprint("%.DELT", name));
    if entry  pda.text = delt_parse(entry.data);

    menu.background = 0;
    pda.display = get_frame_rect(1);
    // The scroll's limit counts from the display's 156 rows; then up to a whole 12 lines, a
    // whole 12 more when it already is one.
    if pda.text.image.height {
        limit := pda.text.image.height - 156;
        limit = limit + 12 - limit % 12;
        pda.limit = max(limit, 0);
    }
    for 0..4  add_button(xx it, xx (3 + 2 * it), xx (2 + 2 * it), .RADIO);
    add_button(BUTTON_EXIT, 13, 12);
    for 0..7  add_button(xx (6 + it), xx (15 + 2 * it), xx (14 + 2 * it), .REPEAT);
    choose_radio(PAGE_MAP);
    set_page(PAGE_MAP);
    menu.screen = .{on_button = on_pda_button, on_key = on_pda_key, draw = draw_pda, close = close_pda};
    return true;
}

// The shift keys, held or not: Space goes back a page with them.
menu_set_shift_held :: (held: bool) { pda.shift_held = held; }

KEY_F1      :: 0x3b00;
KEY_ALT_TAB :: 0xa500;

#scope_file

PAGE_MAP       :: 0;
PAGE_WEAPONS   :: 1;
PAGE_INVENTORY :: 2;
PAGE_GOALS     :: 3;
PAGE_BRIEFING  :: 4;
PAGES          :s32: 5;

BUTTON_EXIT       :: 5;
BUTTON_UP         :: 6;     // The map's pan buttons, and the briefing's scroll.
BUTTON_RIGHT      :: 7;
BUTTON_DOWN       :: 8;
BUTTON_LEFT       :: 9;
BUTTON_ZOOM_OUT   :: 10;
BUTTON_ZOOM_IN    :: 11;
BUTTON_LAYER_UP   :: 12;
BUTTON_LAYER_DOWN :: 13;

// The map's picture and where it goes on the screen (0x93f58).
MAP_WIDTH  :: 290;
MAP_HEIGHT :: 156;
MAP_X      :: 15;
MAP_Y      :: 12;

pda: struct {
    source: Pda_Source;
    goals, guns, items: Anim;
    text: Delt;
    display: Rect;
    scroll, limit: s32;
    page: s32;
    display_invalid := true;
    shift_held: bool;
    map: [MAP_WIDTH * MAP_HEIGHT] u8;
};

// A page chosen (0x93e5b): the map's buttons only on the map, the briefing's arrows only on
// the briefing; the whole screen drawn again.
set_page :: (page: s32) {
    pda.page = page;
    for * menu.buttons {
        if it.id < BUTTON_UP continue;
        if page == PAGE_MAP           it.enabled = true;
        else if page == PAGE_BRIEFING it.enabled = it.id == BUTTON_UP || it.id == BUTTON_DOWN;
        else                          it.enabled = false;
    }
    pda.display_invalid = true;
    menu.refresh = true;
}

// The buttons (0x93930): a page, Exit, the map's messages, the briefing's scroll.
on_pda_button :: (id: s32) {
    if id < PAGES {
        set_page(id);
        return;
    }
    if id == BUTTON_EXIT {
        menu.result = 0;
        return;
    }
    if pda.page == PAGE_MAP {
        MESSAGES :: s32.[2, 5, 3, 4, 7, 6, 8, 9];   // By button, from BUTTON_UP.
        pda.source.send_map_message(MESSAGES[id - BUTTON_UP]);
        pda.display_invalid = true;
    } else if pda.page == PAGE_BRIEFING {
        if id == BUTTON_UP    pda.scroll = max(pda.scroll - 12, 0);
        if id == BUTTON_DOWN  pda.scroll = min(pda.scroll + 12, pda.limit);
        pda.display_invalid = true;
    }
}

// The keys (0x93b77): each presses the button it stands for, as a hotkey does, so a key for
// a button not on this page does nothing.
on_pda_key :: (code: s32) -> bool {
    press :: (id: s32) {
        b := find_button(id);
        if b && b.enabled  press_by_key(b);
    }
    if code == KEY_ESCAPE || code == KEY_F1 { press(BUTTON_EXIT); return true; }
    if code == #char " " {
        step: s32 = ifx pda.shift_held then PAGES - 1 else 1;
        press((pda.page + step) % PAGES);
        return true;
    }
    if pda.page == PAGE_BRIEFING {
        if code == {
            case KEY_UP;    press(BUTTON_UP);
            case KEY_DOWN;  press(BUTTON_DOWN);
            case KEY_PAGE_UP;
                pda.scroll = max(pda.scroll - 120, 0);
                pda.display_invalid = true;
            case KEY_PAGE_DOWN;
                pda.scroll = min(pda.scroll + 120, pda.limit);
                pda.display_invalid = true;
            case; return false;
        }
        return true;
    }
    if pda.page == PAGE_MAP {
        if code == {
            case #char "+"; #through;
            case #char "=";  press(BUTTON_ZOOM_IN);
            case #char "-"; #through;
            case #char "_";  press(BUTTON_ZOOM_OUT);
            case #char "]";  press(BUTTON_LAYER_UP);
            case #char "[";  press(BUTTON_LAYER_DOWN);
            case KEY_UP;     press(BUTTON_UP);
            case KEY_LEFT;   press(BUTTON_LEFT);
            case KEY_RIGHT;  press(BUTTON_RIGHT);
            case KEY_DOWN;   press(BUTTON_DOWN);
            case KEY_ALT_TAB;
                pda.source.send_map_message(PDA_MAP_ALL_LAYERS);
                pda.display_invalid = true;
                menu.refresh = true;
            case; return false;
        }
        return true;
    }
    return false;
}

// The display (0xa1054, 0x93fd1): cleared to the darkest color, the page drawn, the
// display's frame over it.
draw_pda :: () {
    if !(menu.refresh || pda.display_invalid) return;
    pda.display_invalid = false;
    d := pda.display;
    fill_rect(d, menu.remap[0]);
    if pda.page == {
        case PAGE_MAP;
            pda.source.draw_map(pda.map, MAP_WIDTH, MAP_HEIGHT);
            for y: 0..MAP_HEIGHT-1  for x: 0..MAP_WIDTH-1 {
                sx, sy := MAP_X + x, MAP_Y + y;
                menu.canvas[sy * MENU_WIDTH + sx] = pda.map[y * MAP_WIDTH + x];
                menu.covered[sy * MENU_WIDTH + sx] = true;
            }
            for id: BUTTON_UP..BUTTON_LAYER_DOWN  draw_pda_button(xx id);
        case PAGE_WEAPONS;
            // The tenth frame asks for a weapon past the last, which the original's query
            // doesn't know: it answers with a register left over from the frames before,
            // the last frame drawn's number, or the darkest color's when none was.
            last: s32 = -1;
            for 0..pda.guns.frames.count-1 {
                shown := false;
                if it < pda.source.weapons.count  shown = pda.source.weapons[it];
                else  shown = ifx last >= 0 then last != 0 else menu.remap[0] != 0;
                if !shown continue;
                draw_delt(*pda.guns.frames[it], 0, 0, d);
                last = xx it;
            }
        case PAGE_INVENTORY;
            for 0..pda.items.frames.count-1 {
                if it < pda.source.items.count && pda.source.items[it]  draw_delt(*pda.items.frames[it], 0, 0, d);
            }
        case PAGE_GOALS;
            draw_goals();
        case PAGE_BRIEFING;
            t := *pda.text;
            if t.image.pixels {
                // Centered across the display as its right is counted, its last column.
                x := d.left + (((d.right - 1) - d.left - t.image.width) >> 1) - t.x;
                y := d.top - t.y - pda.scroll;
                draw_delt(t, x, y, d);
            }
            draw_pda_button(BUTTON_UP);
            draw_pda_button(BUTTON_DOWN);
    }
    draw_frame(1);
}

// The level's goals ANIM: its first frame always, then a frame over it for each goal done;
// the secrets found, shadowed (0x93fd1).
draw_goals :: () {
    if !pda.goals.frames return;
    d := pda.display;
    draw_delt(*pda.goals.frames[0], 0, 0, d);
    for goal: 0..pda.goals.frames.count-2 {
        if pda.source.is_goal_done(xx goal)  draw_delt(*pda.goals.frames[goal + 1], 0, 0, d);
    }
    draw_frame(30);
    draw_frame(31);
    r := get_frame_rect(31);
    n := pda.source.secrets_percent;
    // "%2d%%"
    text := join(ifx n >= 0 && n < 10 then " " else "", tprint("%", n), "%",, temp);
    screen := Rect.{0, 0, MENU_WIDTH, MENU_HEIGHT};
    draw_text(text, r.left + 1, r.top, 91, screen);
    draw_text(text, r.left, r.top + 1, 91, screen);
    draw_text(text, r.left, r.top, 19, screen);
}

draw_pda_button :: (id: s32) {
    b := find_button(id);
    if !b || !b.enabled return;
    draw_frame(ifx b.pressed then b.down else b.up);
}

close_pda :: () {
    anim_free(*pda.goals);
    anim_free(*pda.guns);
    anim_free(*pda.items);
    delt_free(*pda.text);
}
