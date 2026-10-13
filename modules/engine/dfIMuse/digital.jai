// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Digital sounds: VOC data played on 8 tracks and mixed as iMUSE mixes them for the Sound
// Blaster 16. The card plays 8-bit unsigned stereo at 10989 frames a second (time constant
// 0xA5), from a buffer iMUSE fills 512 frames at a time. Samples play one per frame, whatever
// rate the file gives. Each track adds its samples through two lookup tables in IMUSE.ENG, a
// volume table (17 rows mapping an unsigned sample to a signed one) and a pan table (which
// volume row each side gets), into 16-bit sums, which a soft-clipping table turns back into
// bytes. A track's volume and pan are read at the start of each stretch it mixes, so changes
// land a buffer at a time.
//
// The VOC blocks are read as the sound plays: sound data (its rate ignored), markers, and a
// repeat block whose end-repeat jumps back to it forever. Any other block ends the sound.
//
// Digital sound ids are the caller's own, from IMUSE_DIGITAL_FIRST up; the same id can play on
// several tracks at once. Setting a parameter reaches the one started last; stopping ends them
// all.

IMUSE_DIGITAL_RATE   :: 10989;  // Frames a second: 1000000 / (256 - 0xA5).
IMUSE_DIGITAL_FRAMES :: 512;    // Frames iMUSE mixes into each half of the card's buffer.
IMUSE_DIGITAL_FIRST  : Imuse_Song : 0x10000;
IMUSE_TRACKS         :: 8;      // Dark Forces asks iMUSE for 8.

Imuse_Param :: enum s32 {
    GROUP    :: 0x400;  // 0-15. Dark Forces: 1 sound effects, 2 voices, 3 music.
    PRIORITY :: 0x500;  // 0-127.
    VOLUME   :: 0x600;  // 0-127.
    PAN      :: 0x700;  // 0-127, 64 centered.
}

// Reads the mixing tables from dark_dir/IMUSE.EXE, and from IMUSE.INI how the card was set
// up. Without them digital sounds stay silent.
imuse_load_digital_tables :: (dark_dir: string) -> bool {
    digital.loaded = false;
    path := tprint("%/IMUSE.EXE", dark_dir);
    archive, ok := archive_open(path);
    if !ok return false;
    defer archive_close(archive);
    entry := archive_find(archive, "IMUSE.ENG");
    if !entry || fnv1a_hash(entry.data.data, entry.data.count) != IMUSE_ENG_HASH {
        log_error("'%' holds no IMUSE.ENG this program knows.", path);
        return false;
    }
    image, mapped := lx_map_object(entry.data);
    if !mapped {
        log_error("'%' holds a damaged IMUSE.ENG.", path);
        return false;
    }
    memcpy(digital.volume_table.data, image.bytes.data + ADDRESS_VOLUME_TABLE - image.base, size_of(type_of(digital.volume_table)));
    memcpy(digital.pan_table.data,    image.bytes.data + ADDRESS_PAN_TABLE - image.base,    size_of(type_of(digital.pan_table)));
    build_clip_table();
    digital.swap_sides = is_card_set_up_mono(dark_dir);
    digital.loaded = true;
    return true;
}

// Starts a digital sound on a free track, or on the lowest-priority one if none is free and
// the new sound's priority is at least as high. 'data' is a VOC file, which must stay valid
// while the sound plays. Volume 127, pan 64, group 0.
imuse_start_digital :: (id: Imuse_Song, data: [] u8, priority: int) -> bool {
    if id < IMUSE_DIGITAL_FIRST return false;
    priority = clamp(priority, 0, 127);
    t := take_track(cast(s32) priority);
    if !t return false;
    t.* = .{};
    t.id       = id;
    t.data     = data;
    t.priority = cast(s32) priority;
    t.volume   = 127;
    t.effective = digital.group_effective[0];
    t.pan      = 64;
    if !read_next_block(t) {
        t.id = 0;
        return false;
    }
    // Newest first.
    array_insert_at(*digital.order, cast(s32) (t - digital.tracks.data), 0);
    return true;
}

// Every track playing the sound.
imuse_stop_digital :: (id: Imuse_Song) {
    i := 0;
    while i < digital.order.count {
        t := *digital.tracks[digital.order[i]];
        if t.id == id  free_track(t);
        else           i += 1;
    }
}

// Every digital sound, the songs left playing.
imuse_stop_all_digital :: () { stop_all_digital(); }

imuse_is_digital_playing :: (id: Imuse_Song) -> bool {
    return find_track(id) != null;
}

// Sets a parameter of the sound started last under this id. False when it isn't playing or
// the value is out of range.
imuse_set_param :: (id: Imuse_Song, param: Imuse_Param, value: int) -> bool {
    return set_digital_param(id, param, value);
}

imuse_get_param :: (id: Imuse_Song, param: Imuse_Param) -> int, bool {
    value, ok := get_digital_param(id, param);
    return value, ok;
}

// Moves a parameter to 'value' over 'frames' 60 Hz frames. A volume that reaches 0 stops the
// sound. False when it isn't playing or all 16 fades are taken.
imuse_fade_param :: (id: Imuse_Song, param: Imuse_Param, value: int, frames: int) -> bool {
    if frames < 0 return false;
    return start_param_fade(id, param, value, frames);
}

// Mixes the next frames into 'out', 8-bit unsigned stereo. Runs on the audio thread, under
// audio_lock.
imuse_mix_digital :: (out: [] u8) {
    if paused {
        memset(out.data, 0x80, out.count);
        return;
    }
    at := 0;
    while at < out.count {
        if digital.mixed_at >= digital.mixed.count {
            mix_buffer();
            digital.mixed_at = 0;
        }
        n := min(out.count - at, digital.mixed.count - digital.mixed_at);
        memcpy(out.data + at, digital.mixed.data + digital.mixed_at, n);
        at += n;
        digital.mixed_at += n;
    }
}

#scope_module

Track :: struct {
    id:        Imuse_Song;  // 0 while free.
    data:      [] u8;
    offset:    s64;         // The next byte to read.
    left:      s64;         // Samples left in the block being played.
    loop:      s64;         // Where the last repeat block was.
    priority:  s32;
    volume:    s32;
    effective: s32;         // Volume scaled by the group's.
    pan:       s32;
    group:     s32;
}

digital: struct {
    loaded: bool;
    tracks: [IMUSE_TRACKS] Track;
    order:  [..] s32;           // Playing tracks, newest first.

    volume_table: [17 * 256] u8;    // Signed samples.
    pan_table:    [17 * 17] u8;
    clip_table:   [2 * CLIP_RANGE] u8;  // By sum + CLIP_RANGE.
    swap_sides:   bool;

    // All groups at 127: group 0's effective volume is its own, the others' scaled by it.
    group_effective: [16] s32 = .[127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127];

    sums:  [IMUSE_DIGITAL_FRAMES * 2] s16;
    mixed: [IMUSE_DIGITAL_FRAMES * 2] u8;
    mixed_at: s64 = IMUSE_DIGITAL_FRAMES * 2;
};

stop_all_digital :: () {
    while digital.order.count  free_track(*digital.tracks[digital.order[0]]);
}

is_digital :: (id: Imuse_Song) -> bool {
    return id >= IMUSE_DIGITAL_FIRST;
}

set_digital_param :: (id: Imuse_Song, param: Imuse_Param, value: int) -> bool {
    t := find_track(id);
    if !t return false;
    if param == {
      case .GROUP;
        if value < 0 || value > 15 return false;
        t.group = cast(s32) value;
        t.effective = ((t.volume + 1) * digital.group_effective[t.group]) >> 7;
      case .PRIORITY;
        if value < 0 || value > 127 return false;
        t.priority = cast(s32) value;
      case .VOLUME;
        if value < 0 || value > 127 return false;
        t.volume = cast(s32) value;
        t.effective = ((t.volume + 1) * digital.group_effective[t.group]) >> 7;
      case .PAN;
        if value < 0 || value > 127 return false;
        t.pan = cast(s32) value;
      case;
        return false;
    }
    return true;
}

get_digital_param :: (id: Imuse_Song, param: Imuse_Param) -> int, bool {
    t := find_track(id);
    if !t return 0, false;
    if param == {
        case .GROUP;    return t.group, true;
        case .PRIORITY; return t.priority, true;
        case .VOLUME;   return t.volume, true;
        case .PAN;      return t.pan, true;
    }
    return 0, false;
}

#scope_file

// FNV-1a of IMUSE.ENG in Dark Forces 1.0's IMUSE.EXE, whose tables sit at these addresses.
IMUSE_ENG_HASH       :: 0x424330b5dd647479;
ADDRESS_VOLUME_TABLE :: 0x186C0;
ADDRESS_PAN_TABLE    :: 0x19840;

// The soft clip covers the sum of every track at full scale: 128 per track.
CLIP_RANGE :: IMUSE_TRACKS * 128;

// Saturates gently: n * 127 * i / ((n - 1) * i + n * 127) for a sum i of n tracks, rounded,
// around the unsigned midpoint.
build_clip_table :: () {
    n :: IMUSE_TRACKS;
    for i: 0..CLIP_RANGE-1 {
        c := ((n * 127 * i * 256) / ((n - 1) * i + n * 127) + 128) / 256;
        digital.clip_table[CLIP_RANGE + i]     = cast(u8) (128 + c);
        digital.clip_table[CLIP_RANGE - 1 - i] = cast(u8) (127 - c);
    }
}

// IMUSE.INI holds the selected wave driver's name at 14, then an entry per driver of 46 bytes
// from 28: the name, port, IRQ, DMA, then a stereo flag. Set up mono (the retail file's
// setting), the SB16 driver tells iMUSE so, and iMUSE then mixes stereo all the same but with
// its sides swapped.
is_card_set_up_mono :: (dark_dir: string) -> bool {
    contents, ok := read_entire_file(tprint("%/IMUSE.INI", dark_dir), log_errors = false);
    if !ok return true;
    defer free(contents);
    ini := cast([] u8) contents;
    if ini.count < 28 return true;
    selected := read_name(ini, 14);
    at := 28;
    while at + 46 <= ini.count {
        if equal_nocase(read_name(ini, at), selected) {
            flag := (cast(u32) ini[at + 26]) | ((cast(u32) ini[at + 27]) << 8) | ((cast(u32) ini[at + 28]) << 16) | ((cast(u32) ini[at + 29]) << 24);
            return flag == 0;
        }
        at += 46;
    }
    return true;
}

read_name :: (bytes: [] u8, at: int) -> string {
    name: string;
    name.data = bytes.data + at;
    while name.count < 14 && at + name.count < bytes.count && bytes[at + name.count]  name.count += 1;
    return name;
}

// The first free track, or else the lowest-priority one (the oldest of those tied), freed for
// the new sound if it ranks at least as high.
take_track :: (priority: s32) -> *Track {
    for * digital.tracks  if !it.id  return it;
    lowest: *Track;
    lowest_priority: s32 = 127;
    for digital.order {
        t := *digital.tracks[it];
        if t.priority <= lowest_priority {
            lowest_priority = t.priority;
            lowest = t;
        }
    }
    if !lowest || priority < lowest_priority return null;
    free_track(lowest);
    return lowest;
}

free_track :: (t: *Track) {
    for digital.order  if digital.tracks.data + it == t { array_ordered_remove_by_index(*digital.order, it_index); break; }
    clear_fades(t.id);
    clear_triggers(t.id, IMUSE_ANY, null);
    t.id = 0;
}

find_track :: (id: Imuse_Song) -> *Track {
    for digital.order  if digital.tracks[it].id == id  return *digital.tracks[it];
    return null;
}

// Moves to the next block of samples. False at the end of the sound, or at a block it can't
// play.
read_next_block :: (t: *Track) -> bool {
    data := t.data;
    while true {
        if t.offset + 4 > data.count return false;
        type := data[t.offset];
        if type == {
          case 0;
            return false;
          case 1;
            // Size, rate code, packing: the samples follow, at the output rate.
            size := (cast(s64) data[t.offset + 1]) | ((cast(s64) data[t.offset + 2]) << 8) | ((cast(s64) data[t.offset + 3]) << 16);
            t.offset += 6;
            t.left = size - 2;
            if t.left < 0 || t.offset + t.left > data.count return false;
            if t.left return true;
          case 4;
            // A marker. No retail sound has one; the original fires a trigger.
            t.offset += 6;
          case 6;
            t.loop = t.offset;
            t.offset += 6;
          case 7;
            // Back to the repeat block, however many times the file asks for.
            t.offset = t.loop;
          case #char "C";
            // The file header, taken as its usual 26 bytes.
            if t.offset + 4 > data.count || data[t.offset + 1] != #char "r" || data[t.offset + 2] != #char "e" || data[t.offset + 3] != #char "a" return false;
            t.offset += 0x1A;
          case;
            return false;
        }
    }
    return false;
}

mix_buffer :: () {
    memset(digital.sums.data, 0, size_of(type_of(digital.sums)));
    i := 0;
    while i < digital.order.count {
        t := *digital.tracks[digital.order[i]];
        if mix_track(t)  i += 1;
        else             free_track(t);
    }
    for digital.sums  digital.mixed[it_index] = digital.clip_table[CLIP_RANGE + it];
}

// Adds a buffer's worth of the track. False when its sound has ended.
mix_track :: (t: *Track) -> bool {
    at := 0;
    while true {
        if t.left == 0 && !read_next_block(t) return false;
        if at == IMUSE_DIGITAL_FRAMES return true;
        n := min(IMUSE_DIGITAL_FRAMES - at, t.left);
        mix_samples(array_view(t.data, t.offset, n), at, t.effective, t.pan);
        at += n;
        t.offset += n;
        t.left -= n;
    }
    return true;
}

mix_samples :: (samples: [] u8, at: s64, volume: s32, pan: s32) {
    if !digital.loaded return;
    level := volume >> 3;
    if volume  level += 1;
    level = min(level, 16);
    // Pan in 17 steps from -8 to 8; 64 is the middle, the steps above it shifted by one.
    side := (pan >> 3) - 8;
    if pan > 64  side = (pan >> 3) - 7;
    first  := cast(s32) digital.pan_table[level * 17 + 8 + side];
    second := cast(s32) digital.pan_table[level * 17 + 8 - side];
    if digital.swap_sides  first, second = second, first;
    rows := digital.volume_table.data;
    sums := digital.sums.data + at * 2;
    for samples {
        sums[it_index * 2]     += cast,no_check(s8) rows[first * 256 + it];
        sums[it_index * 2 + 1] += cast,no_check(s8) rows[second * 256 + it];
    }
}

#import "Basic";
#import "File";
#import "Hash";
#import "String";
#import "engine/dfArchive";
