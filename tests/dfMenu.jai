// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

LIST :: #string END
BRF 1.0
BRIEFS 3
# A comment.
LEV: SECBASE    LFD: dfbrief.lfd ANI: brf-mon PAL: brf-jan

LEV: TALAY	LFD: DFBRIEF.LFD ANI: brf-jan
LEV: TALAY      LFD: dfbrief.lfd ANI: brf-jan PAL: brf-jan
LEV: ARC        LFD: dfbrief.lfd ANI: brf-jan PAL: brf-jan
LEV: EXTRA      LFD: dfbrief.lfd ANI: brf-jan PAL: brf-jan
END

briefing_list_parses :: () {
    list, ok := briefing_list_parse(LIST);
    defer briefing_list_free(*list);
    if !check(ok && list.count == 3, "% briefings", list.count) return;
    check(list[0].level == "secbase" && list[0].anim == "brf-mon" && list[0].pltt == "brf-jan", "first: %", list[0]);
    check(list[1].level == "talay" && list[2].level == "arc", "skipped the short line: %, %", list[1].level, list[2].level);
} @test

// The briefing by keys: the difficulty chosen, then OK.
briefing_by_keys :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    if !check(menu_open_briefing("SECBASE", 1, 20), "no briefing") return;
    check(run_menu(3) == MENU_NO_RESULT, "a result before any key");
    menu_press_key(#char "h");
    check(run_menu(3) == MENU_NO_RESULT, "a result from the difficulty");
    check(menu_get_briefing_difficulty() == 2, "difficulty %", menu_get_briefing_difficulty());
    // Case counts: "O" and "o" are OK's, "K" nothing.
    menu_press_key(#char "K");
    check(run_menu(3) == MENU_NO_RESULT, "K did something");
    menu_press_key(KEY_ENTER);
    check(run_menu(3) == 1, "OK didn't accept");
} @test

briefing_cancel_keeps_difficulty :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    if !check(menu_open_briefing("TALAY", 0, 20), "no briefing") return;
    menu_press_key(#char "M");
    menu_press_key(KEY_ESCAPE);
    check(run_menu(4) == 0, "Esc didn't cancel");
    check(menu_get_briefing_difficulty() == 1, "difficulty %", menu_get_briefing_difficulty());
} @test

// Abort asks first; No goes back to the menu; Next isn't there until the mission is done.
esc_menu_by_keys :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    if !check(menu_open_esc(false, 20), "no Esc menu") return;
    menu_press_key(#char "n");
    check(run_menu(3) == MENU_NO_RESULT, "Next before the mission is done");
    menu_press_key(#char "a");
    check(run_menu(3) == MENU_NO_RESULT, "Abort didn't ask");
    menu_press_key(#char "n");
    check(run_menu(3) == MENU_NO_RESULT, "No didn't go back");
    menu_press_key(#char "A");
    menu_press_key(#char "y");
    check(run_menu(6) == xx Esc_Result.ABORT, "Yes didn't abort");

    if !check(menu_open_esc(true, 20), "no Esc menu") return;
    menu_press_key(#char "N");
    menu_press_key(KEY_ENTER);
    check(run_menu(6) == xx Esc_Result.NEXT, "Enter in Next's dialog isn't yes");
    if !check(menu_open_esc(true, 20), "no Esc menu") return;
    menu_press_key(KEY_ESCAPE);
    check(run_menu(3) == xx Esc_Result.RETURN, "Esc didn't return");
} @test

// The mouse: OK pressed and let go over it.
briefing_by_mouse :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    if !check(menu_open_briefing("SECBASE", 1, 20), "no briefing") return;
    run_menu(1);
    video, covered := menu_get_video();
    check(covered[100 * 320 + 160], "the briefing's box isn't drawn");
    menu_move_mouse(250, 178, true);
    check(run_menu(1) == MENU_NO_RESULT, "acted on the press");
    menu_move_mouse(250, 178, false);
    check(run_menu(3) == 1, "OK didn't accept on the release");
} @test

// No agents: the name is asked for at once; typed, OK makes the agent, and Begin plays its
// first mission.
agent_menu_new_agent :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    agents: Agents;
    for * agents.records  it.* = agent_get_blank_record();
    if !check(menu_open_agents(*agents, MISSIONS, 0, 20), "no agent menu") return;
    run_menu(2);
    for cast([] u8) "Kyle K"  menu_press_key(it);
    menu_press_key(KEY_BACKSPACE);
    menu_press_key(KEY_ENTER);
    check(run_menu(12) == MENU_NO_RESULT, "a result from the name");
    chosen := menu_get_chosen_agent();
    record := *agents.records[chosen];
    check(agent_get_name(record) == "Kyle " && record.next == 1 && record.selected == 1, "agent % '%', next %", chosen, agent_get_name(record), record.next);
    // The bars in the palette's matches: the list with the keys (agents) darker.
    video := menu_get_video();
    check(video[35 * 320 + 26] == 12 && video[35 * 320 + 172] == 13, "bars % and %", video[35 * 320 + 26], video[35 * 320 + 172]);
    menu_press_key(#char "b");
    check(run_menu(3) == 1, "Begin didn't play mission 1");
} @test

agent_menu_remove :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    agents: Agents;
    for * agents.records  it.* = agent_get_blank_record();
    agent_set_name(*agents.records[3], "Jan");
    agents.records[3].next = 4;
    agent_set_name(*agents.records[5], "anders");
    agents.records[5].next = 1;
    if !check(menu_open_agents(*agents, MISSIONS, 3, 20), "no agent menu") return;
    // Listed by name without case: anders, then Jan, who is chosen.
    run_menu(2);
    check(menu_get_chosen_agent() == 3, "chosen %", menu_get_chosen_agent());
    menu_press_key(KEY_UP);
    run_menu(2);
    check(menu_get_chosen_agent() == 5, "after Up, chosen %", menu_get_chosen_agent());
    menu_press_key(#char "r");
    menu_press_key(#char "y");
    run_menu(10);
    check(!agents.records[5].name[0] && menu_get_chosen_agent() == 3, "after Remove: '%', chosen %", agent_get_name(*agents.records[5]), menu_get_chosen_agent());
    // Exit asks; Enter is No.
    menu_press_key(#char "d");
    menu_press_key(KEY_ENTER);
    check(run_menu(10) == MENU_NO_RESULT, "Exit without asking");
    menu_press_key(KEY_ESCAPE);
    menu_press_key(#char "y");
    check(run_menu(10) == 0, "Exit didn't exit");
} @test

// The PDA by keys: the map's keys send it messages only on the map page, Space goes on to
// the next page, Shift+Space back, Esc leaves. Each page draws something into the display.
pda_by_keys :: () {
    skip_without_dark();
    if !start() return;
    defer menu_close_for_test();
    pda_messages.count = 0;
    source := Pda_Source.{
        level = "SECBASE",
        is_goal_done = (goal: s32) -> bool { return goal == 0; },
        secrets_percent = 50,
        draw_map = (pixels: [] u8, width: s32, height: s32) { for * pixels  it.* = 10; },
        send_map_message = (message: s32) { array_add(*pda_messages, message); },
    };
    source.weapons[0] = true;
    if !check(menu_open_pda(source, 20), "no PDA") return;
    check(pda_messages.count == 1 && pda_messages[0] == PDA_MAP_CENTER, "opening didn't center the map: %", pda_messages);
    run_menu(2);
    video := menu_get_video();
    check(video[80 * 320 + 100] == 10, "the map isn't in the display: %", video[80 * 320 + 100]);
    menu_press_key(#char "=");
    menu_press_key(#char "[");
    menu_press_key(KEY_LEFT);
    run_menu(4);
    check(pda_messages.count == 4 && pda_messages[1] == 6 && pda_messages[2] == 9 && pda_messages[3] == 4, "map keys sent %", pda_messages);
    // The weapons page: the map's keys do nothing there.
    menu_press_key(#char " ");
    menu_press_key(#char "=");
    run_menu(3);
    check(pda_messages.count == 4, "a map key on the weapons page: %", pda_messages);
    video = menu_get_video();
    check(video[80 * 320 + 100] != 10, "the map still shows on the weapons page");
    // Back past the map to the briefing, and its text.
    menu_set_shift_held(true);
    menu_press_key(#char " ");
    menu_press_key(#char " ");
    run_menu(3);
    menu_set_shift_held(false);
    menu_press_key(#char "=");
    run_menu(2);
    check(pda_messages.count == 4, "a map key on the briefing: %", pda_messages);
    menu_press_key(KEY_F1);
    check(run_menu(4) == 0, "F1 didn't leave the PDA");
} @test

pda_messages: [..] s32;

MISSIONS :: string.["Secret Base", "Talay: Tak Base", "Anoat City", "Research Facility"];

#scope_file

clock: u64;

start :: () -> bool {
    if !ready {
        if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs") return false;
        if !check(menu_init(find_dark_data_dir()), "no HOTKEYS.MSG, font or DARK.EXE") return false;
        ready = true;
    }
    return true;
}

ready: bool;

// Runs n menu frames; the result, if one came.
run_menu :: (frames: int) -> s32 {
    for 1..frames {
        clock += 1_000_000_000 / 10;
        result := menu_update(clock);
        if result != MENU_NO_RESULT return result;
    }
    return MENU_NO_RESULT;
}

menu_close_for_test :: () { menu_shutdown(); ready = false; }

#import "Basic";
#import "engine/dfArchive";
#import "engine/dfMenu";
#import "engine/dfAgents";
