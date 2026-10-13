// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

pal_expands_6_bit :: () {
    data: [768] u8;
    data[0] = 63; data[1] = 32; data[2] = 1;
    palette, ok := pal_parse(data);
    check(ok, "PAL rejected");
    c := palette.colors[0];
    check(c.r == 255 && c.g == 130 && c.b == 4, "6-bit expansion gave % % %", c.r, c.g, c.b);
    _, ok = pal_parse(.[1, 2, 3]);
    check(!ok, "accepted a short PAL");
} @test

pltt_updates_its_range :: () {
    palette: Palette;
    palette.colors[9] = .{1, 1, 1};
    ok := pltt_apply(*palette, .[10, 11, 200, 100, 50, 7, 8, 9, 0]);
    check(ok, "PLTT rejected");
    check(palette.colors[9].r == 1, "touched an entry before the range");
    check(palette.colors[10].r == 200 && palette.colors[10].b == 50, "entry 10 wrong");
    check(palette.colors[11].g == 8, "entry 11 wrong");
    check(!pltt_apply(*palette, .[10, 20, 1, 2, 3]), "accepted a short PLTT");
} @test

bm_reads_columns_bottom_up :: () {
    // 2x3: column 0 is 1,2,3 from the bottom, column 1 is 4,5,6.
    data := make_bm(2, 3, 0x3E, .[1, 2, 3, 4, 5, 6]);
    defer array_free(data);
    texture, ok := bm_parse(data);
    defer texture_free(*texture);
    if !check(ok && texture.frames.count == 1, "BM rejected")  return;
    image := texture.frames[0];
    check(image.width == 2 && image.height == 3, "size % x %", image.width, image.height);
    expected :: u8.[3, 6, 2, 5, 1, 4];
    check(array_equal(image.pixels, expected), "pixels %", image.pixels);
    check(texture.transparent, "flag 0x08 not read as transparent");
    check(!texture.animated, "single BM marked animated");
} @test

bm_unpacks_compressed :: () {
    // 1x6 type 1: a run of three 7s, then 2 literal bytes, then a run of one 9.
    packed :: u8.[0x83, 7, 2, 4, 5, 0x81, 9];
    bytes: [..] u8;
    defer array_free(bytes);
    append_bm_header(*bytes, 1, 6, 0x36, compression = 1, packed_size = packed.count);
    for packed array_add(*bytes, it);
    append_u32(*bytes, 0);
    texture, ok := bm_parse(bytes);
    defer texture_free(*texture);
    if !check(ok, "compressed BM rejected")  return;
    expected :: u8.[9, 5, 4, 7, 7, 7];
    check(array_equal(texture.frames[0].pixels, expected), "type 1 pixels %", texture.frames[0].pixels);

    // Type 2: runs are transparent and carry no value byte, so the same bytes read as a gap of
    // three, then a literal run cut short at the top of the column.
    bytes[14] = 2;
    texture2, ok2 := bm_parse(bytes);
    defer texture_free(*texture2);
    if !check(ok2, "type 2 BM rejected")  return;
    expected2 :: u8.[5, 4, 2, 0, 0, 0];
    check(array_equal(texture2.frames[0].pixels, expected2), "type 2 pixels %", texture2.frames[0].pixels);

    // A column offset past the data.
    put_u32(bytes, bytes.count - 4, 100);
    _, bad := bm_parse(bytes);
    check(!bad, "accepted a column offset past the data");
} @test

bm_reads_animated :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    append_bm_header(*bytes, 1, 0, 0x36, marker = -2, count = 2);
    array_add(*bytes, 10, 2);
    table := bytes.count;
    append_u32(*bytes, 0);
    append_u32(*bytes, 0);
    for frame: 0..1 {
        put_u32(bytes, table + frame * 4, xx (bytes.count - table));
        start := bytes.count;
        for 0..27  array_add(*bytes, 0);
        put_u16(bytes, start, 1);
        put_u16(bytes, start + 2, 2);
        bytes[start + 0x18] = 0x3E;
        array_add(*bytes, cast(u8) (frame * 2 + 1));
        array_add(*bytes, cast(u8) (frame * 2 + 2));
    }
    texture, ok := bm_parse(bytes);
    defer texture_free(*texture);
    if !check(ok, "animated BM rejected")  return;
    check(texture.animated && texture.frame_rate == 10, "animated % rate %", texture.animated, texture.frame_rate);
    check(texture.frames.count == 2, "% frames", texture.frames.count);
    check(texture.transparent, "frame flags not read");
    if texture.frames.count == 2 {
        check(texture.frames[1].pixels[0] == 4 && texture.frames[1].pixels[1] == 3, "frame 1 pixels %", texture.frames[1].pixels);
    }
} @test

fme_reads_frame_and_compressed_cell :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    append_u32(*bytes, cast,no_check(u32) -3);  // Insert x.
    append_u32(*bytes, 5);
    append_u32(*bytes, 1);                      // Flipped.
    append_u32(*bytes, 32);                     // Cell.
    for 0..15  array_add(*bytes, 0);
    // A 2x4 compressed cell: column 0 is two literal pixels and a gap of two; column 1 a gap of
    // one and three literals.
    append_u32(*bytes, 2);
    append_u32(*bytes, 4);
    append_u32(*bytes, 1);
    append_u32(*bytes, 0);
    append_u32(*bytes, 0);
    append_u32(*bytes, 0);
    append_u32(*bytes, 32);
    append_u32(*bytes, 37);
    array_add(*bytes, 0x02, 8, 9, 0x82, 0);
    array_add(*bytes, 0x81, 0x03, 1, 2, 3);

    sprite, ok := fme_parse(bytes);
    defer sprite_free(*sprite);
    if !check(ok, "FME rejected")  return;
    frame := sprite.actions[0].views[0].frames[0];
    check(frame.insert_x == -3 && frame.insert_y == 5 && frame.flip, "frame % % %", frame.insert_x, frame.insert_y, frame.flip);
    cell := sprite.cells[frame.cell];
    expected :: u8.[0, 3, 0, 2, 9, 1, 8, 0];
    check(array_equal(cell.pixels, expected), "cell pixels %", cell.pixels);
} @test

wax_shares_cells_and_stops_at_null :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    for 0..32 + 32 * 4 - 1  array_add(*bytes, 0);
    action := bytes.count;
    put_u32(bytes, 32, xx action);
    for 0..28 + 32 * 4 - 1  array_add(*bytes, 0);
    put_u32(bytes, action, 0x20000);
    put_u32(bytes, action + 8, 7);
    view := bytes.count;
    put_u32(bytes, action + 28, xx view);
    put_u32(bytes, action + 32, xx view);   // Two views, the same list.
    for 0..16 + 32 * 4 - 1  array_add(*bytes, 0);
    frame := bytes.count;
    put_u32(bytes, view + 16, xx frame);
    put_u32(bytes, view + 20, xx frame);
    // A null, then an entry the game never reaches.
    put_u32(bytes, view + 28, xx frame);
    for 0..31  array_add(*bytes, 0);
    cell := bytes.count;
    put_u32(bytes, frame + 12, xx cell);
    append_u32(*bytes, 1);
    append_u32(*bytes, 1);
    for 0..15  array_add(*bytes, 0);
    array_add(*bytes, 42);

    sprite, ok := wax_parse(bytes);
    defer sprite_free(*sprite);
    if !check(ok, "WAX rejected")  return;
    check(sprite.actions.count == 1, "% actions", sprite.actions.count);
    a := sprite.actions[0];
    check(a.world_width == 0x20000 && a.frame_rate == 7, "action size % rate %", a.world_width, a.frame_rate);
    check(a.views.count == 2, "% views", a.views.count);
    check(a.views[0].frames.count == 2, "% frames, expected the list to stop at the null", a.views[0].frames.count);
    check(sprite.cells.count == 1 && sprite.cells[0].pixels[0] == 42, "cells not shared");
} @test

fnt_reads_glyphs :: () {
    bytes: [..] u8;
    defer array_free(bytes);
    append_string(*bytes, "FNT\x15");
    array_add(*bytes, 2, 0, 0, 0, #char "A", #char "B");
    for 0..21  array_add(*bytes, 0);
    array_add(*bytes, 1, 5, 6);
    array_add(*bytes, 2, 1, 2, 3, 4);
    font, ok := fnt_parse(bytes);
    defer font_free(*font);
    if !check(ok && font.glyphs.count == 2, "FNT rejected")  return;
    check(font.first == #char "A" && font.height == 2, "first % height %", font.first, font.height);
    check(font.glyphs[1].width == 2 && array_equal(font.glyphs[1].pixels, u8.[2, 4, 1, 3]), "glyph B %", font.glyphs[1].pixels);
} @test

retail_graphics_parse :: () {
    skip_without_dark();
    gob_unmount_all();
    defer gob_unmount_all();
    if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs")  return;

    counts: struct { pal, cmp, bm, animated, fme, wax, fnt: int; };
    for archive: mounted_gobs {
        for archive.entries {
            ext := path_extension(it.name);
            if ext == {
                case "PAL";
                    _, ok := pal_parse(it.data);
                    check(ok, "% failed", it.name);
                    counts.pal += 1;
                case "CMP";
                    _, ok := cmp_parse(it.data);
                    check(ok, "% failed", it.name);
                    counts.cmp += 1;
                case "BM";
                    texture, ok := bm_parse(it.data);
                    check(ok && texture.frames.count > 0, "% failed", it.name);
                    if texture.animated counts.animated += 1;
                    texture_free(*texture);
                    counts.bm += 1;
                case "FME";
                    sprite, ok := fme_parse(it.data);
                    check(ok, "% failed", it.name);
                    sprite_free(*sprite);
                    counts.fme += 1;
                case "WAX";
                    sprite, ok := wax_parse(it.data);
                    check(ok && sprite.cells.count > 0, "% failed", it.name);
                    sprite_free(*sprite);
                    counts.wax += 1;
                case "FNT";
                    font, ok := fnt_parse(it.data);
                    check(ok && font.glyphs.count > 0, "% failed", it.name);
                    font_free(*font);
                    counts.fnt += 1;
            }
        }
    }
    check(counts.pal == 15 && counts.cmp == 14, "% PALs, % CMPs", counts.pal, counts.cmp);
    check(counts.bm == 893 && counts.animated == 18, "% BMs, % animated", counts.bm, counts.animated);
    check(counts.fme == 59 && counts.wax == 64 && counts.fnt == 7, "% FMEs, % WAXs, % FNTs", counts.fme, counts.wax, counts.fnt);

    // The stormtrooper: walking, attacking, dying, ... and 32 views of walking.
    data, found := gob_find("STORMFIN.WAX");
    if !check(found, "STORMFIN.WAX missing")  return;
    trooper, ok := wax_parse(data);
    defer sprite_free(*trooper);
    check(ok && trooper.actions.count >= 7, "STORMFIN.WAX: % actions", trooper.actions.count);
    if ok  check(trooper.actions[0].views.count == 32, "% views of walking", trooper.actions[0].views.count);
} @test

#scope_file

make_bm :: (width: int, height: int, flags: u8, columns: [] u8) -> [..] u8 {
    bytes: [..] u8;
    append_bm_header(*bytes, width, height, flags);
    for columns array_add(*bytes, it);
    return bytes;
}

append_bm_header :: (bytes: *[..] u8, width: int, height: int, flags: u8, compression: u8 = 0, packed_size := 0, marker := 0, count := 0) {
    append_string(bytes, "BM \x1E");
    append_u16(bytes, width);
    append_u16(bytes, height);
    append_u16(bytes, marker);
    append_u16(bytes, count);
    array_add(bytes, flags, 0, compression, 0);
    append_u32(bytes, xx packed_size);
    for 0..11  array_add(bytes, 0);
}

array_equal :: (a: [] u8, b: [] u8) -> bool {
    if a.count != b.count return false;
    return memcmp(a.data, b.data, a.count) == 0;
}

append_string :: (bytes: *[..] u8, s: string) {
    for 0..s.count-1  array_add(bytes, s[it]);
}

append_u16 :: (bytes: *[..] u8, v: int) {
    array_add(bytes, cast,trunc(u8) v, cast,trunc(u8) (v >> 8));
}

append_u32 :: (bytes: *[..] u8, v: u32) {
    for 0..3  array_add(bytes, cast,trunc(u8) (v >> (it * 8)));
}

put_u16 :: (bytes: [] u8, at: int, v: int) {
    bytes[at] = cast,trunc(u8) v;
    bytes[at + 1] = cast,trunc(u8) (v >> 8);
}

put_u32 :: (bytes: [] u8, at: int, v: u32) {
    for 0..3  bytes[at + it] = cast,trunc(u8) (v >> (it * 8));
}

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
