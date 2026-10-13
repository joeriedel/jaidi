// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// GOB and LFD archives, the archive of sound modules appended to IMUSE.EXE, and the set of
// mounted GOBs the game loads its files from.
//
// Archives are read into memory whole and entries are slices of those bytes. The retail GOBs
// come to about 32 MB; in return there are no file handles or seeks, reads are safe from any
// thread, and the parsers work on plain bytes.

Archive_Kind :: enum u8 { GOB; LFD; IMUSE; }

Archive_Entry :: struct {
    name: string;   // Upper case. GOB: "SECBASE.LEV". LFD: "NAME.TYPE", e.g. "LOGO.ANIM".
                    // IMUSE: "FM4.MDR".
    data: [] u8;    // Slice of Archive.bytes.
}

Archive :: struct {
    path:    string;
    kind:    Archive_Kind;
    bytes:   [] u8;
    entries: [..] Archive_Entry;
}

// Parses an archive's directory from bytes the archive takes ownership of. Every offset and
// length is checked against the buffer, so a damaged or hostile file fails cleanly.
archive_parse :: (archive: *Archive, kind: Archive_Kind, bytes: [] u8) -> bool {
    archive.kind  = kind;
    archive.bytes = bytes;
    ok: bool;
    if kind == {
        case .GOB;   ok = parse_gob(archive);
        case .LFD;   ok = parse_lfd(archive);
        case .IMUSE; ok = parse_imuse(archive);
    }
    if !ok free_entries(archive);
    return ok;
}

// Reads a file and parses it, telling the kinds apart by their first bytes.
archive_open :: (path: string) -> *Archive, bool {
    contents, read_ok := read_entire_file(path, log_errors = false);
    if !read_ok {
        log_error("Can't read archive '%'.", path);
        return null, false;
    }
    bytes := cast([] u8) contents;

    kind: Archive_Kind;
    if      has_tag(bytes, 0, GOB_MAGIC) kind = .GOB;
    else if has_tag(bytes, 0, LFD_RMAP)  kind = .LFD;
    else if has_tag(bytes, 0, EXE_MAGIC) kind = .IMUSE;
    else {
        log_error("'%' isn't an archive.", path);
        free(contents);
        return null, false;
    }

    archive := New(Archive);
    archive.path = copy_string(path);
    if !archive_parse(archive, kind, bytes) {
        log_error("'%' has a damaged % directory.", path, kind);
        archive_close(archive);
        return null, false;
    }
    return archive, true;
}

archive_close :: (archive: *Archive) {
    if !archive return;
    free_entries(archive);
    array_free(archive.entries);
    free(archive.bytes.data);
    free(archive.path);
    free(archive);
}

archive_find :: (archive: *Archive, name: string) -> *Archive_Entry {
    for * archive.entries  if equal_nocase(it.name, name) return it;
    return null;
}

// Mounted GOBs in mount order. Lookups go newest first, so a GOB mounted after the retail ones
// shadows any file it shares a name with and leaves the rest to the originals.
mounted_gobs: [..] *Archive;

RETAIL_GOBS :: string.["DARK.GOB", "SOUNDS.GOB", "TEXTURES.GOB", "SPRITES.GOB"];

gob_mount :: (path: string) -> bool {
    archive, ok := archive_open(path);
    if !ok return false;
    if archive.kind != .GOB {
        log_error("'%' is not a GOB.", path);
        archive_close(archive);
        return false;
    }
    gob_mount_archive(archive);
    return true;
}

// Takes ownership of an already parsed GOB.
gob_mount_archive :: (archive: *Archive) {
    assert(archive.kind == .GOB);
    array_add(*mounted_gobs, archive);
}

gob_mount_retail :: (dark_dir: string) -> bool {
    for RETAIL_GOBS {
        if !gob_mount(tprint("%/%", dark_dir, it)) return false;
    }
    return true;
}

gob_unmount_all :: () {
    for mounted_gobs archive_close(it);
    array_reset(*mounted_gobs);
}

gob_find :: (name: string) -> [] u8, bool {
    entry := gob_find_entry(name);
    if !entry return .[], false;
    return entry.data, true;
}

// Also returns the archive that supplies the entry.
gob_find_entry :: (name: string) -> *Archive_Entry, *Archive {
    for < mounted_gobs {
        entry := archive_find(it, name);
        if entry return entry, it;
    }
    return null, null;
}

// The retail data lives in dark/: next to bin/ when the program runs, and under the repo root
// when tests run at compile time. The program can set its own (a ship build's DARK), so that
// everything reading LFDs uses the folder the GOBs were mounted from.
find_dark_data_dir :: () -> string, bool {
    dir := dark_data_dir;
    if !dir {
        if #compile_time {
            dir = "dark";
        } else {
            dir = tprint("%../dark", path_strip_filename(get_path_of_running_executable()));
        }
    }
    return dir, file_exists(tprint("%/DARK.GOB", dir));
}

set_dark_data_dir :: (dir: string) {
    free(dark_data_dir);
    dark_data_dir = copy_string(dir);
}

Lx_Image :: struct {
    base:  int;
    bytes: [] u8;
}

// A module from IMUSE.EXE's archive mapped into memory: its one object at its base address,
// where the original's code finds its tables. Fixups aren't applied: tables read through it
// must hold no pointers. The bytes are temporary storage.
lx_map_object :: (module: [] u8) -> Lx_Image, bool {
    image: Lx_Image;
    if module.count < 0x40 return image, false;
    lx := cast(int) read_lx_u32(module, 0x3C);
    if lx + 0x84 > module.count || module[lx] != #char "L" || module[lx + 1] != #char "X"  return image, false;

    page_size   := cast(int) read_lx_u32(module, lx + 0x28);
    page_shift  := cast(int) read_lx_u32(module, lx + 0x2C);
    objects     := lx + cast(int) read_lx_u32(module, lx + 0x40);
    page_table  := lx + cast(int) read_lx_u32(module, lx + 0x48);
    data_pages  := cast(int) read_lx_u32(module, lx + 0x80);
    if read_lx_u32(module, lx + 0x44) != 1 || objects + 24 > module.count  return image, false;

    size        := cast(int) read_lx_u32(module, objects);
    image.base   = cast(int) read_lx_u32(module, objects + 4);
    first_page  := cast(int) read_lx_u32(module, objects + 12);
    page_count  := cast(int) read_lx_u32(module, objects + 16);
    if page_size <= 0 || size > 1 << 20  return image, false;

    // Past the last page the object is zeros (uninitialized data).
    image.bytes = NewArray(max(page_count * page_size, size), u8,, temp);
    for page: 0..page_count-1 {
        entry := page_table + (first_page + page - 1) * 8;
        if entry + 8 > module.count return image, false;
        offset := data_pages + ((cast(int) read_lx_u32(module, entry)) << page_shift);
        length := (cast(int) module[entry + 4]) | ((cast(int) module[entry + 5]) << 8);
        if length > page_size || offset + length > module.count return image, false;
        memcpy(image.bytes.data + page * page_size, module.data + offset, length);
    }
    image.bytes.count = size;
    return image, true;
}

// The game's DARK.EXE mapped into memory (le_map_image), when it is the one this program
// knows: the tables read from it are at known addresses. The bytes are temporary storage.
dark_exe_map :: (dark_dir: string) -> Lx_Image, bool {
    path := tprint("%/DARK.EXE", dark_dir);
    contents, read_ok := read_entire_file(path, log_errors = false);
    if !read_ok {
        log_error("Can't read '%'.", path);
        return .{}, false;
    }
    defer free(contents);
    bytes := cast([] u8) contents;
    if fnv1a_hash(bytes.data, bytes.count) != DARK_EXE_HASH {
        log_error("'%' isn't the DARK.EXE this program knows.", path);
        return .{}, false;
    }
    image, mapped := le_map_image(bytes);
    if !mapped  log_error("'%' is damaged.", path);
    return image, mapped;
}

lx_read_u8 :: (image: Lx_Image, address: int) -> u8 {
    return image.bytes[address - image.base];
}

lx_read_u32 :: (image: Lx_Image, address: int) -> u32 {
    o := address - image.base;
    b := image.bytes;
    return (cast(u32) b[o]) | ((cast(u32) b[o + 1]) << 8) | ((cast(u32) b[o + 2]) << 16) | ((cast(u32) b[o + 3]) << 24);
}

// A DOS/4GW executable (DARK.EXE, LE) mapped into memory: every object at its base address,
// gaps and uninitialized data zeros, the image starting at the lowest base. As with
// lx_map_object, fixups aren't applied, so only tables holding no pointers can be read
// through it. The bytes are temporary storage.
le_map_image :: (exe: [] u8) -> Lx_Image, bool {
    image: Lx_Image;
    if exe.count < 0x40 || !has_tag(exe, 0, EXE_MAGIC) return image, false;
    le := cast(int) read_lx_u32(exe, 0x3C);
    if le + 0x84 > exe.count || !has_tag(exe, le, "LE") return image, false;

    page_count   := cast(int) read_lx_u32(exe, le + 0x14);
    page_size    := cast(int) read_lx_u32(exe, le + 0x28);
    last_page    := cast(int) read_lx_u32(exe, le + 0x2C);
    objects      := le + cast(int) read_lx_u32(exe, le + 0x40);
    object_count := cast(int) read_lx_u32(exe, le + 0x44);
    page_map     := le + cast(int) read_lx_u32(exe, le + 0x48);
    data_pages   := cast(int) read_lx_u32(exe, le + 0x80);
    if page_size <= 0 || object_count <= 0 || objects + object_count * 24 > exe.count  return image, false;

    low, high := 0x7fff_ffff_ffff_ffff, 0;
    for 0..object_count-1 {
        at := objects + it * 24;
        size  := cast(int) read_lx_u32(exe, at);
        base  := cast(int) read_lx_u32(exe, at + 4);
        pages := cast(int) read_lx_u32(exe, at + 16);
        low  = min(low, base);
        high = max(high, base + max(size, pages * page_size));
    }
    if high - low > 1 << 24  return image, false;

    image.base  = low;
    image.bytes = NewArray(high - low, u8,, temp);
    for 0..object_count-1 {
        at := objects + it * 24;
        base       := cast(int) read_lx_u32(exe, at + 4);
        first_page := cast(int) read_lx_u32(exe, at + 12);
        pages      := cast(int) read_lx_u32(exe, at + 16);
        for page: 0..pages-1 {
            // LE page map entries: a 24-bit page number, high byte first, then a flags byte.
            entry := page_map + (first_page + page - 1) * 4;
            if entry + 4 > exe.count return image, false;
            number := ((cast(int) exe[entry]) << 16) | ((cast(int) exe[entry + 1]) << 8) | exe[entry + 2];
            length := ifx number == page_count then last_page else page_size;
            offset := data_pages + (number - 1) * page_size;
            if number < 1 || length > page_size || offset + length > exe.count return image, false;
            memcpy(image.bytes.data + base - low + page * page_size, exe.data + offset, length);
        }
    }
    return image, true;
}

#scope_file

dark_data_dir: string;

GOB_MAGIC :: "GOB\n";
LFD_RMAP  :: "RMAP";

// u32 offset, u32 length, char[13] name, packed.
GOB_ENTRY_SIZE :: 21;
GOB_NAME_SIZE  :: 13;

// char[4] type, char[8] name, u32 length.
LFD_HEADER_SIZE :: 16;

EXE_MAGIC   :: "MZ";
IMUSE_MAGIC :: "MUSE";

// "MUSE", u32 (unknown), u32 directory offset, u32 entry count, two 20-character timestamps.
IMUSE_HEADER_SIZE :: 0x38;

// char[8] name, char[3] extension, u8 (unknown), u32 offset from the header, u32 length.
IMUSE_ENTRY_SIZE :: 20;

parse_gob :: (archive: *Archive) -> bool {
    bytes := archive.bytes;
    if bytes.count < 8 || !has_tag(bytes, 0, GOB_MAGIC) return false;

    dir: s64 = read_u32(bytes, 4);
    if dir + 4 > bytes.count return false;
    count: s64 = read_u32(bytes, dir);
    if count > (bytes.count - dir - 4) / GOB_ENTRY_SIZE return false;

    for i: 0..count-1 {
        at := dir + 4 + i * GOB_ENTRY_SIZE;
        offset: s64 = read_u32(bytes, at);
        length: s64 = read_u32(bytes, at + 4);
        if offset + length > bytes.count return false;

        entry := array_add(*archive.entries);
        entry.name = copy_upper(read_fixed_string(bytes, at + 8, GOB_NAME_SIZE));
        entry.data = array_view(bytes, offset, length);
    }
    return true;
}

// IMUSE.EXE (the sound setup program) carries the iMUSE engine and the sound drivers in an
// archive appended to its LE executable, starting at the first 16-byte boundary after the
// executable's last page: a "MUSE" header, the modules, then the directory, which ends the file.
parse_imuse :: (archive: *Archive) -> bool {
    bytes := archive.bytes;
    if bytes.count < 0x40 || !has_tag(bytes, 0, EXE_MAGIC) return false;
    le: s64 = read_u32(bytes, 0x3C);
    if le + 0x84 > bytes.count || !has_tag(bytes, le, "LE") return false;

    pages:     s64 = read_u32(bytes, le + 0x14);
    page_size: s64 = read_u32(bytes, le + 0x28);
    last_page: s64 = read_u32(bytes, le + 0x2C);
    data:      s64 = read_u32(bytes, le + 0x80);
    if pages == 0 || page_size > 1 << 16 || last_page > page_size return false;
    header := (data + (pages - 1) * page_size + last_page + 15) & ~15;
    if header + IMUSE_HEADER_SIZE > bytes.count || !has_tag(bytes, header, IMUSE_MAGIC) return false;

    dir:   s64 = header + read_u32(bytes, header + 8);
    count: s64 = read_u32(bytes, header + 12);
    if dir > bytes.count || count > (bytes.count - dir) / IMUSE_ENTRY_SIZE return false;

    for i: 0..count-1 {
        at := dir + i * IMUSE_ENTRY_SIZE;
        offset: s64 = header + read_u32(bytes, at + 12);
        length: s64 = read_u32(bytes, at + 16);
        if offset + length > bytes.count return false;

        name := read_fixed_string(bytes, at, 8);
        ext  := read_fixed_string(bytes, at + 8, 3);
        entry := array_add(*archive.entries);
        entry.name = ifx ext then sprint("%.%", name, ext) else copy_string(name);
        to_upper_in_place(entry.name);
        entry.data = array_view(bytes, offset, length);
    }
    return true;
}

// The RMAP lists every resource; each resource then follows with the same header repeated.
parse_lfd :: (archive: *Archive) -> bool {
    bytes := archive.bytes;
    if bytes.count < LFD_HEADER_SIZE || !has_tag(bytes, 0, LFD_RMAP) return false;

    rmap_length: s64 = read_u32(bytes, 12);
    if rmap_length % LFD_HEADER_SIZE != 0 return false;
    if LFD_HEADER_SIZE + rmap_length > bytes.count return false;

    at := LFD_HEADER_SIZE + rmap_length;
    for i: 0..rmap_length / LFD_HEADER_SIZE - 1 {
        header := LFD_HEADER_SIZE + i * LFD_HEADER_SIZE;
        length: s64 = read_u32(bytes, header + 12);
        if at + LFD_HEADER_SIZE + length > bytes.count return false;
        if memcmp(bytes.data + header, bytes.data + at, LFD_HEADER_SIZE) != 0 return false;

        type := read_fixed_string(bytes, header, 4);
        name := read_fixed_string(bytes, header + 4, 8);
        entry := array_add(*archive.entries);
        entry.name = sprint("%.%", name, type);
        to_upper_in_place(entry.name);
        entry.data = array_view(bytes, at + LFD_HEADER_SIZE, length);
        at += LFD_HEADER_SIZE + length;
    }
    return true;
}

free_entries :: (archive: *Archive) {
    for archive.entries free(it.name);
    array_reset(*archive.entries);
}

read_u32 :: (bytes: [] u8, at: s64) -> u32 {
    return  (cast(u32) bytes[at])               | ((cast(u32) bytes[at + 1]) << 8) |
           ((cast(u32) bytes[at + 2]) << 16)    | ((cast(u32) bytes[at + 3]) << 24);
}

has_tag :: (bytes: [] u8, at: s64, tag: string) -> bool {
    if at + tag.count > bytes.count return false;
    return memcmp(bytes.data + at, tag.data, tag.count) == 0;
}

// A zero-padded name field; stops at the first zero.
read_fixed_string :: (bytes: [] u8, at: s64, size: s64) -> string {
    s: string;
    s.data = bytes.data + at;
    while s.count < size && s.data[s.count] != 0  s.count += 1;
    return s;
}

copy_upper :: (s: string) -> string {
    result := copy_string(s);
    to_upper_in_place(result);
    return result;
}

DARK_EXE_HASH :: 0x1ca8cc37ecb0eb08;     // Dark Forces 1.0, build 2.

#import "Basic";
#import "File";
#import "Hash";
#import "File_Utilities";
#import "String";
#import "System";

read_lx_u32 :: (bytes: [] u8, at: int) -> u32 {
    return  (cast(u32) bytes[at])            | ((cast(u32) bytes[at + 1]) << 8) |
           ((cast(u32) bytes[at + 2]) << 16) | ((cast(u32) bytes[at + 3]) << 24);
}
