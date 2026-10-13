// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// VOC: Creative Voice files, the game's sound effects (SOUNDS.GOB) and cutscene voices (VOIC in
// the LFDs). Every retail file is 8-bit unsigned mono, uncompressed, at about 11 kHz; looping
// sounds mark their loop with a repeat block and an end-repeat block.

Sound :: struct {
    rate:    s32;               // Samples per second.
    samples: [..] u8;           // Unsigned 8-bit, 128 is silence.

    // The part between a repeat and an end-repeat block, or -1 when the sound doesn't loop.
    loop_start: s64 = -1;
    loop_end:   s64 = -1;
    loop_count: s32;            // Times through the loop as the block gives it; 0xFFFF is forever.
}

sound_free :: (sound: *Sound) {
    array_free(sound.samples);
    sound.* = .{};
}

voc_parse :: (data: [] u8) -> Sound, bool {
    sound: Sound;
    ok := parse_voc(*sound, data);
    if !ok sound_free(*sound);
    return sound, ok;
}

#scope_file

VOC_MAGIC :: "Creative Voice File\x1A";

parse_voc :: (sound: *Sound, data: [] u8) -> bool {
    if data.count < 26 || memcmp(data.data, VOC_MAGIC.data, VOC_MAGIC.count) != 0 return false;
    at: s64 = data[20] | ((cast(s64) data[21]) << 8);

    while at < data.count {
        type := data[at];
        if type == 0 break;
        if at + 4 > data.count return false;
        size: s64 = data[at + 1] | ((cast(s64) data[at + 2]) << 8) | ((cast(s64) data[at + 3]) << 16);
        body := at + 4;
        if body + size > data.count return false;

        if type == {
            case 1;
                // Rate code, codec, samples. Only 8-bit PCM (codec 0) is used.
                if size < 2 || data[body + 1] != 0 return false;
                rate := 1_000_000 / (256 - cast(s32) data[body]);
                if sound.samples.count && rate != sound.rate return false;
                sound.rate = rate;
                append_samples(sound, array_view(data, body + 2, size - 2));
            case 2;
                if !sound.rate return false;
                append_samples(sound, array_view(data, body, size));
            case 3;
                // Silence: length - 1, rate code.
                if size < 3 return false;
                length: s64 = (data[body] | ((cast(s64) data[body + 1]) << 8)) + 1;
                if !sound.rate  sound.rate = 1_000_000 / (256 - cast(s32) data[body + 2]);
                old := sound.samples.count;
                array_resize(*sound.samples, old + length, initialize = false);
                memset(sound.samples.data + old, 128, length);
            case 6;
                if size < 2 return false;
                sound.loop_start = sound.samples.count;
                sound.loop_count = data[body] | ((cast(s32) data[body + 1]) << 8);
            case 7;
                sound.loop_end = sound.samples.count;
        }
        at = body + size;
    }

    if sound.loop_start >= 0 && sound.loop_end <= sound.loop_start {
        sound.loop_start = -1;
        sound.loop_end   = -1;
    }
    return sound.samples.count > 0 && sound.rate > 0;
}

append_samples :: (sound: *Sound, samples: [] u8) {
    old := sound.samples.count;
    array_resize(*sound.samples, old + samples.count, initialize = false);
    memcpy(sound.samples.data + old, samples.data, samples.count);
}

#import "Basic";
