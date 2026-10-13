// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// GMD files: a "MIDI" container holding an "MDpg" chunk (iMUSE metadata, unused here) and a
// format 2 standard MIDI file. Each MTrk is an independent sequence, which iMUSE calls a chunk:
// chunk 1 is the song, the rest are transition pieces that jumps lead into.

GMD_MAX_CHUNKS :: 16;

Gmd :: struct {
    data:   [] u8;
    chunks: [GMD_MAX_CHUNKS] [] u8;  // Event data of each MTrk, without its header.
    chunk_count: int;
}

// Checks the container and that every chunk lies inside it. The Gmd points into 'data'.
gmd_parse :: (data: [] u8) -> Gmd, bool {
    gmd: Gmd;
    gmd.data = data;
    if data.count < 8 || !has_tag(data, 0, "MIDI") return gmd, false;
    end := min(8 + cast(int) read_u32_be(data, 4), data.count);

    track_count := -1;
    at := 8;
    while at + 8 <= end {
        length := cast(int) read_u32_be(data, at + 4);
        body := at + 8;
        if body + length > end return gmd, false;

        if has_tag(data, at, "MThd") {
            if length < 6 return gmd, false;
            track_count = read_u16_be(data, body + 2);
        } else if has_tag(data, at, "MTrk") {
            if gmd.chunk_count == GMD_MAX_CHUNKS return gmd, false;
            gmd.chunks[gmd.chunk_count] = array_view(data, body, length);
            gmd.chunk_count += 1;
        }
        at = body + length;
    }
    if track_count < 0 || gmd.chunk_count == 0 || gmd.chunk_count != track_count  return gmd, false;
    return gmd, true;
}

#scope_file

read_u32_be :: (bytes: [] u8, at: int) -> u32 {
    return ((cast(u32) bytes[at]) << 24) | ((cast(u32) bytes[at + 1]) << 16) |
           ((cast(u32) bytes[at + 2]) << 8) | (cast(u32) bytes[at + 3]);
}

read_u16_be :: (bytes: [] u8, at: int) -> int {
    return ((cast(int) bytes[at]) << 8) | bytes[at + 1];
}

has_tag :: (bytes: [] u8, at: int, tag: string) -> bool {
    if at + tag.count > bytes.count return false;
    return memcmp(bytes.data + at, tag.data, tag.count) == 0;
}

#import "Basic";
