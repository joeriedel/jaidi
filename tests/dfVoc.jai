// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

voc_reads_blocks_and_loop :: () {
    bytes := make_voc_header();
    defer array_free(bytes);
    add_block(*bytes, 1, .[165, 0, 1, 2, 3]);       // 1000000 / 91 Hz.
    add_block(*bytes, 6, .[0xFF, 0xFF]);
    add_block(*bytes, 2, .[4, 5]);
    add_block(*bytes, 7, .[]);
    add_block(*bytes, 3, .[1, 0, 165]);             // Two samples of silence.
    array_add(*bytes, 0);

    sound, ok := voc_parse(bytes);
    defer sound_free(*sound);
    if !check(ok, "VOC rejected")  return;
    check(sound.rate == 10989, "rate %", sound.rate);
    check(sound.samples.count == 7 && sound.samples[4] == 5 && sound.samples[6] == 128, "samples %", sound.samples);
    check(sound.loop_start == 3 && sound.loop_end == 5 && sound.loop_count == 0xFFFF, "loop % % %", sound.loop_start, sound.loop_end, sound.loop_count);
} @test

voc_rejects_damage :: () {
    bytes := make_voc_header();
    defer array_free(bytes);
    add_block(*bytes, 1, .[165, 0, 1, 2, 3]);
    bytes[bytes.count - 6] = 50;                    // Block size past the end.
    _, ok := voc_parse(bytes);
    check(!ok, "accepted a block past the end");

    _, ok = voc_parse(.[]);
    check(!ok, "accepted nothing");

    packed := make_voc_header();
    defer array_free(packed);
    add_block(*packed, 1, .[165, 1, 1, 2, 3]);      // 4-bit ADPCM.
    _, ok = voc_parse(packed);
    check(!ok, "accepted a compressed codec");
} @test

retail_sounds_parse :: () {
    skip_without_dark();
    gob_unmount_all();
    defer gob_unmount_all();
    dir := find_dark_data_dir();
    if !check(gob_mount_retail(dir), "couldn't mount the retail GOBs")  return;

    count, looped := 0, 0;
    for mounted_gobs[1].entries {
        if path_extension(it.name) != "VOC" || !it.data.count continue;   // DEFV0000.VOC is empty.
        sound, ok := voc_parse(it.data);
        check(ok, "% failed", it.name);
        if sound.loop_start >= 0 looped += 1;
        sound_free(*sound);
        count += 1;
    }
    check(count == 246, "% VOCs", count);
    check(looped > 0, "no looping sounds");

    archive, ok := archive_open(tprint("%/LFD/JEDISFX.LFD", dir));
    if !check(ok, "JEDISFX.LFD didn't open")  return;
    defer archive_close(archive);
    voices := 0;
    for archive.entries {
        if path_extension(it.name) != "VOIC" continue;
        sound, parsed := voc_parse(it.data);
        check(parsed, "% failed", it.name);
        sound_free(*sound);
        voices += 1;
    }
    check(voices > 0, "no voices in JEDISFX.LFD");
} @test

#scope_file

make_voc_header :: () -> [..] u8 {
    bytes: [..] u8;
    for "Creative Voice File\x1A"  array_add(*bytes, it);
    array_add(*bytes, 26, 0, 0x0A, 0x01, 0x29, 0x11);
    return bytes;
}

add_block :: (bytes: *[..] u8, type: u8, body: [] u8) {
    array_add(bytes, type);
    if type == 0 return;
    array_add(bytes, cast,trunc(u8) body.count, cast,trunc(u8) (body.count >> 8), cast,trunc(u8) (body.count >> 16));
    for body array_add(bytes, it);
}

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfVoc";
