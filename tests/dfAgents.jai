// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// A file that isn't there is made: 14 blank records, the size of the original's.
agents_file_is_made :: () {
    path := tprint("%/.build/agents_test/DARKPILO.CFG", get_working_directory());
    file_delete(path);
    defer file_delete(path);
    agents, existed := agents_load(path);
    check(!existed, "found a file that isn't there");
    agents_save(*agents, path);
    data, ok := read_entire_file(path);
    if !check(ok && data.count == 14943, "made a file of % bytes", data.count) return;
    blank := *agents.records[0];
    check(!blank.name[0] && blank.items[0][Agent_Items.LIVES] == 3 && blank.stats[0][AGENT_STAT_BATTERY] == 0x20000, "blank record %", blank.items[0]);

    agent_set_name(*agents.records[2], "Kyle Katarn");
    agents.records[2].next = 5;
    agents.records[2].completed[3] = 2;
    agents.records[2].stats[4][0] = 321;
    check(agents_save(*agents, path), "not saved");
    again, read_back := agents_load(path);
    check(read_back, "didn't read it back");
    r := *again.records[2];
    check(agent_get_name(r) == "Kyle Katarn" && r.next == 5 && r.completed[3] == 2 && r.stats[4][0] == 321, "read back '%', next %", agent_get_name(r), r.next);
} @test

// The retail file reads as the original's: 14 records, three named.
retail_agents_read :: () {
    skip_without_dark();
    agents, ok := agents_load(tprint("%/DARKPILO.CFG", find_dark_data_dir()));
    if !check(ok, "not read") return;
    named := 0;
    for agents.records  if it.name[0]  named += 1;
    check(named == 3, "% agents named", named);
} @test

#import "Basic";
#import "File";
#import "File_Utilities";
#import "System";
#import "engine/dfArchive";
#import "engine/dfAgents";
