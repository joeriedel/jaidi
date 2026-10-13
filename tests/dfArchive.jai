// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

gob_parses :: () {
    archive := make_archive(.GOB, make_gob(.[.{"SECBASE.LEV", "level"}, .{"BAR.voc", "sound"}]));
    defer archive_close(archive);

    check(archive.entries.count == 2, "expected 2 entries, got %", archive.entries.count);
    entry := archive_find(archive, "secbase.lev");
    check(entry != null, "SECBASE.LEV not found by lower-case name");
    if entry check(cast(string) entry.data == "level", "SECBASE.LEV data is '%'", cast(string) entry.data);
    entry = archive_find(archive, "BAR.VOC");
    check(entry && entry.name == "BAR.VOC", "names are stored upper case");
    check(archive_find(archive, "MISSING.LEV") == null, "found a missing name");
} @test

gob_rejects_damage :: () {
    good := make_gob(.[.{"A.TXT", "abc"}]);
    defer array_free(good);

    bad_magic := array_copy(good);
    bad_magic[0] = #char "X";
    check(!is_valid_archive(.GOB, bad_magic), "accepted a bad magic");

    // Directory offset past the end.
    bad_dir := array_copy(good);
    put_u32(bad_dir, 4, xx bad_dir.count);
    check(!is_valid_archive(.GOB, bad_dir), "accepted a directory past the end");

    // Entry running past the end.
    bad_entry := array_copy(good);
    dir := get_u32(bad_entry, 4);
    put_u32(bad_entry, dir + 8, 1000);
    check(!is_valid_archive(.GOB, bad_entry), "accepted an entry past the end");

    // More entries than the directory has room for.
    bad_count := array_copy(good);
    put_u32(bad_count, dir, 1000);
    check(!is_valid_archive(.GOB, bad_count), "accepted an oversized entry count");

    check(!is_valid_archive(.GOB, .[]), "accepted an empty buffer");
} @test

lfd_parses :: () {
    archive := make_archive(.LFD, make_lfd(.[.{"ANIM", "logo", "frames"}, .{"PLTT", "LOGO", "palette"}]));
    defer archive_close(archive);

    check(archive.entries.count == 2, "expected 2 entries, got %", archive.entries.count);
    entry := archive_find(archive, "logo.anim");
    check(entry && cast(string) entry.data == "frames", "LOGO.ANIM missing or wrong");
    entry = archive_find(archive, "LOGO.PLTT");
    check(entry && cast(string) entry.data == "palette", "LOGO.PLTT missing or wrong");
} @test

lfd_rejects_damage :: () {
    good := make_lfd(.[.{"FILM", "INTRO", "script"}]);
    defer array_free(good);

    bad_rmap := array_copy(good);
    put_u32(bad_rmap, 12, 17);
    check(!is_valid_archive(.LFD, bad_rmap), "accepted an RMAP length that isn't a multiple of 16");

    // The repeated header must match the RMAP entry.
    bad_header := array_copy(good);
    bad_header[32 + 4] = #char "X";
    check(!is_valid_archive(.LFD, bad_header), "accepted a mismatched resource header");

    truncated := array_copy(good);
    truncated.count -= 1;
    check(!is_valid_archive(.LFD, truncated), "accepted a truncated resource");
} @test

gob_shadows :: () {
    gob_unmount_all();
    defer gob_unmount_all();

    original := make_archive(.GOB, make_gob(.[.{"SECBASE.LEV", "original"}, .{"SECBASE.O", "objects"}]));
    mod      := make_archive(.GOB, make_gob(.[.{"SECBASE.LEV", "modded"}]));
    gob_mount_archive(original);
    gob_mount_archive(mod);

    data, found := gob_find("SECBASE.LEV");
    check(found && cast(string) data == "modded", "the later GOB doesn't shadow the earlier one");
    entry, from := gob_find_entry("secbase.o");
    check(entry && from == original, "a file only in the original doesn't fall through");
    _, found = gob_find("NOPE.LEV");
    check(!found, "found a missing name");
} @test

retail_gobs_mount :: () {
    skip_without_dark();
    dir := find_dark_data_dir();
    gob_unmount_all();
    defer gob_unmount_all();

    check(gob_mount_retail(dir), "couldn't mount the retail GOBs");
    expected :: int.[139, 302, 894, 123];
    for mounted_gobs {
        check(it.entries.count == expected[it_index], "% has % entries, expected %", it.path, it.entries.count, expected[it_index]);
    }
    _, found := gob_find("SECBASE.LEV");
    check(found, "SECBASE.LEV not found");
    entry, from := gob_find_entry("STALK-01.GMD");
    check(entry && ends_with(from.path, "SOUNDS.GOB"), "STALK-01.GMD not found in SOUNDS.GOB");
} @test

retail_lfds_open :: () {
    skip_without_dark();
    dir := find_dark_data_dir();

    files := file_list(tprint("%/LFD", dir));
    check(files.count == 44, "expected 44 LFDs, found %", files.count);
    for files {
        archive, ok := archive_open(it);
        check(ok && archive.kind == .LFD, "% didn't open as an LFD", it);
        archive_close(archive);
    }
} @test

retail_imuse_exe_opens :: () {
    skip_without_dark();
    archive, ok := archive_open(tprint("%/IMUSE.EXE", find_dark_data_dir()));
    if !check(ok && archive.kind == .IMUSE, "IMUSE.EXE didn't open as an iMUSE archive")  return;
    defer archive_close(archive);
    check(archive.entries.count == 38, "% entries, expected 38", archive.entries.count);
    for name: string.["IMUSE.ENG", "FM4.MDR", "GMIDI.MDR", "SB16.WDR"] {
        entry := archive_find(archive, name);
        check(entry && entry.data.count > 2 && entry.data[0] == #char "M" && entry.data[1] == #char "Z", "% is missing or isn't a module", name);
    }

    // Cut short, the directory no longer fits.
    contents, read := read_entire_file(tprint("%/IMUSE.EXE", find_dark_data_dir()));
    assert(read);
    bytes := cast([] u8) contents;
    bytes.count -= 10;
    cut: Archive;
    check(!archive_parse(*cut, .IMUSE, bytes), "accepted a truncated IMUSE.EXE");
    free(contents);
} @test

#scope_file

Gob_File :: struct { name: string; data: string; }
Lfd_File :: struct { type: string; name: string; data: string; }

make_gob :: (files: [] Gob_File) -> [..] u8 {
    bytes: [..] u8;
    append_string(*bytes, "GOB\n");
    append_u32(*bytes, 0);  // Directory offset, patched below.
    offsets: [..] u32;
    defer array_free(offsets);
    for files {
        array_add(*offsets, xx bytes.count);
        append_string(*bytes, it.data);
    }
    put_u32(bytes, 4, xx bytes.count);
    append_u32(*bytes, xx files.count);
    for files {
        append_u32(*bytes, offsets[it_index]);
        append_u32(*bytes, xx it.data.count);
        append_padded(*bytes, it.name, 13);
    }
    return bytes;
}

make_lfd :: (files: [] Lfd_File) -> [..] u8 {
    bytes: [..] u8;
    append_string(*bytes, "RMAP");
    append_padded(*bytes, "resource", 8);
    append_u32(*bytes, xx (files.count * 16));
    for files  append_lfd_header(*bytes, it);
    for files {
        append_lfd_header(*bytes, it);
        append_string(*bytes, it.data);
    }
    return bytes;
}

append_lfd_header :: (bytes: *[..] u8, file: Lfd_File) {
    append_padded(bytes, file.type, 4);
    append_padded(bytes, file.name, 8);
    append_u32(bytes, xx file.data.count);
}

// The archive owns the bytes, so hand it a heap copy.
make_archive :: (kind: Archive_Kind, bytes: [..] u8) -> *Archive {
    archive := New(Archive);
    ok := archive_parse(archive, kind, bytes);
    assert(ok);
    return archive;
}

is_valid_archive :: (kind: Archive_Kind, bytes: [] u8) -> bool {
    archive: Archive;
    ok := archive_parse(*archive, kind, bytes);
    for archive.entries free(it.name);
    array_free(archive.entries);
    array_free(bytes);
    return ok;
}

append_string :: (bytes: *[..] u8, s: string) {
    for 0..s.count-1  array_add(bytes, s[it]);
}

append_padded :: (bytes: *[..] u8, s: string, size: int) {
    for 0..size-1  array_add(bytes, ifx it < s.count then s[it] else 0);
}

append_u32 :: (bytes: *[..] u8, v: u32) {
    for 0..3  array_add(bytes, cast,trunc(u8) (v >> (it * 8)));
}

put_u32 :: (bytes: [] u8, at: int, v: u32) {
    for 0..3  bytes[at + it] = cast,trunc(u8) (v >> (it * 8));
}

get_u32 :: (bytes: [] u8, at: int) -> int {
    return bytes[at] | ((cast(int) bytes[at + 1]) << 8) | ((cast(int) bytes[at + 2]) << 16) | ((cast(int) bytes[at + 3]) << 24);
}

#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "engine/dfArchive";
