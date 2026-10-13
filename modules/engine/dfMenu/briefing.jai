// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The mission briefing (DARK.EXE 0x1a32c, 0x946d5). BRIEFING.LST names each level's LFD,
// ANIM and PLTT; the text is a picture, the DELT named after the level, scrolled 12 lines at
// a time in the box the ANIM's second frame marks out. The buttons: OK, Cancel, the arrows,
// and the difficulty, chosen here. Music is paused while it's up.

Briefing_Entry :: struct {
    level, lfd, anim, pltt: string;     // Lower case, as the original keeps them.
}

// "BRF 1.0", "BRIEFS n", then a line per level: LEV: LFD: ANI: PAL: (0x1a54d). Lines that
// don't give all four are skipped and not counted.
briefing_list_parse :: (text: string) -> [..] Briefing_Entry, bool {
    list: [..] Briefing_Entry;
    lines := text;
    header, count := 0, -1;
    while lines {
        found, line, rest := split_from_left(lines, #char "\n");
        if !found { line = lines; rest = ""; }
        lines = rest;
        line = trim(line);
        if !line || line[0] == #char "#" continue;
        fields := split_words(line);
        if header == 0 {
            if fields.count < 2 || fields[0] != "BRF" || fields[1] != "1.0" return list, false;
            header = 1;
        } else if count < 0 {
            if fields.count < 2 || fields[0] != "BRIEFS" return list, false;
            value, ok := string_to_int(fields[1]);
            if !ok return list, false;
            count = xx value;
        } else {
            if list.count >= count break;
            if fields.count < 8 || fields[0] != "LEV:" || fields[2] != "LFD:" || fields[4] != "ANI:" || fields[6] != "PAL:" continue;
            array_add(*list, .{to_lower_copy(fields[1]), to_lower_copy(fields[3]), to_lower_copy(fields[5]), to_lower_copy(fields[7])});
        }
    }
    return list, count >= 0;
}

briefing_list_free :: (list: *[..] Briefing_Entry) {
    for list.* { free(it.level); free(it.lfd); free(it.anim); free(it.pltt); }
    array_free(list.*);
}

// Opens the level's briefing, the difficulty (0 easy to 2 hard) chosen at the start; false
// when it can't, and the mission goes ahead without one. frame_delay is Landru's, in its
// ticks. The result: 1 accepted, 0 cancelled.
menu_open_briefing :: (level: string, difficulty: s32, frame_delay: s32) -> bool {
    if !briefings.read {
        briefings.read = true;
        text, found := gob_find("BRIEFING.LST");
        if found  briefings.list = briefing_list_parse(cast(string) text);
    }
    if !briefings.list return false;
    // A level the list doesn't have gets the first one's.
    entry := *briefings.list[0];
    name := to_lower_copy(level,, temp);
    for * briefings.list  if it.level == name { entry = it; break; }

    if !open_menu(entry.lfd, entry.anim, entry.pltt, frame_delay) return false;
    menu.background = 0;
    b := *briefing;
    b.* = .{};
    b.difficulty_at_start = difficulty;
    b.box = get_frame_rect(1);
    text_data := find_resource(name, "DELT");
    if text_data  b.text = delt_parse(text_data);
    // The scroll's limit counts from a 130-line box, not the frame's; then up to a whole 12
    // lines, a whole 12 more when it already is one.
    if b.text.image.height {
        limit := b.text.image.height - 130;
        limit = limit + 12 - limit % 12;
        b.limit = max(limit, 0);
    }
    add_button(BUTTON_OK, 3, 2);
    add_button(BUTTON_UP, 5, 4, .REPEAT);
    add_button(BUTTON_DOWN, 7, 6, .REPEAT);
    add_button(BUTTON_CANCEL, 9, 8);
    add_button(BUTTON_EASY, 11, 10, .RADIO);
    add_button(BUTTON_MEDIUM, 13, 12, .RADIO);
    add_button(BUTTON_HARD, 15, 14, .RADIO);
    choose_radio(BUTTON_EASY + 10 * clamp(difficulty, 0, 2));
    menu.screen = .{on_button = on_briefing_button, on_key = on_briefing_key, draw = draw_briefing_text, close = close_briefing};
    return true;
}

// The difficulty chosen, which the original keeps even when the briefing is cancelled.
menu_get_briefing_difficulty :: () -> s32 {
    choice := get_radio_choice();
    if choice < 0 return briefing.difficulty_at_start;
    return (choice - BUTTON_EASY) / 10;
}

#scope_file

BUTTON_OK     :: 200;
BUTTON_UP     :: 210;
BUTTON_DOWN   :: 220;
BUTTON_CANCEL :: 230;
BUTTON_EASY   :: 240;
BUTTON_MEDIUM :: 250;
BUTTON_HARD   :: 260;

briefings: struct {
    read: bool;
    list: [..] Briefing_Entry;
};

briefing: struct {
    text: Delt;
    box: Rect;
    scroll: s32;
    limit: s32;
    text_invalid := true;
    difficulty_at_start: s32;
};

on_briefing_button :: (id: s32) {
    b := *briefing;
    if id == {
        case BUTTON_OK;      menu.result = 1;
        case BUTTON_CANCEL;  menu.result = 0;
        case BUTTON_UP;
            if b.scroll > 0 {
                b.scroll = max(b.scroll - 12, 0);
                b.text_invalid = true;
            }
        case BUTTON_DOWN;
            if b.scroll != b.limit {
                b.scroll = min(b.scroll + 12, b.limit);
                b.text_invalid = true;
            }
    }
}

// The arrow keys press the arrow buttons; the page keys scroll ten lines (0x949f3). Each
// empties the key buffer, so a held key steps at most once a frame.
on_briefing_key :: (code: s32) -> bool {
    b := *briefing;
    if code == {
        case KEY_UP;    press_by_key(find_button(BUTTON_UP));
        case KEY_DOWN;  press_by_key(find_button(BUTTON_DOWN));
        case KEY_PAGE_UP;
            if b.scroll > 0  b.scroll = max(b.scroll - 120, 0);
            b.text_invalid = true;
        case KEY_PAGE_DOWN;
            if b.scroll != b.limit  b.scroll = min(b.scroll + 120, b.limit);
            b.text_invalid = true;
        case;
            return false;
    }
    flush_keys();
    return true;
}

// The box (0xa1054): the background again inside it, the text centered across it, then the
// frame's own lines over it.
draw_briefing_text :: () {
    b := *briefing;
    if !(menu.refresh || b.text_invalid) return;
    b.text_invalid = false;
    draw_frame(0, b.box);
    t := *b.text;
    if t.image.pixels {
        x := b.box.left + ((b.box.right - b.box.left) - t.image.width) / 2 - t.x;
        y := b.box.top - t.y - b.scroll;
        draw_delt(t, x, y, b.box);
    }
    draw_frame(1, b.box);
}

close_briefing :: () {
    delt_free(*briefing.text);
}

split_words :: (line: string) -> [..] string {
    words: [..] string;
    words.allocator = temp;
    s := line;
    while s {
        while s && (s[0] == #char " " || s[0] == #char "\t" || s[0] == #char "\r")  advance(*s);
        if !s break;
        word := s;
        while s && s[0] != #char " " && s[0] != #char "\t" && s[0] != #char "\r"  advance(*s);
        word.count -= s.count;
        array_add(*words, word);
    }
    return words;
}

to_lower_copy :: (s: string) -> string {
    result := copy_string(s);
    to_lower_in_place(result);
    return result;
}
