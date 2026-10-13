// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

KEYON_BLOCK :: 0xB0;
LEFT        :: 0x100;  // Offset of the left register set.

driver_loads_from_imuse_exe :: () {
    skip_without_dark();
    check(fm_load_driver(find_dark_data_dir()), "couldn't load FM4.MDR's tables");
    d := *fm_driver;
    // Spot checks of the shape of each table.
    check(d.velocity_to_volume[0] == 0 && d.velocity_to_volume[63] == 63, "velocity table runs % to %", d.velocity_to_volume[0], d.velocity_to_volume[63]);
    check(d.carrier_offset[0] == d.modulator_offset[0] + 3, "carrier isn't 3 past the modulator");
    for 1..d.freq_index_to_pitch.count-1  if d.freq_index_to_pitch[it] < d.freq_index_to_pitch[it - 1] && d.freq_index_to_pitch[it] * 2 > d.freq_index_to_pitch[it - 1] {
        check(false, "pitch table drops at %", it);
        break;
    }
    for 1..127  if d.key_to_block[it] < d.key_to_block[it - 1] {
        check(false, "block table drops at key %", it + 7);
        break;
    }
} @test

notes_start_and_stop :: () {
    start_fm();
    fm_send_midi(0xC0, 0);
    fm_send_midi(0x90, 60, 100);

    voice := find_voice(0, 60);
    check(voice >= 0, "no voice plays channel 0 key 60");
    if voice < 0 return;
    right := fm_get_register(xx (KEYON_BLOCK + voice));
    left  := fm_get_register(xx (KEYON_BLOCK + voice + LEFT));
    check(right & 0x20 && left & 0x20, "key-on not set on both sides: % %", right, left);
    check(right == left, "sides disagree on frequency: % %", right, left);

    fm_send_midi(0x80, 60, 0);
    check(!fm_get_voice_state()[voice].active, "voice still active after note off");
    check(fm_get_register(xx (KEYON_BLOCK + voice)) & 0x20 == 0, "key-on still set after note off");
    check(fm_get_register(xx (KEYON_BLOCK + voice)) & 0x1F == right & 0x1F, "note off changed the frequency");
} @test

octave_is_one_block :: () {
    start_fm();
    fm_send_midi(0x90, 60, 100);
    fm_send_midi(0x90, 72, 100);
    a, b := find_voice(0, 60), find_voice(0, 72);
    check(a >= 0 && b >= 0, "notes didn't get voices");
    if a < 0 || b < 0 return;

    block_a := (fm_get_register(xx (KEYON_BLOCK + a)) >> 2) & 7;
    block_b := (fm_get_register(xx (KEYON_BLOCK + b)) >> 2) & 7;
    fnum_a  := get_fnum(a);
    fnum_b  := get_fnum(b);
    check(block_b == block_a + 1, "blocks % and % aren't an octave apart", block_a, block_b);
    check(fnum_a == fnum_b, "f-numbers differ an octave apart: % %", fnum_a, fnum_b);
} @test

tenth_note_steals :: () {
    start_fm();
    for 0..FM_VOICE_COUNT-1  fm_send_midi(0x90, xx (48 + it), 100);
    check(count_active_voices() == FM_VOICE_COUNT, "expected all voices active");
    fm_send_midi(0x90, 80, 100);
    check(count_active_voices() == FM_VOICE_COUNT, "voice count changed after stealing");
    check(find_voice(0, 80) >= 0, "the tenth note didn't get a voice");
} @test

priority_protects_voices :: () {
    start_fm();
    // Channel 1 reserves all its notes, so only priority decides.
    fm_send_midi(0xB1, MIDI_CC_NOTE_REQ, FM_VOICE_COUNT);
    fm_send_midi(0xB1, MIDI_CC_PRIORITY, 10);
    for 0..FM_VOICE_COUNT-1  fm_send_midi(0x91, xx (48 + it), 100);
    fm_send_midi(0x90, 80, 100);  // Channel 0 has priority 0.
    check(find_voice(0, 80) < 0, "a lower-priority channel stole a voice");

    fm_send_midi(0xB0, MIDI_CC_PRIORITY, 20);
    fm_send_midi(0x90, 81, 100);
    check(find_voice(0, 81) >= 0, "a higher-priority channel couldn't steal");
} @test

over_reserved_voices_go_first :: () {
    start_fm();
    // Channel 1 outranks channel 0 but plays more notes than it reserved.
    fm_send_midi(0xB1, MIDI_CC_PRIORITY, 10);
    for 0..FM_VOICE_COUNT-1  fm_send_midi(0x91, xx (48 + it), 100);
    fm_send_midi(0x90, 80, 100);
    check(find_voice(0, 80) >= 0, "couldn't steal from an over-reserved channel");
} @test

drum_key_picks_drum_timbre :: () {
    start_fm();
    key :: 35;  // Acoustic bass drum.
    fm_send_midi(0x99, key, 100);
    voice := find_voice(MIDI_DRUM_CHANNEL, key);
    check(voice >= 0, "drum note didn't get a voice");
    if voice < 0 return;

    timbre := cast(int) cast,no_check(s8) fm_driver.key_to_drum_timbre[key] + 128;
    expected := fm_driver.timbres_right[timbre * 12 + 10] | 0x20;
    got := fm_get_register(xx (0xC0 + voice));
    check(timbre >= 128 && got == expected, "feedback register % for timbre %, expected %", got, timbre, expected);
} @test

volume_zero_mutes_carrier :: () {
    start_fm();
    fm_send_midi(0x90, 60, 127);
    voice := find_voice(0, 60);
    if voice < 0 { check(false, "no voice"); return; }
    carrier := 0x40 + fm_driver.carrier_offset[voice];

    check(fm_get_register(xx carrier) & 0x3F < 0x3F, "carrier fully attenuated at full volume");
    fm_send_midi(0xB0, MIDI_CC_VOLUME, 0);
    check(fm_get_register(xx carrier) & 0x3F == 0x3F, "carrier not attenuated at volume 0");
    check(fm_get_register(xx (carrier + LEFT)) & 0x3F == 0x3F, "left carrier not attenuated at volume 0");
} @test

note_sounds_then_releases :: () {
    start_fm();
    fm_send_midi(0xC0, 0);
    fm_send_midi(0x90, 60, 127);
    on_peak := measure_peak(FM_SAMPLE_RATE / 4);
    fm_send_midi(0x80, 60, 0);
    measure_peak(FM_SAMPLE_RATE * 3);
    off_peak := measure_peak(FM_SAMPLE_RATE / 10);
    check(on_peak > 1000, "note on is too quiet: peak %", on_peak);
    check(off_peak < 50, "still sounding 3 s after note off: peak %", off_peak);
} @test

all_notes_off_frees_voices :: () {
    start_fm();
    for 0..4  fm_send_midi(0x90, xx (60 + it), 100);
    fm_stop_all_notes();
    check(count_active_voices() == 0, "% voices still active", count_active_voices());
    for 0..FM_VOICE_COUNT-1  check(fm_get_register(xx (KEYON_BLOCK + it)) & 0x20 == 0, "voice % still keyed on", it);
} @test

bend_retunes_sounding_notes :: () {
    start_fm();
    fm_send_midi(0x90, 62, 100);  // Reference: what D sounds like.
    reference := find_voice(0, 62);
    if !check(reference >= 0, "no voice for the reference note")  return;
    fnum, block := get_fnum(reference), get_block(reference);
    fm_send_midi(0x80, 62, 0);

    fm_send_midi(0x90, 60, 100);
    voice := find_voice(0, 60);
    if !check(voice >= 0, "no voice for C")  return;
    // The driver takes (bend - 0x2000) / 2 as 1/256 semitones: 0x2400 is 2 up.
    fm_send_midi(0xE0, 0, 0x48);
    check(get_fnum(voice) == fnum && get_block(voice) == block, "bent C is %/%, D is %/%", get_fnum(voice), get_block(voice), fnum, block);
    check(fm_get_register(xx (KEYON_BLOCK + voice)) & 0x20 != 0, "the bend released the note");

    fm_send_midi(0x80, 60, 0);
    fm_send_midi(0x90, 60, 100);  // Starts bent.
    voice = find_voice(0, 60);
    check(voice >= 0 && get_fnum(voice) == fnum && get_block(voice) == block, "a new note didn't start bent");
} @test

drum_channel_ignores_bends :: () {
    start_fm();
    fm_send_midi(0x99, 36, 100);
    voice := find_voice(9, 36);
    if !check(voice >= 0, "no drum voice")  return;
    before := get_fnum(voice);
    fm_send_midi(0xE9, 0, 0x48);
    check(get_fnum(voice) == before, "the drum was bent");
} @test

#scope_file

// Every test needs the game's FM driver tables.
start_fm :: () #expand {
    skip_without_dark();
    if !fm_driver.loaded  assert(fm_load_driver(find_dark_data_dir()));
    fm_reset();
}

find_voice :: (channel: int, key: int) -> int {
    for fm_get_voice_state()  if it.active && it.channel == channel && it.key == key  return it_index;
    return -1;
}

count_active_voices :: () -> int {
    count := 0;
    for fm_get_voice_state()  if it.active count += 1;
    return count;
}

get_fnum :: (voice: int) -> int {
    return ((cast(int) fm_get_register(xx (KEYON_BLOCK + voice)) & 3) << 8) | fm_get_register(xx (0xA0 + voice));
}

measure_peak :: (frames: int) -> int {
    buffer: [1024] s16;
    peak := 0;
    remaining := frames;
    while remaining > 0 {
        n := min(remaining, buffer.count / 2);
        fm_generate(array_view(buffer, 0, n * 2));
        for 0..n*2-1  peak = max(peak, abs(cast(int) buffer[it]));
        remaining -= n;
    }
    return peak;
}

get_block :: (voice: int) -> int {
    return (fm_get_register(xx (KEYON_BLOCK + voice)) >> 2) & 7;
}

#import "Basic";
#import "Math";
#import "engine/dfArchive";
#import "engine/dfFm";
