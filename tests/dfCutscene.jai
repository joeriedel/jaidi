// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

cutscene_list_reads_entries :: () {
    text :: #string END
CUT 1.0
CUTS 3
# comment
15:     broken.lfd      broken          x       0       0       0       100
10:	logo.lfd	logo	10	20	0	1	110
20:     swlogo.lfd      swlogo          7       0       5       0       90   # trailing
END
    entries := cutscene_list_parse(text);
    defer cutscene_list_free(*entries);
    if !check(entries.count == 2, "% entries", entries.count)  return;
    a := entries[0];
    check(a.id == 10 && a.archive == "logo.lfd" && a.film == "logo" && a.speed == 10 && a.next == 20 && a.skip == 0 && a.music == 1 && a.volume == 110, "first %", a);
    b := entries[1];
    check(b.id == 20 && b.speed == 7 && b.next == 0 && b.skip == 5 && b.volume == 90, "second %", b);
} @test

cutmuse_reads_cues :: () {
    text :: #string END
// header
SEQUENCE: 1
// cue 1
CUE: star-thm
0 0 0 0    // LucasArts
CUE: star-thm   // comment
B 2 C 7
SEQUENCE: 2
	CUE: execmus
. 0 0 0
END
    sequences := cutmuse_parse(text);
    defer cutmuse_free(*sequences);
    if !check(sequences.count == 2, "% sequences", sequences.count)  return;
    s := sequences[0];
    if !check(s.id == 1 && s.cues.count == 2, "sequence 1: id %, % cues", s.id, s.cues.count)  return;
    c := s.cues[1];
    check(c.song == "star-thm" && c.from_chunk == #char "B" && c.from_measure == 2 && c.to_chunk == #char "C" && c.to_measure == 7, "cue 2 %", c);
    check(sequences[1].cues.count == 1 && sequences[1].cues[0].from_chunk == #char ".", "sequence 2 %", sequences[1]);
} @test

film_reads_objects :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    for s32.[4, 12, 2]  append_u16(*bytes, it);
    // A DELT actor shown at cell 0, moved at cell 3.
    commands: [..] u8;
    defer array_free(commands);
    for s32.[6, 3, 0,  6, 13, 1,  12, 4, 10, 20, 0, 0,  6, 3, 3,  8, 5, 1, 0,  4, 2] append_u16(*commands, it);
    append_object(*bytes, "DELT", "ship", 3, commands);
    // The view, ending at once.
    view: [..] u8;
    defer array_free(view);
    for s32.[4, 2]  append_u16(*view, it);
    append_object(*bytes, "VIEW", "untitled", 2, view);

    film, ok := film_parse(bytes);
    defer film_info_free(*film);
    if !check(ok && film.cell_count == 12 && film.objects.count == 2, "ok %, % cells, % objects", ok, film.cell_count, film.objects.count)  return;
    o := film.objects[0];
    check(o.type == "DELT" && o.name == "ship" && o.block == .ACTOR && o.commands.count == commands.count, "object %", o);
    length, op, args := film_read_command(o.commands, 6);
    check(length == 6 && op == .SHOW && film_get_arg(args, 0) == 1, "second record % % %", length, op, args);
} @test

film_rejects_unterminated_stream :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    for s32.[4, 1, 1]  append_u16(*bytes, it);
    commands: [..] u8;
    defer array_free(commands);
    for s32.[6, 3, 0]  append_u16(*commands, it);
    append_object(*bytes, "DELT", "x", 3, commands);
    film, ok := film_parse(bytes);
    film_info_free(*film);
    check(!ok, "accepted a stream without END");
} @test

delt_draws_clipped_and_flipped :: () {
    // Rectangle 0,0..3,0; one plain line of 4 at (0, 0): 1 2 3 4.
    delt: [..] u8;
    defer array_free(delt);
    for s32.[0, 0, 3, 0,  8, 0, 0]  append_u16(*delt, it);
    array_add(*delt, 1, 2, 3, 4);
    append_u16(*delt, 0);
    check(is_valid_delt(delt), "valid DELT rejected");

    canvas := NewArray(CANVAS_WIDTH * CANVAS_HEIGHT, u8);
    defer array_free(canvas);
    draw_delt(canvas, delt, 10, 5, .{11, 0, 13, CANVAS_HEIGHT});
    row := 5 * CANVAS_WIDTH;
    check(canvas[row + 10] == 0 && canvas[row + 11] == 2 && canvas[row + 12] == 3 && canvas[row + 13] == 0, "clipped: %", array_view(canvas, row + 9, 6));

    memset(canvas.data, 0, canvas.count);
    draw_delt(canvas, delt, 10, 5, CANVAS_RECT, flip = true, mirror = 3);
    check(canvas[row + 10] == 4 && canvas[row + 13] == 1, "flipped: %", array_view(canvas, row + 9, 6));
} @test

retail_lists_parse :: () {
    skip_without_dark();
    dark_dir := find_dark_data_dir();
    if !check(gob_mount_retail(dark_dir), "can't mount the GOBs")  return;
    defer gob_unmount_all();
    if !check(cutscene_init(), "CUTSCENE.LST didn't load")  return;
    defer cutscene_shutdown();
    // The opening's chain, and its music sequence's cues.
    ids: [..] s32;
    defer array_free(ids);
    id: s32 = CUTSCENE_OPENING;
    while id && ids.count < 10 {
        array_add(*ids, id);
        found := false;
        for cutscene_get_list()  if it.id == id { id = it.next; found = true; break; }
        if !found break;
    }
    check(ids.count == 5, "opening chain %", ids);
    sequences := cutscene_get_music_sequences();
    check(sequences.count > 0 && sequences[0].cues.count >= 7, "% sequences", sequences.count);
} @test

retail_opening_plays_through :: () {
    skip_without_dark();
    dark_dir := find_dark_data_dir();
    if !check(gob_mount_retail(dark_dir), "can't mount the GOBs")  return;
    defer gob_unmount_all();
    if !check(cutscene_init(), "CUTSCENE.LST didn't load")  return;
    defer cutscene_shutdown();

    imuse_init();
    if !check(imuse_load_digital_tables(dark_dir), "iMUSE's tables didn't load")  return;

    // Runs the opening on a fake clock, counting the scenes it passes through, checking
    // something shows in each, and mixing its sounds as the audio thread would.
    if !check(cutscene_start(CUTSCENE_OPENING, 0), "the opening didn't start")  return;
    heard: [..] bool;
    defer array_free(heard);
    mixed_frames := 0;
    scenes: [..] s32;
    defer array_free(scenes);
    lit: [..] bool;
    defer array_free(lit);
    now: u64 = 0;
    STEP :: 1_000_000_000 / 60;
    music_checked := false;
    while cutscene_update(now) && now < 600 * 1_000_000_000 {
        // LOGO's first cell sends cue 1, which starts the theme.
        if !music_checked && now > 1_000_000_000 {
            music_checked = true;
            song := imuse_find_midi("star-thm");
            chunk, measure, beat, tick, playing := imuse_get_position(song);
            check(song && playing, "the theme isn't playing (song %)", song);
        }
        id := cutscene_get_scene();
        if !scenes || scenes[scenes.count - 1] != id { array_add(*scenes, id); array_add(*lit, false); array_add(*heard, false); }
        due := cast(int) (now * IMUSE_DIGITAL_RATE / 1_000_000_000);
        if due > mixed_frames {
            out := NewArray((due - mixed_frames) * 2, u8,, temp);
            imuse_mix_digital(out);
            for out  if it != 128 { heard[heard.count - 1] = true; break; }
            mixed_frames = due;
        }
        if !lit[lit.count - 1] {
            palette := cutscene_get_palette();
            for cutscene_get_video() {
                c := palette.colors[it];
                if c.r || c.g || c.b { lit[lit.count - 1] = true; break; }
            }
        }
        now += STEP;
    }
    print("    scenes %, lit %, heard %, % s\n", scenes, lit, heard, now / 1_000_000_000);
    check(scenes.count == 5, "played scenes %", scenes);
    for lit  check(it, "scene % never showed anything", scenes[it_index]);
    // LOGO, 1E and DARKLOGO start sounds; SWLOGO and the crawl have none.
    expected_heard :: bool.[true, false, false, true, true];
    if scenes.count == expected_heard.count {
        for heard  check(it == expected_heard[it_index], "scene %: heard %, expected %", scenes[it_index], it, expected_heard[it_index]);
    }
} @test

#scope_file

append_u16 :: (bytes: *[..] u8, v: s64) {
    array_add(bytes, cast,trunc(u8) v, cast,trunc(u8) (v >> 8));
}

append_object :: (bytes: *[..] u8, type: string, name: string, block: s32, commands: [] u8) {
    for 0..3  array_add(bytes, type[it]);
    for 0..7  array_add(bytes, ifx it < name.count then name[it] else 0);
    size := commands.count + 22;
    for 0..3  array_add(bytes, cast,trunc(u8) (size >> (it * 8)));
    append_u16(bytes, block);
    append_u16(bytes, 0);
    append_u16(bytes, commands.count);
    for commands  array_add(bytes, it);
}

#import "Basic";
#import "engine/dfArchive";
#import "engine/dfCutscene";
#import "engine/dfIMuse";
