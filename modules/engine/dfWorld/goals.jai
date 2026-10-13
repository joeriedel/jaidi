// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// A mission's goals and its end, as DARK.EXE keeps them.
//
// The level's GOL file says which goal each objective item and each INF "complete N"
// message finishes; the PDA shows them. Goals don't end the mission: the level's INF does,
// with an elevator reaching a stop marked COMPLETE (0x35e70). That marks the mission
// complete (0x10867) and starts a task (0x12a6a) that tells the player so, over and over,
// until the player leaves by the Esc menu.

// Whether a goal is done (0x1575c): by the first item or "complete" number that names it.
world_is_goal_complete :: (goal: s32) -> bool {
    s := *world.player_state;
    for 0..GOAL_SLOTS-1 {
        if world.goals.by_trigger[it] == goal return s.triggers_done[it];
        if world.goals.by_item[it] == goal    return s.items_done[it];
    }
    return false;
}

world_is_mission_complete :: () -> bool { return world.loaded && world.mission_complete; }

#scope_module

load_goals :: () {
    world.goals = .{};
    text, found := gob_find(tprint("%.GOL", world.name));
    if !found return;
    goals, ok := gol_parse(cast(string) text);
    if ok  world.goals = goals;
    else log_error("Couldn't read %.GOL.", world.name);
}

// A COMPLETE stop reached.
complete_mission :: () {
    world.mission_complete = true;
    if world.end_messages.running return;
    world.end_messages = .{running = true, next_tick = world.clock.tick};
    // Its task is made by the elevators' (0x12a38).
    world.tasks.end_messages = add_child_task(world.tasks.elevators, .END_MESSAGES);
}

// The task that keeps telling the player the mission is over (0x12a65): "Mission Objectives
// Complete" for 582 ticks, then "Press <ESC> Key to End Mission" for 4369, and again.
update_end_messages :: () {
    t := *world.end_messages;
    if !t.running || world.clock.tick < t.next_tick return;
    if !t.second {
        send_message(MSG_OBJECTIVES_COMPLETE);
        t.next_tick = world.clock.tick + 582;
    } else {
        send_message(MSG_PRESS_ESC);
        t.next_tick = world.clock.tick + 4369;
    }
    t.second = !t.second;
}

End_Messages :: struct {
    running: bool;
    second: bool;               // The second message is next.
    next_tick: s32;
}

MSG_OBJECTIVES_COMPLETE :: 461;
MSG_PRESS_ESC           :: 462;
