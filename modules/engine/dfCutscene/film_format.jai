// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// FILM, a Landru film: a header (version 4, the length in cells, the object count), then each
// object: its resource type and name (the resource it plays, from the same LFD), its size, a
// block kind, its command count and the byte length of its commands. An END record follows the
// objects.
//
// An object's commands are a stream of records: a length in bytes (header included), an
// opcode, then 16-bit arguments. The stream is cut into cells by TIMESTAMP records and ends
// with END.

FILM_VERSION :: 4;

Film_Block :: enum s16 {
    END     :: 1;
    VIEW    :: 2;
    ACTOR   :: 3;   // DELT, ANIM or CUST.
    PALETTE :: 4;
    SOUND   :: 5;
}

Film_Op :: enum s16 {
    END         :: 2;
    TIMESTAMP   :: 3;
    // Actors.
    POS         :: 4;   // x, y, x fraction, y fraction (1/256 pixel).
    VEL         :: 5;   // Per cell, the same way.
    Z           :: 6;
    STATE       :: 7;   // Frame, fraction.
    STATEV      :: 8;   // Frames per cell, fraction.
    VAR1        :: 9;   // CUST: the music cue.
    VAR2        :: 10;
    CLIP        :: 11;  // Left, top, right, bottom.
    CLIPV       :: 12;
    SHOW        :: 13;
    FLIP        :: 14;  // Horizontal, vertical.
    // Palettes.
    PALETTE_SET :: 15;
    // The view.
    SETRGB      :: 16;  // Bytes: first, last, r, g, b.
    DEFPAL      :: 17;
    FADE        :: 18;  // Screen fade, color fade.
    // Sounds.
    SOUND_START :: 19;
    SOUND_STOP  :: 20;
    VOLUME      :: 21;
    SOUND_FADE  :: 22;
    SOUND_VAR1  :: 23;
    SOUND_VAR2  :: 24;
    SOUND_CMD   :: 25;
    PAN         :: 26;
    PAN_FADE    :: 27;
    SOUND_CMD2  :: 28;
}

Film_Object_Info :: struct {
    type:     string;   // "VIEW", "DELT", "ANIM", "CUST", "PLTT", "VOIC", "GMID".
    name:     string;   // As stored ("untitled" for the view, "custom" for CUST).
    block:    Film_Block;
    commands: [] u8;    // Slice of the FILM's bytes.
}

Film_Info :: struct {
    cell_count: s32;
    objects: [..] Film_Object_Info;
}

film_info_free :: (film: *Film_Info) {
    array_free(film.objects);
    film.* = .{};
}

FILM_HEADER_SIZE :: 6;
FILM_OBJECT_HEADER_SIZE :: 22;

// Names and types point into 'data', which must outlive the result. Every command stream is
// checked to end with END, its records within it, so stepping through it needs no checks.
film_parse :: (data: [] u8) -> Film_Info, bool {
    film: Film_Info;
    if data.count < FILM_HEADER_SIZE || get_s16(data, 0) != FILM_VERSION return film, false;
    film.cell_count = get_s16(data, 2);
    count := get_s16(data, 4);
    if count < 0 return film, false;

    at := FILM_HEADER_SIZE;
    for 0..count-1 {
        if at + FILM_OBJECT_HEADER_SIZE > data.count { film_info_free(*film); return film, false; }
        object: Film_Object_Info;
        object.type  = read_name(data, at, 4);
        object.name  = read_name(data, at + 4, 8);
        object.block = cast(Film_Block) get_s16(data, at + 16);
        used := get_s16(data, at + 20);
        at += FILM_OBJECT_HEADER_SIZE;
        if used < 0 || at + used > data.count { film_info_free(*film); return film, false; }
        object.commands = array_view(data, at, used);
        at += used;
        if !is_valid_stream(object.commands) { film_info_free(*film); return film, false; }
        array_add(*film.objects, object);
    }
    return film, true;
}

// The record at 'at': its length, opcode and arguments.
film_read_command :: (commands: [] u8, at: s64) -> length: s32, op: Film_Op, args: [] u8 {
    length := get_s16(commands, at);
    op := cast(Film_Op) get_s16(commands, at + 2);
    return length, op, array_view(commands, at + 4, length - 4);
}

film_get_arg :: (args: [] u8, index: s64) -> s32 {
    if index * 2 + 2 > args.count return 0;
    return get_s16(args, index * 2);
}

#scope_file

is_valid_stream :: (commands: [] u8) -> bool {
    at := 0;
    while at + 4 <= commands.count {
        length := get_s16(commands, at);
        if length < 4 || at + length > commands.count return false;
        if get_s16(commands, at + 2) == xx Film_Op.END return true;
        at += length;
    }
    return false;
}

// A fixed-size name, up to its first null.
read_name :: (data: [] u8, at: s64, size: s64) -> string {
    name: string;
    name.data = data.data + at;
    while name.count < size && data[at + name.count]  name.count += 1;
    return name;
}

get_s16 :: (data: [] u8, at: s64) -> s32 {
    return cast(s32) cast,trunc(s16) ((cast(u16) data[at]) | ((cast(u16) data[at + 1]) << 8));
}

#import "Basic";
