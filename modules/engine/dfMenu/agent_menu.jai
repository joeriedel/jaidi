// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The agent menu (DARK.EXE 0x9062b, pilotmen.c), from AGENTMNU.LFD: the agents on the left,
// the missions on the right, up to the highest the chosen agent has open, each one done
// marked with the difficulty it was done at. New Agent asks for a name, Remove and Exit ask
// first (agentdlg.c); Begin plays the mission chosen.
//
// The lists (listbox.c): the background again under each, a bar on the chosen row, darker
// in the list that has the keys, the rows in the font 8 lines apart. Up and Down move in the
// list with the keys, Tab, Left and Right switch lists; a press picks the row under it. The
// agents are listed by name, without case, the free ones last.

// Opens the menu over the agents and the missions' titles, from current's record. frame_delay
// in Landru ticks. The result: the mission to play, or 0 for Exit. With all_open (dev builds),
// every mission may be played, whatever the agent has done.
menu_open_agents :: (agents: *Agents, missions: [] string, current: s32, frame_delay: s32, all_open := false) -> bool {
    if !open_menu("agentmnu.lfd", "agentmnu", "agentmnu", frame_delay) return false;
    a := *agent_menu;
    a.agents = agents;
    a.missions = missions;
    a.mission_count = cast(s32) min(missions.count, AGENT_MISSIONS);
    a.all_open = all_open;
    // Each agent's mission is one it may play (0x198e4).
    for * agents.records  it.selected = max(cast(s32) 1, min(it.selected, get_open_missions(it)));
    sort_agents();
    a.current = 0;
    for a.order  if it == current  a.current = xx it_index;
    a.lists[0] = .{rect = get_frame_rect(9)};
    a.lists[1] = .{rect = get_frame_rect(10)};
    menu.background = 0;
    add_button(BUTTON_NEW, 2, 1);
    add_button(BUTTON_REMOVE, 4, 3);
    add_button(BUTTON_EXIT, 6, 5);
    add_button(BUTTON_BEGIN, 8, 7);
    refresh_lists();
    menu.screen = .{on_button = on_agent_button, on_key = on_agent_key, on_press = on_agent_press, on_frame = on_agent_frame, draw = draw_agent_lists};
    return true;
}

// The record of the agent chosen.
menu_get_chosen_agent :: () -> s32 {
    a := *agent_menu;
    return a.order[clamp(a.current, 0, AGENT_SLOTS - 1)];
}

#scope_file

BUTTON_NEW    :: 100;
BUTTON_REMOVE :: 110;
BUTTON_EXIT   :: 120;
BUTTON_BEGIN  :: 130;

LIST_AGENTS   :: 0;
LIST_MISSIONS :: 1;

NAME_LENGTH :: 18;              // What the name field takes (0xc4907).

List :: struct {
    rect: Rect;
    count, selected: s32;
    activated: bool;            // Changed by the player since the last frame.
    invalid := true;
}

Dialog_Kind :: enum u8 { NONE; NAME; REMOVE; EXIT; }

agent_menu: struct {
    agents: *Agents;
    missions: [] string;
    mission_count: s32;
    all_open: bool;             // Every mission open (dev builds).
    order: [AGENT_SLOTS] s32;   // The records by name.
    current: s32;               // Into order.
    lists: [2] List;
    dialog: Dialog_Kind;
    name: [..] u8;
    name_slot: s32;             // The record the name dialog fills.
};

// The list with the keys, kept from one visit to the next (0xf8d78).
focus: s32 = LIST_AGENTS;

// How many missions the agent may play: up to the highest it has open.
get_open_missions :: (record: *Agent_Record) -> s32 {
    a := *agent_menu;
    return ifx a.all_open then a.mission_count else min(record.next, a.mission_count);
}

get_agent :: () -> *Agent_Record {
    a := *agent_menu;
    return *a.agents.records[a.order[clamp(a.current, 0, AGENT_SLOTS - 1)]];
}

count_agents :: () -> s32 {
    n: s32;
    for agent_menu.agents.records  if it.name[0]  n += 1;
    return n;
}

// The lists' counts and choices from the agents (0x8fcc9).
refresh_lists :: () {
    a := *agent_menu;
    count := count_agents();
    if count <= a.current  a.current = 0;
    agents := *a.lists[LIST_AGENTS];
    agents.count, agents.selected, agents.invalid = count, a.current, true;
    record := get_agent();
    missions := *a.lists[LIST_MISSIONS];
    missions.count = get_open_missions(record);
    missions.selected = record.selected - 1;
    missions.invalid = true;
}

// New Agent only while a slot is free (0x8fb33).
update_new_button :: () {
    b := find_button(BUTTON_NEW);
    if b  b.enabled = count_agents() < AGENT_SLOTS;
}

// By name without case, the free ones last, by the original's quicksort (0x905b4, 0x90392),
// whose order for equal names is its own; the agent chosen stays chosen.
sort_agents :: () {
    a := *agent_menu;
    current := a.order[clamp(a.current, 0, AGENT_SLOTS - 1)];
    for * a.order  it.* = xx it_index;
    quicksort(0, AGENT_SLOTS - 1);
    for a.order  if it == current  a.current = xx it_index;
}

compare_agents :: (i: s32, j: s32) -> s32 {
    a := *agent_menu;
    x := agent_get_name(*a.agents.records[a.order[i]]);
    y := agent_get_name(*a.agents.records[a.order[j]]);
    k := 0;
    while true {
        cx := ifx k < x.count then to_lower(x[k]) else 0;
        cy := ifx k < y.count then to_lower(y[k]) else 0;
        if cx != cy {
            // A free slot after any name.
            if !x.count return 1;
            if !y.count return -1;
            return cast(s32) cx - cast(s32) cy;
        }
        if !cx return 0;
        k += 1;
    }
    return 0;
}

swap_agents :: (i: s32, j: s32) {
    a := *agent_menu;
    a.order[i], a.order[j] = a.order[j], a.order[i];
}

quicksort :: (lo: s32, hi: s32) {
    if hi <= lo return;
    if hi - lo == 1 {
        if compare_agents(lo, hi) > 0  swap_agents(lo, hi);
        return;
    }
    p := lo;
    i, j := lo + 1, hi;
    while i < j {
        while i < j && compare_agents(i, p) <= 0  i += 1;
        while i < j && compare_agents(p, j) < 0   j -= 1;
        if i < j  swap_agents(i, j);
    }
    if compare_agents(p, i) > 0 {
        swap_agents(p, i);
        j += 1;
    } else {
        i -= 1;
    }
    if i - lo < hi - j {
        quicksort(lo, i);
        quicksort(j, hi);
    } else {
        quicksort(j, hi);
        quicksort(lo, i);
    }
}

on_agent_button :: (id: s32) {
    a := *agent_menu;
    if id == {
        case BUTTON_NEW;
            // The first free slot by the list's order.
            for a.order {
                if a.agents.records[it].name[0] continue;
                a.name_slot = it;
                open_agent_dialog(.NAME);
                break;
            }
        case BUTTON_REMOVE;
            open_agent_dialog(.REMOVE);
        case BUTTON_EXIT;
            open_agent_dialog(.EXIT);
        case BUTTON_BEGIN;
            record := get_agent();
            if record.name[0] && record.selected >= 0 && record.selected <= get_open_missions(record)  menu.result = record.selected;
    }
}

// Tab, Left and Right switch lists (0x90242), without taking the key; Up and Down move in
// the list with the keys (0xa5bec), clamped.
on_agent_key :: (code: s32) -> bool {
    a := *agent_menu;
    if code == KEY_TAB || code == KEY_LEFT || code == KEY_RIGHT {
        focus = 1 - focus;
        a.lists[0].invalid, a.lists[1].invalid = true, true;
        return false;
    }
    if code == KEY_UP || code == KEY_DOWN {
        list := *a.lists[focus];
        selected := clamp(list.selected + ifx code == KEY_UP then cast(s32) -1 else 1, 0, max(list.count - 1, 0));
        if selected != list.selected {
            list.selected = selected;
            list.activated = true;
            list.invalid = true;
        }
        return true;
    }
    return false;
}

// A press in a list picks the row under it; holding and letting go do nothing more.
on_agent_press :: (x: s32, y: s32) {
    a := *agent_menu;
    for * list, index: a.lists {
        if !is_inside(list.rect, x, y) continue;
        row := clamp((y - list.rect.top - 3) / 8, 0, max(list.count - 1, 0));
        list.selected = row;
        list.activated = true;
        list.invalid = true;
        return;
    }
}

// The lists' callbacks (0x8fda3, 0x8fe10).
on_agent_frame :: (frame: s32) {
    a := *agent_menu;
    // With no agents yet, the name is asked for at once: here once the menu has been drawn,
    // which the original may not wait for.
    if frame == 1 && !count_agents() {
        b := find_button(BUTTON_NEW);
        if b  press_by_key(b);
        return;
    }
    agents := *a.lists[LIST_AGENTS];
    if agents.activated {
        agents.activated = false;
        a.current = agents.selected;
        set_focus(LIST_AGENTS);
        refresh_lists();
    }
    missions := *a.lists[LIST_MISSIONS];
    if missions.activated {
        missions.activated = false;
        get_agent().selected = missions.selected + 1;
        set_focus(LIST_MISSIONS);
        refresh_lists();
    }
}

set_focus :: (list: s32) {
    if focus == list return;
    focus = list;
    agent_menu.lists[0].invalid, agent_menu.lists[1].invalid = true, true;
}

draw_agent_lists :: () {
    a := *agent_menu;
    for * list, index: a.lists {
        if !(menu.refresh || list.invalid) continue;
        list.invalid = false;
        draw_list(list, xx index);
    }
}

// A list (0xa5d66): the background again inside it, the bar over the chosen row, then each
// row's text, from 4 in and 4 down, 8 lines apart, clipped to the list.
draw_list :: (list: *List, index: s32) {
    a := *agent_menu;
    r := list.rect;
    list.selected = clamp(list.selected, 0, max(list.count - 1, 0));
    draw_frame(0, r);
    bar := menu.remap[ifx focus == index then 0xF else 0xE];
    fill_rect(.{r.left, r.top + 3 + 8 * list.selected, r.right, r.top + 12 + 8 * list.selected}, bar);
    for row: 0..list.count-1 {
        text: string;
        if index == LIST_AGENTS  text = agent_get_name(*a.agents.records[a.order[row]]);
        else if row < a.missions.count  text = a.missions[row];
        color := menu.remap[ifx row == list.selected then 6 else 3];
        draw_text(text, r.left + 4, r.top + 4 + 8 * row, color, r);
    }
    // Each mission done, marked with the difficulty it was done at (0x8fe6c).
    if index == LIST_MISSIONS {
        record := get_agent();
        mark := get_frame_rect(11);
        for i: 0..min(record.next - 1, list.count)-1 {
            draw_frame(11 + record.completed[i], dy = r.top - mark.top + 4 + 8 * i);
        }
    }
}

// The dialogs (agentdlg.c): over the menu, from agentdlg; frames 0 to 2 their backgrounds.
open_agent_dialog :: (kind: Dialog_Kind) {
    a := *agent_menu;
    background: s32 = ifx kind == .REMOVE then cast(s32) 0 else ifx kind == .EXIT then cast(s32) 1 else 2;
    if !open_menu_dialog("agentdlg", background) return;
    a.dialog = kind;
    if kind == {
        case .REMOVE;
            add_button(170, 3, 4);
            add_button(160, 5, 6);
        case .EXIT;
            add_button(190, 3, 4);
            add_button(180, 5, 6);
        case .NAME;
            add_button(150, 7, 8);
            add_button(140, 9, 10);
            array_reset(*a.name);
    }
    menu.screen = .{on_button = on_dialog_button, on_key = on_dialog_key, on_frame = on_dialog_frame, draw = draw_dialog};
}

// OK and the yeses are the lower ids of their pairs.
on_dialog_button :: (id: s32) {
    menu.dialog.result = ifx id == 140 || id == 160 || id == 180 then cast(s32) 1 else -1;
}

// The name field (0xc40a5): characters from space to '~' while there's room, Backspace and
// Delete take the last off.
on_dialog_key :: (code: s32) -> bool {
    a := *agent_menu;
    if a.dialog != .NAME return false;
    if code >= 0x20 && code <= 0x7E {
        if a.name.count < NAME_LENGTH  array_add(*a.name, cast(u8) code);
        return true;
    }
    if code == KEY_BACKSPACE || code == KEY_DELETE {
        if a.name  a.name.count -= 1;
        return true;
    }
    return false;
}

// The field (0xc42ea): a box with a lighter top and sides, the name, and a caret blinking
// with Landru's clock.
draw_dialog :: () {
    a := *agent_menu;
    if a.dialog != .NAME return;
    r := get_frame_rect(11);
    light, dark, black := menu.remap[2], menu.remap[4], menu.remap[0];
    fill_rect(.{r.left, r.top, r.right, r.top + 1}, light);
    fill_rect(.{r.left, r.bottom - 1, r.right, r.bottom}, dark);
    fill_rect(.{r.left, r.top + 1, r.left + 1, r.bottom - 1}, light);
    fill_rect(.{r.right - 1, r.top + 1, r.right, r.bottom - 1}, light);
    fill_rect(.{r.left + 1, r.top + 1, r.right - 1, r.bottom - 1}, black);
    name := cast(string) a.name;
    draw_text(name, r.left + 3, r.top + 3, dark, r);
    caret_x := r.left + 4 + get_text_width(name);
    fill_rect(.{caret_x, r.top + 11, caret_x + 6, r.top + 12}, ifx get_landru_ticks() & 0x40 then dark else black);
}

// A dialog's answer, once it has one.
on_dialog_frame :: (frame: s32) {
    a := *agent_menu;
    yes := menu.dialog.result > 0;
    if !menu.dialog.result return;
    kind := a.dialog;
    a.dialog = .NONE;
    name := trim(copy_string(cast(string) a.name,, temp));
    close_menu_dialog();
    if kind == {
        case .NAME;
            record := *a.agents.records[a.name_slot];
            // A name of nothing but spaces counts as none.
            if yes && name {
                agent_set_name(record, cast(string) a.name);
                record.next, record.selected = 1, 1;
                record.completed = .[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
                for a.order  if it == a.name_slot  a.current = xx it_index;
            } else {
                record.name[0] = 0;
            }
            sort_agents();
            update_new_button();
            refresh_lists();
        case .REMOVE;
            if !yes return;
            record := get_agent();
            record.name[0] = 0;
            record.next, record.selected = 0, 0;
            record.completed = .[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
            a.lists[LIST_AGENTS].activated = true;
            update_new_button();
            sort_agents();
            refresh_lists();
        case .EXIT;
            if yes  menu.result = 0;
    }
}

#import "engine/dfAgents";
