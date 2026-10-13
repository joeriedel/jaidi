// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// DARKPILO.CFG, the agents: "PCF", version 0x12, 14, then 14 records of 1067 bytes, as
// DARK.EXE reads and writes it (0x188ac, 0x189d8, 0x184ba, 0x1860d). A record: the name, the
// mission chosen, the highest open, the difficulty, the difficulty each mission was done at,
// and for each mission what the agent takes into it: 32 bytes of items, 10 numbers of ammo
// and stats. A file that's missing or whose header is wrong is made new: 14 blank records
// (0x18699).

AGENT_SLOTS   :: 14;
AGENT_MISSIONS :: 14;
AGENT_NAME_MAX :: 32;

Agent_Record :: struct {
    name: [AGENT_NAME_MAX] u8;      // Zero-terminated; empty for a free slot.
    selected: s32;                  // The mission chosen, from 1.
    next: s32;                      // The highest mission open.
    difficulty: u8;                 // 0 easy, 1 medium, 2 hard.
    completed: [AGENT_MISSIONS] u8; // The difficulty each mission was done at.
    // What the agent takes into each mission, by the mission's place from 0: the items'
    // bytes (Agent_Items) and the ammo and stats (Agent_Stats).
    items: [AGENT_MISSIONS] [32] u8;
    stats: [AGENT_MISSIONS] [10] s32;
}

// The bytes of a mission's items.
Agent_Items :: enum s32 {
    PISTOL :: 0; RIFLE; DETONATOR_WEAPON; AUTOGUN; MORTAR; FUSION; MINE_WEAPON; CONCUSSION; CANNON;
    RED_KEY; YELLOW_KEY; BLUE_KEY; GOGGLES; CLEATS; MASK; PLANS; PHRIK; NAVA; DATATAPE; UNUSED;
    DT_WEAPON; CODE1;               // To CODE9, 29.
    CURRENT_WEAPON :: 30;
    LIVES :: 31;
}

// A mission's numbers: the ammo (energy, power, plasma, detonators, shells, mines,
// missiles), then shields, health and the battery in 16.16.
AGENT_STAT_SHIELDS :: 7;
AGENT_STAT_HEALTH  :: 8;
AGENT_STAT_BATTERY :: 9;

Agents :: struct {
    records: [AGENT_SLOTS] Agent_Record;
}

agent_get_name :: (record: *Agent_Record) -> string {
    count := 0;
    while count < AGENT_NAME_MAX && record.name[count]  count += 1;
    return .{count, record.name.data};
}

// The name, cut to what fits with its terminator.
agent_set_name :: (record: *Agent_Record, name: string) {
    memset(record.name.data, 0, AGENT_NAME_MAX);
    for 0..min(name.count, AGENT_NAME_MAX - 1)-1  record.name[it] = name[it];
}

// A record as a new file has them (0x18421): the pistol and the two thrown weapons, the
// pistol in hand, 3 lives; energy, shields and health 100; the battery full.
agent_get_blank_record :: () -> Agent_Record {
    r: Agent_Record;
    for m: 0..AGENT_MISSIONS-1 {
        items := *r.items[m];
        items.*[Agent_Items.PISTOL] = 0xFF;
        items.*[Agent_Items.DETONATOR_WEAPON] = 0xFF;
        items.*[Agent_Items.MINE_WEAPON] = 0xFF;
        items.*[Agent_Items.CURRENT_WEAPON] = 1;
        items.*[Agent_Items.LIVES] = 3;
        stats := *r.stats[m];
        stats.*[0] = 100;
        stats.*[AGENT_STAT_SHIELDS] = 100;
        stats.*[AGENT_STAT_HEALTH] = 100;
        stats.*[AGENT_STAT_BATTERY] = 0x20000;
    }
    return r;
}

// Reads the file; false when it's missing or its header is wrong, and the agents are a new
// file's, for the caller to write (0x18699).
agents_load :: (path: string) -> Agents, bool {
    agents: Agents;
    contents, ok := read_entire_file(path, log_errors = false);
    defer free(contents);
    bytes := cast([] u8) contents;
    if ok && bytes.count >= HEADER_SIZE + AGENT_SLOTS * RECORD_SIZE && bytes[0] == #char "P" && bytes[1] == #char "C" && bytes[2] == #char "F" && bytes[3] == VERSION && bytes[4] == AGENT_SLOTS {
        for * agents.records  read_record(it, array_view(bytes, HEADER_SIZE + it_index * RECORD_SIZE, RECORD_SIZE));
        return agents, true;
    }
    for * agents.records  it.* = agent_get_blank_record();
    return agents, false;
}

agents_save :: (agents: *Agents, path: string) -> bool {
    bytes := NewArray(HEADER_SIZE + AGENT_SLOTS * RECORD_SIZE, u8,, temp);
    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4] = #char "P", #char "C", #char "F", VERSION, AGENT_SLOTS;
    for * agents.records  write_record(it, array_view(bytes, HEADER_SIZE + it_index * RECORD_SIZE, RECORD_SIZE));
    make_directory_if_it_does_not_exist(path_strip_filename(path), recursive = true);
    if !write_entire_file(path, bytes.data, bytes.count) {
        log_error("Couldn't write '%'.", path);
        return false;
    }
    return true;
}

#scope_file

HEADER_SIZE :: 5;
RECORD_SIZE :: 1067;
VERSION :: 0x12;

read_record :: (r: *Agent_Record, b: [] u8) {
    for 0..AGENT_NAME_MAX-1  r.name[it] = b[it];
    r.name[AGENT_NAME_MAX - 1] = 0;
    r.selected = get_s32(b, 0x20);
    r.next = get_s32(b, 0x24);
    r.difficulty = b[0x28];
    for 0..AGENT_MISSIONS-1  r.completed[it] = b[0x29 + it];
    for m: 0..AGENT_MISSIONS-1 {
        for i: 0..31  r.items[m][i] = b[0x37 + m * 32 + i];
        for i: 0..9   r.stats[m][i] = get_s32(b, 0x1F7 + (m * 10 + i) * 4);
    }
}

write_record :: (r: *Agent_Record, b: [] u8) {
    for 0..AGENT_NAME_MAX-1  b[it] = r.name[it];
    put_s32(b, 0x20, r.selected);
    put_s32(b, 0x24, r.next);
    b[0x28] = r.difficulty;
    for 0..AGENT_MISSIONS-1  b[0x29 + it] = r.completed[it];
    for m: 0..AGENT_MISSIONS-1 {
        for i: 0..31  b[0x37 + m * 32 + i] = r.items[m][i];
        for i: 0..9   put_s32(b, 0x1F7 + (m * 10 + i) * 4, r.stats[m][i]);
    }
}

get_s32 :: (b: [] u8, at: int) -> s32 {
    v := (cast(u32) b[at]) | ((cast(u32) b[at + 1]) << 8) | ((cast(u32) b[at + 2]) << 16) | ((cast(u32) b[at + 3]) << 24);
    return cast,no_check(s32) v;
}

put_s32 :: (b: [] u8, at: int, value: s32) {
    v := cast,no_check(u32) value;
    for 0..3  b[at + it] = cast,trunc(u8) (v >> (8 * it));
}

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
