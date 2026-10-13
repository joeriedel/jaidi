// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The Esc menu in a mission (DARK.EXE 0x19c94, 0x925eb), from MENU.LFD: Abort Mission, or
// Next Mission once the mission is complete; Configuration; Quit; Return to Mission. Abort,
// Next and Quit ask first, each in its own dialog (the yesno ANIM, 0x92714, 0x9275e,
// 0x927ab) in place of the menu; No goes back to the menu.
//
// Behind it the game stands still in grey, the menu palette's grey for each color's
// brightness (0x4ead8): see menu_get_grey_palette. The caller fades the game out first and,
// on Return, back in (0x199e6, 0x19a6d).

Esc_Result :: enum s32 {
    RETURN :: 0;                // To the mission.
    NEXT   :: 1;                // The mission complete: on to the next.
    ABORT  :: 2;
    QUIT   :: 4;
}

menu_open_esc :: (mission_complete: bool, frame_delay: s32) -> bool {
    esc = .{complete = mission_complete, frame_delay = frame_delay};
    return open_esc_menu();
}

// The game's palette as it shows behind the Esc menu: each color the grey of the menu's
// palette (entries 33 to 63, darkest last) for its brightness, from the DAC's 6-bit values
// (0x4ead8).
menu_get_grey_palette :: (game: Palette) -> Palette {
    grey: Palette;
    for game.colors {
        r, g, b := it.r >> 2, it.g >> 2, it.b >> 2;
        grey.colors[it_index] = menu.palette.colors[63 - (((b >> 2) + (r >> 2) + (g >> 1)) >> 1)];
    }
    return grey;
}

#scope_file

esc: struct {
    complete: bool;
    frame_delay: s32;
    dialog: Esc_Result;         // The dialog up, or RETURN for the menu.
};

BUTTON_ABORT  :: 310;
BUTTON_NEXT   :: 320;
BUTTON_RETURN :: 330;
BUTTON_CONFIG :: 340;
BUTTON_QUIT   :: 350;

open_esc_menu :: () -> bool {
    esc.dialog = .RETURN;
    if !open_menu("menu.lfd", "escmenu", "menu", esc.frame_delay) return false;
    menu.background = 0;
    // Only one of Abort and Next is there: the other isn't drawn and takes no keys.
    add_button(BUTTON_ABORT, 2, 1).enabled = !esc.complete;
    add_button(BUTTON_NEXT, 4, 3).enabled = esc.complete;
    add_button(BUTTON_RETURN, 6, 5);
    add_button(BUTTON_CONFIG, 8, 7);
    add_button(BUTTON_QUIT, 10, 9);
    menu.screen = .{on_button = on_esc_button, on_result = on_esc_result};
    return true;
}

// The dialogs' buttons by kind: background frame, then No's and Yes's ids and frames.
open_dialog :: (kind: Esc_Result) -> bool {
    if !open_menu("menu.lfd", "yesno", "menu", esc.frame_delay) return false;
    esc.dialog = kind;
    if kind == {
        case .NEXT;
            menu.background = 0;
            add_button(400, 4, 3);
            add_button(410, 6, 5);
        case .ABORT;
            menu.background = 1;
            add_button(420, 4, 3);
            add_button(430, 6, 5);
        case .QUIT;
            menu.background = 2;
            add_button(440, 8, 7);
            add_button(450, 10, 9);
    }
    menu.screen = .{on_button = on_dialog_button, on_result = on_esc_result};
    return true;
}

on_esc_button :: (id: s32) {
    if id == {
        case BUTTON_ABORT;   menu.result = xx Esc_Result.ABORT;
        case BUTTON_NEXT;    menu.result = xx Esc_Result.NEXT;
        case BUTTON_RETURN;  menu.result = xx Esc_Result.RETURN;
        case BUTTON_QUIT;    menu.result = xx Esc_Result.QUIT;
        // Configuration has no screen yet.
    }
}

// Yes is the higher id of each pair.
on_dialog_button :: (id: s32) {
    menu.result = ifx id % 20 == 10 then cast(s32) 1 else 0;
}

// The menu's choice opens its dialog; a dialog's No goes back to the menu, its Yes is the
// answer.
on_esc_result :: (result: s32) -> bool {
    if esc.dialog == .RETURN {
        if result == xx Esc_Result.RETURN return false;
        return open_dialog(xx result);
    }
    if result == 1 {
        menu.result = xx esc.dialog;
        return false;
    }
    return open_esc_menu();
}
