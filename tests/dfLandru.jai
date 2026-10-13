// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

delt_draws_lines :: () {
    bytes := make_delt();
    defer array_free(bytes);
    delt, ok := delt_parse(bytes);
    defer delt_free(*delt);
    if !check(ok, "DELT rejected")  return;
    check(delt.x == 10 && delt.y == 20 && delt.image.width == 4 && delt.image.height == 2, "rect % % % %", delt.x, delt.y, delt.image.width, delt.image.height);
    // Row 0: a plain line of 3 from x 11. Row 1: a run of two 9s then one literal 0.
    expected_pixels :: u8.[0, 1, 2, 3, 9, 9, 0, 0];
    expected_opaque :: bool.[false, true, true, true, true, true, true, false];
    check(memcmp(delt.image.pixels.data, expected_pixels.data, 8) == 0, "pixels %", delt.image.pixels);
    check(memcmp(delt.opaque.data, expected_opaque.data, 8) == 0, "mask %", delt.opaque);
} @test

delt_rejects_truncation :: () {
    bytes := make_delt();
    defer array_free(bytes);
    bytes.count -= 3;
    delt, ok := delt_parse(bytes);
    delt_free(*delt);
    check(!ok, "accepted a truncated DELT");
} @test

anim_reads_frames :: () {
    delt := make_delt();
    defer array_free(delt);
    bytes: [..] u8;
    defer array_free(bytes);
    append_u16(*bytes, 2);
    for 0..1 {
        append_u16(*bytes, delt.count);
        append_u16(*bytes, 0);
        for delt array_add(*bytes, it);
    }
    anim, ok := anim_parse(bytes);
    defer anim_free(*anim);
    check(ok && anim.frames.count == 2, "ANIM: ok %, % frames", ok, anim.frames.count);
} @test

lfd_font_reads_rows :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    for v: s32.[0x41, 2, 16, 2, 0, 0]  append_u16(*bytes, v);
    array_add(*bytes, 3, 9);
    array_add(*bytes, 0x80, 0x00, 0x40, 0x00);
    array_add(*bytes, 0xFF, 0x80, 0x00, 0x01);
    font, ok := lfd_font_parse(bytes);
    defer lfd_font_free(*font);
    if !check(ok, "FONT rejected")  return;
    check(font.first == 0x41 && font.height == 2 && font.widths.count == 2 && font.widths[1] == 9, "header % % %", font.first, font.height, font.widths);
    check(font.rows.count == 4 && font.rows[2] == 0xFF80 && font.rows[3] == 0x0001, "rows %", font.rows);
} @test

retail_lfd_graphics_parse :: () {
    skip_without_dark();
    counts: struct { delt, anim, font, pltt: int; };
    for path: file_list(tprint("%/LFD", find_dark_data_dir())) {
        archive, ok := archive_open(path);
        if !check(ok, "% didn't open", path) continue;
        defer archive_close(archive);
        for archive.entries {
            ext := path_extension(it.name);
            if ext == {
                case "DELT";
                    delt, ok := delt_parse(it.data);
                    check(ok, "% in % failed", it.name, path);
                    delt_free(*delt);
                    counts.delt += 1;
                case "ANIM";
                    anim, ok := anim_parse(it.data);
                    check(ok && anim.frames.count > 0, "% in % failed", it.name, path);
                    anim_free(*anim);
                    counts.anim += 1;
                case "FONT";
                    font, ok := lfd_font_parse(it.data);
                    check(ok, "% in % failed", it.name, path);
                    lfd_font_free(*font);
                    counts.font += 1;
                case "PLTT";
                    palette: Palette;
                    check(pltt_apply(*palette, it.data), "% in % failed", it.name, path);
                    counts.pltt += 1;
            }
        }
    }
    check(counts.delt == 122 && counts.anim == 126 && counts.font == 3 && counts.pltt == 82, "counts %", counts);
} @test

#scope_file

// Rect (10, 20)-(13, 21). A plain line of 3 at (11, 20); a coded line of 3 at (10, 21): a run
// of two 9s, then one literal 0.
make_delt :: () -> [..] u8 {
    bytes: [..] u8;
    for v: s32.[10, 20, 13, 21]  append_u16(*bytes, v);
    for v: s32.[3 << 1, 11, 20]  append_u16(*bytes, v);
    array_add(*bytes, 1, 2, 3);
    for v: s32.[(3 << 1) | 1, 10, 21]  append_u16(*bytes, v);
    array_add(*bytes, (2 << 1) | 1, 9);
    array_add(*bytes, 1 << 1, 0);
    append_u16(*bytes, 0);
    return bytes;
}

append_u16 :: (bytes: *[..] u8, v: s64) {
    array_add(bytes, cast,trunc(u8) v);
    array_add(bytes, cast,trunc(u8) (v >> 8));
}

#import "Basic";
#import "File_Utilities";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/dfLandru";
