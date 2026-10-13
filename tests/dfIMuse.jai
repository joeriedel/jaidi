// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Interrupts per second of music: 1_000_000 / IMUSE_TICK_US is about 144.
TICKS_PER_SECOND :: 1_000_000 / IMUSE_TICK_US;

// A tempo event at the start takes effect during the first interrupt, which still runs at the
// default 120 BPM; the other 72 run at 240. With the original's rounding that reaches tick 966:
// beat 3, tick 6.
TEMPO_240_AFTER_73 :: 6;

half_second_is_one_beat_at_120 :: () {
    track: [..] u8;
    add_note(*track, 0, 0x90, 60, 100);
    add_note(*track, 1920, 0x80, 60, 0);
    add_end_of_track(*track, 0);
    play_tracks(track);

    // The original reduces tempo and tick rate below 2^16 before dividing, which rounds the step
    // to 6.66666 ticks per interrupt, so half a second (72 interrupts) lands one tick short.
    run(72);
    s := get_first_player();
    check(s.measure == 1 && s.beat == 1 && s.tick == 479, "at %.%.%, expected 1.1.479", s.measure, s.beat, s.tick);
    run(1);
    s = get_first_player();
    check(s.measure == 1 && s.beat == 2 && s.tick == 6, "at %.%.%, expected 1.2.6", s.measure, s.beat, s.tick);
    check(s.notes == 1, "% notes played", s.notes);
} @test

tempo_change_takes_effect :: () {
    track: [..] u8;
    add_tempo(*track, 0, 250000);  // 240 BPM.
    add_end_of_track(*track, 1920 * 4);
    play_tracks(track);

    run(73);
    s := get_first_player();
    check(s.tempo_us == 250000, "tempo %", s.tempo_us);
    check(s.measure == 1 && s.beat == 3 && s.tick == TEMPO_240_AFTER_73, "at %.%.%, expected 1.3.%", s.measure, s.beat, s.tick, TEMPO_240_AFTER_73);
} @test

beats_carry_into_measures :: () {
    track: [..] u8;
    add_end_of_track(*track, 1920 * 4);
    play_tracks(track);

    run(TICKS_PER_SECOND * 2 + 1);  // 4 beats at 120 BPM.
    s := get_first_player();
    check(s.measure == 2 && s.beat == 1, "at %.%.%, expected 2.1", s.measure, s.beat, s.tick);
} @test

marker_is_recorded :: () {
    track: [..] u8;
    add_sysex(*track, 0, .[0x7D, 3, #char "t", #char "o", #char " ", #char "B", 0, 0xF7]);
    add_end_of_track(*track, 1920);
    play_tracks(track);

    run(2);
    s := get_first_player();
    check(to_string(s.marker.data) == "to B", "marker is '%'", to_string(s.marker.data));
} @test

jump_loops_the_song :: () {
    track: [..] u8;
    add_note(*track, 0, 0x90, 60, 100);
    add_note(*track, 240, 0x80, 60, 0);
    add_jump(*track, 240, hook = 0, chunk = 1, measure = 1, beat = 1, tick = 0);  // At beat 2.
    add_end_of_track(*track, 1920);
    play_tracks(track);

    run(TICKS_PER_SECOND * 2);  // Four times round the half-second loop.
    check(imuse_get_status().player_count == 1, "stopped instead of looping");
    s := get_first_player();
    check(s.jumps >= 3, "% jumps", s.jumps);
    check(s.notes >= 4, "% notes", s.notes);
} @test

hooked_jump_is_skipped :: () {
    track: [..] u8;
    add_jump(*track, 0, hook = 5, chunk = 1, measure = 1, beat = 1, tick = 0);
    add_end_of_track(*track, 480);
    play_tracks(track);

    run(TICKS_PER_SECOND / 4);
    check(get_first_player().jumps == 0, "jumped");
    run(TICKS_PER_SECOND);
    check(imuse_get_status().player_count == 0, "still playing after the end of the track");
} @test

jump_to_another_chunk :: () {
    song: [..] u8;
    add_jump(*song, 0, hook = 0, chunk = 2, measure = 1, beat = 2, tick = 0);
    add_end_of_track(*song, 1920);
    transition: [..] u8;
    add_note(*transition, 600, 0x90, 64, 100);
    add_end_of_track(*transition, 1920);
    play_tracks(song, transition);

    run(2);
    s := get_first_player();
    check(s.chunk == 2 && s.jumps == 1, "chunk %, % jumps", s.chunk, s.jumps);
    run(TICKS_PER_SECOND / 4);
    check(get_first_player().notes == 1, "the transition's note didn't play");
} @test

parts_without_a_program_play_drums :: () {
    load_fm_driver();
    track: [..] u8;
    add_message(*track, 0, 0xC0 | 2, 5);  // Part 3 gets a program; part 4 doesn't.
    add_note(*track, 0, 0x92, 60, 100);
    add_note(*track, 0, 0x93, 36, 100);
    add_end_of_track(*track, 1920);
    play_tracks(track);

    run(1);
    p := get_first_player();
    check(p.parts[2].has_program && p.parts[2].channel == 0, "part 3 on channel %", p.parts[2].channel);
    check(!p.parts[3].has_program && p.parts[3].channel == -1, "part 4 on channel %", p.parts[3].channel);
    check(count_voices_on(0) == 1, "% voices on channel 0", count_voices_on(0));
    check(count_voices_on(MIDI_DRUM_CHANNEL) == 1, "% voices on the drum channel", count_voices_on(MIDI_DRUM_CHANNEL));
} @test

higher_priority_song_takes_channels :: () {
    // Fifteen melodic parts fill every output channel.
    full: [..] u8;
    for part: 0..14  add_message(*full, 0, 0xC0 | cast(u8) part, 1);
    add_end_of_track(*full, 1920 * 8);
    one: [..] u8;
    add_message(*one, 0, 0xC0, 1);
    add_end_of_track(*one, 1920 * 8);

    imuse_init();
    low  := play_song("FULL", 64, full);
    run(1);
    check(count_parts_with_channels(get_player(low)) == 15, "the first song holds % channels", count_parts_with_channels(get_player(low)));

    lower := play_song("LOWER", 40, one);
    run(1);
    check(count_parts_with_channels(get_player(lower)) == 0, "a lower-priority song took a channel");
    imuse_stop(lower);

    high := play_song("HIGHER", 80, one);
    run(1);
    check(get_player(high).parts[0].channel >= 0, "the higher-priority song got no channel");
    check(count_parts_with_channels(get_player(low)) == 14, "the first song kept % channels", count_parts_with_channels(get_player(low)));

    imuse_stop(high);
    check(count_parts_with_channels(get_player(low)) == 15, "the channel didn't go back");
} @test

volumes_combine :: () {
    track: [..] u8;
    add_message(*track, 0, 0xC0, 1);
    add_control(*track, 0, 0, 7, 64);
    add_end_of_track(*track, 1920 * 8);
    play_tracks(track);
    run(1);
    song := get_first_player().song;

    // (64 + 1) * (127 + 1) * player volume >> 14, the player's being 127 scaled by each.
    imuse_set_volume(song, 100);
    check(get_player(song).parts[0].volume == 50, "volume % at song volume 100", get_player(song).parts[0].volume);
    imuse_set_music_volume(64);
    check(get_player(song).parts[0].volume == 25, "volume % at music volume 64", get_player(song).parts[0].volume);

    imuse_set_volume(song, 0);
    check(get_player(song).parts[0].channel == -1, "a silent song kept its channel");
} @test

third_song_takes_the_oldest_player :: () {
    track: [..] u8;
    add_end_of_track(*track, 1920 * 8);

    imuse_init();
    a := play_song("A", 64, track);
    b := play_song("B", 64, track);
    c := imuse_load_midi_from_memory("C", make_gmd(track));
    d := imuse_load_midi_from_memory("D", make_gmd(track));
    check(!imuse_play(c, 63), "a lower-priority song took a player");
    check(imuse_play(c, 64), "an equal-priority song didn't take a player");
    check(!get_player(a) && get_player(b) && get_player(c), "the wrong song was stopped");
    check(imuse_play(d, 64) && !get_player(b), "the oldest of equals wasn't the one stopped");
} @test

bend_without_range_swells_volume :: () {
    track: [..] u8;
    add_message(*track, 0, 0xC0, 1);
    add_control(*track, 0, 0, 7, 64);
    add_control(*track, 0, 0, 16, 0);
    add_note(*track, 0, 0xE0, 0x7F, 0x7F);  // All the way up: 127.
    add_note(*track, 480, 0xE0, 0, 0x3F);   // Slightly down; the shifts round toward minus infinity.
    add_end_of_track(*track, 1920);
    play_tracks(track);

    run(1);
    check(get_first_player().parts[0].volume == 127, "volume % at full bend", get_first_player().parts[0].volume);
    run(TICKS_PER_SECOND / 2);
    check(get_first_player().parts[0].volume == 62, "volume % slightly down", get_first_player().parts[0].volume);
} @test

pedal_holds_released_notes :: () {
    load_fm_driver();
    track: [..] u8;
    add_message(*track, 0, 0xC0, 1);
    add_control(*track, 0, 0, 64, 127);
    add_note(*track, 0, 0x90, 60, 100);
    add_note(*track, 240, 0x80, 60, 0);
    add_control(*track, 240, 0, 64, 0);
    add_end_of_track(*track, 1920);
    play_tracks(track);

    run(TICKS_PER_SECOND / 4 + 4);  // Past the note-off.
    check(count_voices_on(0) == 1, "the pedal didn't hold the note");
    run(TICKS_PER_SECOND / 4);      // Past the pedal release.
    check(count_voices_on(0) == 0, "the pedal release didn't end the note");
} @test

hook_holds_a_jump_until_set :: () {
    track: [..] u8;
    add_jump(*track, 480, hook = 1, chunk = 1, measure = 1, beat = 1, tick = 0);  // At beat 2.
    add_end_of_track(*track, 480);
    play_tracks(track);
    song := get_first_player().song;

    run(TICKS_PER_SECOND / 2 + 2);
    check(get_first_player().jumps == 0, "jumped without its hook");

    play_tracks(track);
    song = get_first_player().song;
    imuse_set_hook(song, 1);
    run(TICKS_PER_SECOND / 2 + 2);
    check(get_first_player().jumps == 1 && get_first_player().hook == 0, "% jumps, hook %", get_first_player().jumps, get_first_player().hook);
    run(TICKS_PER_SECOND / 2);
    check(get_first_player().jumps == 1, "jumped again after the hook was used");
} @test

hook_0x80_skips_one_plain_jump :: () {
    track: [..] u8;
    add_jump(*track, 480, hook = 0, chunk = 1, measure = 1, beat = 1, tick = 0);
    add_end_of_track(*track, 480);
    play_tracks(track);
    imuse_set_hook(get_first_player().song, 0x80);

    run(TICKS_PER_SECOND / 2 + 2);
    check(get_first_player().jumps == 0 && get_first_player().hook == 0, "% jumps, hook %", get_first_player().jumps, get_first_player().hook);
    run(TICKS_PER_SECOND);
    check(imuse_get_status().player_count == 0, "the song didn't run on to its end");
} @test

triggers_match_markers :: () {
    track: [..] u8;
    add_sysex(*track, 0,  .[0x7D, 0, 5, 0xF7]);                                     // Id 5.
    add_sysex(*track, 10, .[0x7D, 0, 6, 0xF7]);                                     // Id 6.
    add_sysex(*track, 10, .[0x7D, 3, #char "t", #char "o", #char " ", #char "A", 0, 0xF7]);
    add_end_of_track(*track, 1920);
    play_tracks(track);
    song := get_first_player().song;
    trigger_log.count = 0;

    imuse_set_trigger(song, 6, log_marker);
    imuse_set_trigger(song, MARKER_TEXT, log_marker);
    imuse_set_trigger(song, 0, log_marker);  // Takes the first marker, then it's used up.
    check(imuse_count_triggers(song) == 3, "% triggers set", imuse_count_triggers(song));
    run(TICKS_PER_SECOND / 4);

    check(trigger_log.count == 3, "% triggers fired", trigger_log.count);
    if trigger_log.count == 3 {
        check(trigger_log.markers[0] == 5, "any-marker trigger got %", trigger_log.markers[0]);
        check(trigger_log.markers[1] == 6, "id trigger got %", trigger_log.markers[1]);
        check(trigger_log.markers[2] == MARKER_TEXT && trigger_log.text == "to A", "text trigger got % '%'", trigger_log.markers[2], trigger_log.text);
    }
    check(imuse_count_triggers() == 0, "triggers still set after firing");
    check(to_string(get_first_player().marker.data) == "to A" && get_first_player().marker_id == MARKER_TEXT, "last marker is '%'", to_string(get_first_player().marker.data));
} @test

trigger_can_stop_its_song :: () {
    load_fm_driver();
    track: [..] u8;
    add_message(*track, 0, 0xC0, 1);
    add_note(*track, 0, 0x90, 60, 100);
    add_sysex(*track, 10, .[0x7D, 0, 1, 0xF7]);
    add_note(*track, 0, 0x90, 64, 100);  // Never plays: the song stops first.
    add_end_of_track(*track, 1920);
    play_tracks(track);
    imuse_set_trigger(get_first_player().song, 1, stop_marked_song);

    run(4);
    check(imuse_get_status().player_count == 0, "the song kept playing");
    check(count_voices_on(0) == 0, "notes kept sounding");
} @test

delayed_stop_counts_frames :: () {
    track: [..] u8;
    add_end_of_track(*track, 1920 * 8);
    play_tracks(track);
    song := get_first_player().song;

    // 15 frames of 16667 us end in the 37th interrupt of 6944 us.
    check(imuse_stop(song, 15), "no delayed stop free");
    run(36);
    check(imuse_get_status().player_count == 1, "stopped early");
    run(1);
    check(imuse_get_status().player_count == 0, "didn't stop after 15 frames");
} @test

fade_to_zero_stops_the_song :: () {
    track: [..] u8;
    add_end_of_track(*track, 1920 * 16);
    play_tracks(track);
    song := get_first_player().song;

    // 127 down to 0 in 120 frames: one step a frame, plus the 7 left over spread out, applied
    // every sixth frame. Frame 54 ends in interrupt 130, frame 60 in 145, frame 120 in 289.
    check(imuse_fade_volume(song, 0, 120), "couldn't start the fade");
    run(144);
    check(get_first_player().volume == 70, "volume % after 54 frames", get_first_player().volume);
    run(1);
    check(get_first_player().volume == 64, "volume % after 60 frames", get_first_player().volume);
    run(288 - 145);
    check(imuse_get_status().player_count == 1, "stopped before the fade ended");
    run(1);
    check(imuse_get_status().player_count == 0, "still playing after fading to 0");
} @test

// Key 60 sounds from tick 0 to 480; the song jumps to chunk 2 at tick 240, which the 37th
// interrupt reaches (at tick 246).
make_held_note_song :: (sustain: u8, restrike_at := -1) -> [..] u8, [..] u8 {
    song: [..] u8;
    add_message(*song, 0, 0xC0, 1);
    add_note(*song, 0, 0x90, 60, 100);
    add_jump(*song, 240, hook = 0, chunk = 2, measure = 1, beat = 1, tick = 0, sustain = sustain);
    add_note(*song, 240, 0x80, 60, 0);
    add_end_of_track(*song, 1920);
    target: [..] u8;
    if restrike_at >= 0 {
        add_note(*target, restrike_at, 0x90, 60, 100);
        add_note(*target, 1000, 0x80, 60, 0);
    }
    add_end_of_track(*target, 1920 * 4);
    return song, target;
}

note_rings_on_through_a_sustained_jump :: () {
    load_fm_driver();
    song, target := make_held_note_song(sustain = 1);
    play_tracks(song, target);

    // The note-off lies 234 ticks past the jump: about 35 interrupts at 6.67 ticks each.
    run(37);
    check(get_first_player().jumps == 1, "didn't jump");
    check(is_key_sounding(0, 60) && get_first_player().sustained == 1, "the note didn't ring on");
    run(29);
    check(is_key_sounding(0, 60), "the note ended early");
    run(10);
    check(!is_key_sounding(0, 60) && get_first_player().sustained == 0, "the note didn't end at its note-off");
} @test

restrike_cuts_a_sustained_note :: () {
    load_fm_driver();
    // Chunk 2 strikes the key again at its tick 120: the held note ends 10 ticks before, so the
    // new note isn't cut when the old note-off would have come.
    song, target := make_held_note_song(sustain = 1, restrike_at = 120);
    play_tracks(song, target);
    run(37 + 45);
    check(is_key_sounding(0, 60), "the restruck note was cut");
    check(get_first_player().sustained == 0, "the held note still rings on");
} @test

plain_jump_cuts_notes :: () {
    load_fm_driver();
    song, target := make_held_note_song(sustain = 0);
    play_tracks(song, target);
    run(37);
    check(get_first_player().jumps == 1 && !is_key_sounding(0, 60), "the note survived the jump");
} @test

shared_parts_take_over_channels :: () {
    load_fm_driver();
    old: [..] u8;
    for part: u8.[0, 1]  add_message(*old, 0, 0xC0 | part, 1);
    add_note(*old, 0, 0x90, 60, 100);
    add_end_of_track(*old, 1920 * 8);
    new: [..] u8;
    for part: u8.[0, 1]  add_message(*new, 0, 0xC0 | part, 2);
    add_note(*new, 0, 0x91, 64, 100);
    add_end_of_track(*new, 1920 * 8);

    imuse_init();
    a := play_song("OLD", 64, old);
    run(1);
    b := play_song("NEW", 64, new);
    check(imuse_share_parts(a, b), "couldn't share");
    check(!imuse_share_parts(a, b), "shared twice");
    run(1);

    for part: 0..1 {
        pa, pb := get_player(a).parts[part], get_player(b).parts[part];
        check(pa.channel >= 0 && pb.channel == pa.channel && pb.shared, "part %: old on %, new on % (shared %)", part, pa.channel, pb.channel, pb.shared);
    }
    check(is_key_sounding(get_player(b).parts[1].channel, 64), "the new song's note isn't sounding");

    channel := get_player(b).parts[0].channel;
    imuse_stop(a);
    check(get_player(b).parts[0].channel == channel, "the new song moved from channel % to %", channel, get_player(b).parts[0].channel);
    check(!is_key_sounding(channel, 60), "the old song's note outlived it");
} @test

stalk_hands_over_to_fight :: () {
    skip_without_dark();
    mount_retail();
    defer gob_unmount_all();
    load_fm_driver();

    imuse_init();
    stalk := imuse_load_midi("stalk-01");
    fight := imuse_load_midi("fight-01");
    check(stalk && fight && imuse_play(stalk), "couldn't start STALK-01");
    run(TICKS_PER_SECOND * 10);

    // Hand over: start the new song, share parts, stop the old one a quarter second later.
    check(imuse_play(fight) && imuse_share_parts(stalk, fight), "couldn't hand over");
    imuse_stop(stalk, 15);
    run(TICKS_PER_SECOND * 10);

    s := imuse_get_status();
    if !check(s.player_count == 1 && s.players[0].song == fight, "% songs playing", s.player_count)  return;
    used: [16] bool;
    used[MIDI_DRUM_CHANNEL] = true;
    for s.players[0].parts  if it.channel >= 0  used[it.channel] = true;
    for fm_get_voice_state()  check(!it.active || used[it.channel], "voice % stuck on channel %, key %", it_index, it.channel, it.key);
    imuse_stop_all();
} @test

rejects_damaged_files :: () {
    imuse_init();
    track: [..] u8;
    add_end_of_track(*track, 0);
    good := make_gmd(track);

    _, ok := gmd_parse(good);
    check(ok, "rejected a good file");

    bad := array_copy(good);
    bad[0] = #char "X";
    _, ok = gmd_parse(bad);
    check(!ok, "accepted a bad container tag");

    // Claim two tracks but hold one.
    bad = array_copy(good);
    bad[41] = 2;  // Low byte of MThd's track count.
    _, ok = gmd_parse(bad);
    check(!ok, "accepted a missing track");

    // Track running past the end.
    bad = array_copy(good);
    bad[50] = 200;  // Third byte of the MTrk length.
    _, ok = gmd_parse(bad);
    check(!ok, "accepted a track past the end");
} @test

all_retail_gmds_parse :: () {
    skip_without_dark();
    mount_retail();
    defer gob_unmount_all();

    count := 0;
    for find_gob_entries_ending(".GMD") {
        _, ok := gmd_parse(it.data);
        check(ok, "% doesn't parse", it.name);
        count += 1;
    }
    check(count == 55, "% GMDs, expected 55", count);
} @test

all_retail_gmds_play :: () {
    skip_without_dark();
    mount_retail();
    defer gob_unmount_all();

    imuse_init();
    for find_gob_entries_ending(".GMD") {
        song := imuse_load_midi(path_strip_extension(it.name));
        check(song && imuse_play(song), "% won't start", it.name);
        notes := 0;
        for 1..TICKS_PER_SECOND * 30 {
            imuse_tick();
            if imuse_get_status().player_count  notes = get_first_player().notes;
        }
        check(notes > 0 || it.name == "TEMP.GMD", "% played no notes in 30 s", it.name);
        imuse_unload_all();
    }
} @test

stalk_01_loops :: () {
    skip_without_dark();
    mount_retail();
    defer gob_unmount_all();

    imuse_init();
    song := imuse_load_midi("stalk-01");
    check(song && imuse_play(song), "couldn't start STALK-01");
    run(TICKS_PER_SECOND * 150);
    if !check(imuse_get_status().player_count == 1, "STALK-01 stopped")  return;
    s := get_first_player();
    print("    STALK-01 after 150 s: chunk %, at %.%.%, % jumps, % notes, marker '%'\n",
          s.chunk, s.measure, s.beat, s.tick, s.jumps, s.notes, to_string(s.marker.data));
    check(s.jumps == 2, "% jumps, expected the intro skip and one loop", s.jumps);
    imuse_stop_all();
} @test

// ---- Digital sounds.

FRAMES :: IMUSE_DIGITAL_FRAMES;

digital_sound_ends_after_its_samples :: () {
    imuse_init();
    voc := make_voc(FRAMES + 100, loop = false);
    defer array_free(voc);
    check(imuse_start_digital(IMUSE_DIGITAL_FIRST, voc, 64), "didn't start");
    mix_frames(FRAMES);
    check(imuse_is_digital_playing(IMUSE_DIGITAL_FIRST), "ended in the first buffer");
    // The end is found when the next buffer wants more.
    mix_frames(FRAMES);
    mix_frames(FRAMES);
    check(!imuse_is_digital_playing(IMUSE_DIGITAL_FIRST), "still playing after its samples");
} @test

digital_loop_repeats_forever :: () {
    imuse_init();
    voc := make_voc(100, loop = true);
    defer array_free(voc);
    imuse_start_digital(IMUSE_DIGITAL_FIRST, voc, 64);
    mix_frames(FRAMES * 20);
    check(imuse_is_digital_playing(IMUSE_DIGITAL_FIRST), "the loop ended");
} @test

digital_unknown_block_ends_sound :: () {
    imuse_init();
    voc := make_voc(100, loop = false);
    defer array_free(voc);
    voc[26] = 2;    // Sound continuation: not a block iMUSE plays.
    check(!imuse_start_digital(IMUSE_DIGITAL_FIRST, voc, 64), "started on a block it can't play");
} @test

digital_tracks_are_taken_by_priority :: () {
    imuse_init();
    voc := make_voc(100, loop = true);
    defer array_free(voc);
    for 0..IMUSE_TRACKS-1  imuse_start_digital(IMUSE_DIGITAL_FIRST + cast(s32) it, voc, 64);
    check(!imuse_start_digital(IMUSE_DIGITAL_FIRST + 100, voc, 63), "a lower priority took a track");
    check(imuse_start_digital(IMUSE_DIGITAL_FIRST + 101, voc, 64), "an equal priority found no track");
    // The oldest of the lowest goes.
    check(!imuse_is_digital_playing(IMUSE_DIGITAL_FIRST), "the oldest still plays");
    check(imuse_is_digital_playing(IMUSE_DIGITAL_FIRST + 1), "the second oldest went");
    imuse_stop_all();
    check(!imuse_is_digital_playing(IMUSE_DIGITAL_FIRST + 101), "stop all left a digital sound");
} @test

digital_fade_moves_every_sixth_frame :: () {
    imuse_init();
    voc := make_voc(100, loop = true);
    defer array_free(voc);
    id := IMUSE_DIGITAL_FIRST;
    imuse_start_digital(id, voc, 64);
    imuse_set_param(id, .VOLUME, 120);
    // 120 to 0 over 12 frames: 10 a frame, applied when the frames left are a multiple of 6.
    check(imuse_fade_param(id, .VOLUME, 0, 12), "fade refused");
    run_frames(5);
    volume := imuse_get_param(id, .VOLUME);
    check(volume == 120, "after 5 frames at %, expected 120", volume);
    run_frames(1);
    volume = imuse_get_param(id, .VOLUME);
    check(volume == 60, "after 6 frames at %, expected 60", volume);
    run_frames(6);
    check(!imuse_is_digital_playing(id), "a fade to 0 didn't stop the sound");
} @test

digital_mix_pans_and_clips :: () {
    skip_without_dark();
    imuse_init();
    if !check(imuse_load_digital_tables(find_dark_data_dir()), "tables didn't load")  return;
    voc := make_voc(FRAMES, loop = true, value = 255);
    defer array_free(voc);
    id := IMUSE_DIGITAL_FIRST;
    imuse_start_digital(id, voc, 64);
    out := mix_frames(FRAMES);
    check(out[0] == out[1] && out[0] > 128, "centered: % %", out[0], out[1]);
    // Pan 127 with the retail setup (mono, sides swapped): all on the second byte.
    imuse_set_param(id, .PAN, 127);
    out = mix_frames(FRAMES);
    check(out[0] == 128 && out[1] > 128, "panned: % %", out[0], out[1]);
    // Two sounds sum through the soft clip, under twice one.
    imuse_set_param(id, .PAN, 64);
    one := mix_frames(FRAMES)[0];
    imuse_start_digital(id + 1, voc, 64);
    two := mix_frames(FRAMES)[0];
    check(two > one && two - 128 < 2 * (one - 128), "one % two %", one, two);
} @test

#scope_file

// A VOC: the header, a repeat block if looping, one block of samples, an end-repeat, the end.
make_voc :: (samples: int, loop: bool, value: u8 = 200) -> [..] u8 {
    voc: [..] u8;
    for "Creative Voice File\x1A"  array_add(*voc, it);
    array_add(*voc, 0x1A, 0, 0x0A, 0x01, 0x29, 0x11);
    if loop  array_add(*voc, 6, 2, 0, 0, 0xFF, 0xFF);
    size := samples + 2;
    array_add(*voc, 1, cast,trunc(u8) size, cast,trunc(u8) (size >> 8), cast,trunc(u8) (size >> 16), 0xA5, 0);
    for 1..samples  array_add(*voc, value);
    if loop  array_add(*voc, 7, 0, 0, 0);
    array_add(*voc, 0);
    return voc;
}

mix_frames :: (frames: int) -> [] u8 {
    out := NewArray(frames * 2, u8,, temp);
    imuse_mix_digital(out);
    return out;
}

// 60 Hz frames on the interrupt clock.
run_frames :: (frames: int) {
    ticks := (frames * 16667 + IMUSE_TICK_US - 1) / IMUSE_TICK_US;
    for 1..ticks  imuse_tick();
}


run :: (ticks: int) {
    for 1..ticks  imuse_tick();
}

trigger_log: struct {
    markers: [8] int;
    count:   int;
    text:    string;
};

log_marker :: (song: Imuse_Song, marker: Imuse_Marker) {
    if trigger_log.count == trigger_log.markers.count return;
    trigger_log.markers[trigger_log.count] = marker.id;
    trigger_log.count += 1;
    if marker.id == MARKER_TEXT  trigger_log.text = marker.text;
}

stop_marked_song :: (song: Imuse_Song, marker: Imuse_Marker) {
    imuse_stop(song);
}

// For tests that check which FM voices sound.
load_fm_driver :: () #expand {
    skip_without_dark();
    if !fm_driver.loaded  assert(fm_load_driver(find_dark_data_dir()));
}

// Starts from a clean iMUSE.
play_tracks :: (tracks: .. [..] u8) {
    imuse_init();
    play_song("TEST", 64, ..tracks);
}

play_song :: (name: string, priority: int, tracks: .. [..] u8) -> Imuse_Song {
    song := imuse_load_midi_from_memory(name, make_gmd(..tracks));
    ok := imuse_play(song, priority);
    assert(ok);
    return song;
}

// The most recently started song.
get_first_player :: () -> Imuse_Player_State {
    s := imuse_get_status();
    assert(s.player_count > 0);
    return s.players[0];
}

get_player :: (song: Imuse_Song) -> *Imuse_Player_State {
    s := New(Imuse_Status, initialized = false,, temp);
    s.* = imuse_get_status();
    for * s.players  if it.song == song  return it;
    return null;
}

count_parts_with_channels :: (p: *Imuse_Player_State) -> int {
    n := 0;
    for p.parts  if it.channel >= 0  n += 1;
    return n;
}

is_key_sounding :: (channel: int, key: int) -> bool {
    for fm_get_voice_state()  if it.active && it.channel == channel && it.key == key  return true;
    return false;
}

count_voices_on :: (channel: int) -> int {
    n := 0;
    for fm_get_voice_state()  if it.active && it.channel == channel  n += 1;
    return n;
}

make_gmd :: (tracks: .. [..] u8) -> [] u8 {
    body: [..] u8;
    append_tag(*body, "MDpg"); append_be(*body, 14, 4);
    for 1..14  array_add(*body, 0);
    append_tag(*body, "MThd"); append_be(*body, 6, 4);
    append_be(*body, 2, 2); append_be(*body, xx tracks.count, 2); append_be(*body, 480, 2);
    for tracks {
        append_tag(*body, "MTrk"); append_be(*body, xx it.count, 4);
        array_add(*body, ..it);
    }
    data: [..] u8;
    append_tag(*data, "MIDI"); append_be(*data, xx body.count, 4);
    array_add(*data, ..body);
    return data;
}

add_note :: (track: *[..] u8, delta: int, status: u8, key: u8, velocity: u8) {
    append_vlq(track, delta);
    array_add(track, status, key, velocity);
}

add_message :: (track: *[..] u8, delta: int, status: u8, data1: u8) {
    append_vlq(track, delta);
    array_add(track, status, data1);
}

add_control :: (track: *[..] u8, delta: int, channel: u8, controller: u8, value: u8) {
    add_note(track, delta, 0xB0 | channel, controller, value);
}

add_tempo :: (track: *[..] u8, delta: int, us_per_beat: int) {
    append_vlq(track, delta);
    array_add(track, 0xFF, 0x51, 3);
    append_be(track, xx us_per_beat, 3);
}

add_end_of_track :: (track: *[..] u8, delta: int) {
    append_vlq(track, delta);
    array_add(track, 0xFF, 0x2F, 0);
}

add_sysex :: (track: *[..] u8, delta: int, body: [] u8) {
    append_vlq(track, delta);
    array_add(track, 0xF0);
    append_vlq(track, body.count);
    array_add(track, ..body);
}

add_jump :: (track: *[..] u8, delta: int, hook: u8, chunk: u8, measure: int, beat: u8, tick: int, sustain: u8 = 0) {
    add_sysex(track, delta, .[0x7D, 1, hook, chunk, xx (measure >> 7), xx (measure & 0x7F), beat,
                          xx (tick >> 7), xx (tick & 0x7F), sustain, 0xF7]);
}

append_tag :: (bytes: *[..] u8, tag: string) {
    for 0..3  array_add(bytes, tag[it]);
}

append_be :: (bytes: *[..] u8, value: u32, size: int) {
    for < 0..size-1  array_add(bytes, cast,trunc(u8) (value >> (it * 8)));
}

append_vlq :: (bytes: *[..] u8, value: int) {
    groups: [4] u8;
    n := 0;
    v := value;
    while true {
        groups[n] = cast(u8) (v & 0x7F);
        n += 1;
        v >>= 7;
        if !v break;
    }
    for < i: 0..n-1  array_add(bytes, groups[i] | ifx i then cast(u8) 0x80 else 0);
}

mount_retail :: () {
    gob_unmount_all();
    dir := find_dark_data_dir();
    ok := gob_mount_retail(dir);
    assert(ok);
}

find_gob_entries_ending :: (suffix: string) -> [..] Archive_Entry {
    result: [..] Archive_Entry;
    for archive: mounted_gobs  for archive.entries  if ends_with(it.name, suffix) array_add(*result, it);
    return result;
}

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfFm";
#import "engine/dfIMuse";
