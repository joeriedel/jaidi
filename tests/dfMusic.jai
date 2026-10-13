// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

TICKS_PER_SECOND :: 1_000_000 / IMUSE_TICK_US;

random_matches_the_original :: () {
    imuse_init();
    music_init();
    // The original's generator from the linked seeds, worked out by hand from its code.
    expected :: int.[4, 6, 6, 6, 4, 7, 6, 2, 3, 7, 1, 7];
    for expected {
        got := music_pick_random(0, 9);
        if !check(got == it, "pick % is %, expected %", it_index, got, it)  break;
    }
} @test

stalk_to_fight_and_back :: () {
    if !start_level_one() return;
    defer gob_unmount_all();

    status := music_get_status();
    check(status.state == .STALK && get_playing_song() == "stalk-01", "level 1 starts with %, playing %", status.state, get_playing_song());

    // Not at once: the song opens with a "clear callback" marker, which would end the wait for
    // a transition before it began, in the original too.
    for 1..TICKS_PER_SECOND * 5  imuse_tick();
    music_set_state(.FIGHT);
    seconds, steps := run_until_playing_only("fight-01", 60);
    print("    to fight in % s, through %\n", seconds, steps);
    check(seconds >= 0, "never got to fight-01");
    check(steps.waited && steps.transition && steps.entered, "skipped a step of the transition");
    check(music_get_status().last_entry > 0, "no entry point picked");
    check(!has_stuck_voices(), "notes stuck after the transition");

    music_set_state(.STALK);
    seconds, steps = run_until_playing_only("stalk-01", 60);
    print("    back to stalk in % s, through %\n", seconds, steps);
    check(seconds >= 0, "never got back to stalk-01");
    check(!has_stuck_voices(), "notes stuck after the transition back");
    music_stop();
} @test

songs_start_by_name :: () {
    if !start_level_one() return;
    defer gob_unmount_all();

    music_start_songs("stalk-02", "fight-02");
    status := music_get_status();
    check(status.level == 0 && status.state == .STALK, "level %, state %", status.level, status.state);
    check(status.stalk_song == "stalk-02" && status.fight_song == "fight-02", "songs % and %", status.stalk_song, status.fight_song);
    check(get_playing_song() == "stalk-02", "playing %", get_playing_song());

    music_stop();
    check(music_get_status().state == .OFF && !music_get_status().stalk_song && imuse_get_status().player_count == 0, "didn't stop");
} @test

fight_music_runs_out :: () {
    if !start_level_one() return;
    defer gob_unmount_all();

    for 1..TICKS_PER_SECOND * 5  imuse_tick();
    // Alerts build up: the first sets the timer 873 ticks behind, each next one adds 436, and
    // fight music starts once the timer passes now: at the fourth alert in a row.
    now := 10_000;
    for 1..3  music_start_fight(now);
    check(music_get_status().state == .STALK, "fight music started after % alerts", 3);
    music_start_fight(now);
    check(music_get_status().state == .FIGHT && music_get_status().fight, "four alerts didn't start fight music");
    music_update(now + MUSIC_FIGHT_EXTEND - 1);
    check(music_get_status().state == .FIGHT, "fight music ended early");
    music_update(now + MUSIC_FIGHT_EXTEND);
    check(music_get_status().state == .STALK && !music_get_status().fight, "fight music didn't run out");

    music_sustain_fight(now + 1000);
    check(music_get_status().state == .STALK, "sustaining a finished fight restarted it");
    music_stop();
} @test

#scope_file

start_level_one :: () -> bool #expand {
    skip_without_dark();
    gob_unmount_all();
    dir := find_dark_data_dir();
    assert(gob_mount_retail(dir));
    if !fm_driver.loaded  assert(fm_load_driver(dir));
    imuse_init();
    music_init();
    music_start_level(1);
    return true;
}

Steps_Seen :: struct {
    waited, transition, entered: bool;
}

// Seconds until 'name' is the only song playing, or -1.
run_until_playing_only :: (name: string, limit_seconds: int) -> seconds: float, Steps_Seen {
    steps: Steps_Seen;
    for tick: 1..limit_seconds * TICKS_PER_SECOND {
        imuse_tick();
        step := music_get_status().step;
        if step == .WAITING     steps.waited     = true;
        if step == .TRANSITION  steps.transition = true;
        if step == .ENTERING    steps.entered    = true;
        s := imuse_get_status();
        if s.player_count == 1 && s.players[0].name == name && step != .ENTERING  return tick / cast(float) TICKS_PER_SECOND, steps;
    }
    return -1, steps;
}

get_playing_song :: () -> string {
    s := imuse_get_status();
    return ifx s.player_count then s.players[0].name else "";
}

// Voices sounding on channels the playing song doesn't hold.
has_stuck_voices :: () -> bool {
    s := imuse_get_status();
    used: [16] bool;
    used[MIDI_DRUM_CHANNEL] = true;
    for p: 0..s.player_count-1  for s.players[p].parts  if it.channel >= 0  used[it.channel] = true;
    for fm_get_voice_state()  if it.active && !used[it.channel]  return true;
    return false;
}

#import "Basic";
#import "engine/dfArchive";
#import "engine/dfFm";
#import "engine/dfIMuse";
#import "engine/dfMusic";
