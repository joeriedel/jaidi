// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The FM driver's tables come from the game's own driver, FM4.MDR, which ships inside
// IMUSE.EXE. The module is a 32-bit LX executable; mapping its one object at its base address
// puts each table at a fixed address. The addresses belong to the driver build checked here.

// The original driver's tables. Read only.
Fm_Driver :: struct {
    loaded: bool;

    velocity_to_volume:  [64] u8;   // Velocity / 2, or a scaled level, to OPL attenuation.
    freq_index_to_pitch: [192] u16; // F-number, 16 steps per semitone.
    key_to_freq_index:   [128] u8;  // Indexed by key - 7, as in the driver.
    key_to_block:        [128] u8;  // Likewise.
    key_to_drum_timbre:  [128] u8;  // Signed timbre - 128, for the drum channel.
    modulator_offset:    [FM_VOICE_COUNT] u8;  // Operator register offsets per voice.
    carrier_offset:      [FM_VOICE_COUNT] u8;
    bank_fields:         [TIMBRE_FIELD_COUNT * 3] u8;  // Per field: byte, shift, mask.
    timbres_right:       [TIMBRE_COUNT * TIMBRE_SIZE] u8;
    timbres_left:        [TIMBRE_COUNT * TIMBRE_SIZE] u8;
}

fm_driver: Fm_Driver;

// Reads the tables from dark_dir/IMUSE.EXE. Without them notes don't sound.
fm_load_driver :: (dark_dir: string) -> bool {
    path := tprint("%/IMUSE.EXE", dark_dir);
    archive, ok := archive_open(path);
    if !ok return false;
    defer archive_close(archive);

    entry := archive_find(archive, "FM4.MDR");
    if !entry {
        log_error("'%' holds no FM4.MDR.", path);
        return false;
    }
    if fnv1a_hash(entry.data.data, entry.data.count) != FM4_MDR_HASH {
        log_error("'%' holds an FM4.MDR this program doesn't know.", path);
        return false;
    }
    image, mapped := lx_map_object(entry.data);
    if !mapped {
        log_error("'%' holds a damaged FM4.MDR.", path);
        return false;
    }

    d := *fm_driver;
    d.* = .{};
    read_u32_table(image, ADDRESS_VELOCITY_TO_VOLUME, d.velocity_to_volume);
    read_u32_table(image, ADDRESS_FREQ_INDEX_TO_PITCH, d.freq_index_to_pitch);
    read_u8_table(image, ADDRESS_KEY_TO_FREQ_INDEX, d.key_to_freq_index);
    read_u8_table(image, ADDRESS_KEY_TO_BLOCK, d.key_to_block);
    read_u8_table(image, ADDRESS_KEY_TO_DRUM_TIMBRE, d.key_to_drum_timbre);
    read_u32_table(image, ADDRESS_MODULATOR_OFFSET, d.modulator_offset);
    read_u32_table(image, ADDRESS_CARRIER_OFFSET, d.carrier_offset);
    read_u32_table(image, ADDRESS_BANK_FIELDS, d.bank_fields);
    read_u8_table(image, ADDRESS_TIMBRES_RIGHT, d.timbres_right);
    read_u8_table(image, ADDRESS_TIMBRES_LEFT, d.timbres_left);
    d.loaded = true;
    return true;
}

TIMBRE_COUNT       :: 167;
TIMBRE_SIZE        :: 12;
TIMBRE_FIELD_COUNT :: 28;

#scope_file

// FNV-1a of FM4.MDR in Dark Forces 1.0's IMUSE.EXE.
FM4_MDR_HASH :: 0x72c091dcc3df8a33;

// Addresses in the mapped object.
ADDRESS_VELOCITY_TO_VOLUME  :: 0x114F4;  // u32 entries.
ADDRESS_TIMBRES_RIGHT       :: 0x115F4;
ADDRESS_TIMBRES_LEFT        :: 0x11DC8;
ADDRESS_KEY_TO_DRUM_TIMBRE  :: 0x1259C;
ADDRESS_BANK_FIELDS         :: 0x1281C;  // u32 entries.
ADDRESS_MODULATOR_OFFSET    :: 0x12B58;  // u32 entries.
ADDRESS_CARRIER_OFFSET      :: 0x12B7C;  // u32 entries.
ADDRESS_KEY_TO_BLOCK        :: 0x12BA0;
ADDRESS_FREQ_INDEX_TO_PITCH :: 0x12C20;  // u32 entries.
ADDRESS_KEY_TO_FREQ_INDEX   :: 0x12F20;

read_u8_table :: (image: Lx_Image, address: int, table: [] u8) {
    at := address - image.base;
    assert(at >= 0 && at + table.count <= image.bytes.count);
    memcpy(table.data, image.bytes.data + at, table.count);
}

// The driver keeps these as u32s; every value fits the narrower type.
read_u32_table :: (image: Lx_Image, address: int, table: [] $T) {
    at := address - image.base;
    assert(at >= 0 && at + table.count * 4 <= image.bytes.count);
    for * table  it.* = cast(T) read_u32(image.bytes, at + it_index * 4);
}

read_u32 :: (bytes: [] u8, at: int) -> u32 {
    return  (cast(u32) bytes[at])            | ((cast(u32) bytes[at + 1]) << 8) |
           ((cast(u32) bytes[at + 2]) << 16) | ((cast(u32) bytes[at + 3]) << 24);
}

#import "Basic";
#import "Hash";
#import "engine/dfArchive";
