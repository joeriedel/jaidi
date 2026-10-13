// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// FM music driver: turns MIDI channel messages into OPL3 register writes, the way the DOS game's
// FM driver did, using that driver's own tables (see driver.jai).
//
// The OPL3 runs as two OPL2 register sets: set 0 (registers 0x000-0x0FF) feeds the right
// output and set 1 (0x100-0x1FF) the left. Each of the 9 voices plays on both, with timbres
// from slightly different banks, which is where the stereo comes from. MIDI pan is ignored.
//
// Not thread safe: when the audio callback is running, call this under audio_lock.

FM_SAMPLE_RATE :: 49716;  // The OPL3's native rate.
FM_VOICE_COUNT :: 9;

fm_reset :: () {
    fm = .{};
    OPL3_Reset(*fm.chip, FM_SAMPLE_RATE);

    // Writes that match the zeroed shadow are skipped, so after a chip reset this only sets
    // keyboard split and OPL3 mode.
    for reg: 0..REGISTER_COUNT-1 {
        write_register(.RIGHT, xx reg, 0);
        write_register(.LEFT,  xx reg, 0);
    }
    write_register(.RIGHT, REG_KBD_SPLIT, VALUE_KEYBOARD_SPLIT);
    write_register(.RIGHT, REG_PERCUSSION, 0);
    write_register(.LEFT,  REG_MODE, VALUE_ENABLE);  // 0x105: OPL3 mode.

    for * fm.channels it.* = .{};
    for 0..FM_VOICE_COUNT-1  fm.voices[it].id = xx it;
    for 0..FM_VOICE_COUNT-1  list_push(*fm.free, xx it);
}

// One MIDI channel message. Running status isn't handled here; the caller passes full messages.
fm_send_midi :: (status: u8, data1: u8, data2: u8 = 0) {
    channel := status & 0x0F;
    data1 &= 0x7F;
    data2 &= 0x7F;
    if status & 0xF0 == {
        case MIDI_NOTE_OFF;       stop_note(channel, data1);
        case MIDI_NOTE_ON;        start_note(channel, data1, data2);
        case MIDI_CONTROL_CHANGE; apply_control_change(channel, data1, data2);
        case MIDI_PROGRAM_CHANGE; fm.channels[channel].timbre = data1;
        case MIDI_PITCH_BEND;     bend_channel(channel, ((cast(int) data2) << 7) | data1);
    }
}

// A controller with a full-range value. iMUSE sends part priorities this way: a part's own
// plus its song's can pass 127, and the original driver keeps the whole value.
fm_set_control :: (channel: u8, controller: u8, value: int) {
    apply_control_change(channel & 0x0F, controller, value);
}

fm_stop_all_notes :: () {
    while fm.active.count {
        voice := fm.active.ids[0];
        release_voice(voice);
        list_remove(*fm.active, voice);
        list_push(*fm.free, voice);
    }
    for * fm.channels {
        it.ref_count = 0;
        it.note_req  = 1;
    }
}

// Fills interleaved stereo frames (left, right).
fm_generate :: (frames: [] s16) {
    assert(frames.count % 2 == 0);
    OPL3_GenerateStream(*fm.chip, frames.data, xx (frames.count / 2));
}

Fm_Voice_State :: struct {
    active:  bool;
    channel: u8;
    key:     u8;
}

// For tools and tests.
fm_get_voice_state :: () -> [FM_VOICE_COUNT] Fm_Voice_State {
    result: [FM_VOICE_COUNT] Fm_Voice_State;
    for i: 0..fm.active.count-1 {
        v := *fm.voices[fm.active.ids[i]];
        result[v.id] = .{true, v.channel, v.key};
    }
    return result;
}

fm_get_register :: (index: u16) -> u8 {
    return fm.registers[index];
}

MIDI_NOTE_OFF       :: 0x80;
MIDI_NOTE_ON        :: 0x90;
MIDI_CONTROL_CHANGE :: 0xB0;
MIDI_PROGRAM_CHANGE :: 0xC0;
MIDI_PITCH_BEND     :: 0xE0;

MIDI_CC_VOLUME   :: 7;
MIDI_CC_PAN      :: 10;
MIDI_CC_NOTE_REQ :: 17;  // General purpose 2: iMUSE's per-part note reservation.
MIDI_CC_PRIORITY :: 18;  // General purpose 3: iMUSE's per-part priority.

MIDI_DRUM_CHANNEL :: 9;

#load "driver.jai";

#scope_file

Side :: enum u8 { RIGHT; LEFT; }

REGISTER_COUNT :: 256;

REG_MODE         :: 0x05;
REG_KBD_SPLIT    :: 0x08;
REG_ENABLE_WAVE  :: 0x20;
REG_LEVEL        :: 0x40;
REG_ATTACK_DECAY :: 0x60;
REG_SUSTAIN_REL  :: 0x80;
REG_FNUM_LOW     :: 0xA0;
REG_KEYON_BLOCK  :: 0xB0;
REG_PERCUSSION   :: 0xBD;
REG_FEEDBACK     :: 0xC0;
REG_WAVE_SELECT  :: 0xE0;

VALUE_ENABLE         :: 0x01;
VALUE_KEYON          :: 0x20;
VALUE_LEVEL_MASK     :: 0x3F;
VALUE_KEYBOARD_SPLIT :: 0x40;
VALUE_OUT_LEFT       :: 0x10;
VALUE_OUT_RIGHT      :: 0x20;

PITCH_CENTER :: 0x2000;
MAX_ATTEN    :: 0x3F;

// Indices into fm_driver.bank_fields.
FIELD_CARRIER_LEVEL     :: 0;
FIELD_CARRIER_VELOCITY  :: 1;
FIELD_MODULATOR_LEVEL   :: 13;
FIELD_MODULATOR_VELOCITY:: 14;
FIELD_CONNECTION        :: 26;

Channel :: struct {
    priority:  int;
    note_req:  int = 1;
    ref_count: int;
    port:      int;   // 1 once the channel plays more notes than it reserved; stolen from first.
    timbre:    int;
    volume:    int = 127;
    pan:       int = 64;
    pitch:     int = PITCH_CENTER;
}

Voice :: struct {
    id:      u8;
    channel: u8;
    key:     u8;
    // Per side, set at note on and reused when the channel volume changes.
    carrier_level: [2] int;
}

// Voice ids, most recently added first. The original keeps linked lists with insertion at the
// head, and voice allocation and stealing depend on that order.
Voice_List :: struct {
    ids:   [FM_VOICE_COUNT] u8;
    count: int;
}

fm: struct {
    chip:      opl3_chip;
    registers: [REGISTER_COUNT * 2] u8;  // Shadow of both register sets.
    channels:  [16] Channel;
    voices:    [FM_VOICE_COUNT] Voice;
    active:    Voice_List;
    free:      Voice_List;
};

start_note :: (channel_id: u8, key: u8, velocity: u8) {
    if !fm_driver.loaded return;
    channel := *fm.channels[channel_id];
    if channel_id == MIDI_DRUM_CHANNEL {
        channel.timbre = cast(int) cast,no_check(s8) fm_driver.key_to_drum_timbre[key] + 128;
        if channel.timbre >= 128  channel.pitch = PITCH_CENTER;
    }

    voice := alloc_voice(channel_id);
    if voice < 0 return;
    fm.voices[voice].channel = channel_id;
    fm.voices[voice].key     = key;

    channel.ref_count += 1;
    update_port(channel);
    start_voice(xx voice, key, velocity, channel.timbre, channel.volume, channel.pitch);
}

stop_note :: (channel_id: u8, key: u8) {
    for i: 0..fm.active.count-1 {
        voice := fm.active.ids[i];
        if fm.voices[voice].channel != channel_id || fm.voices[voice].key != key  continue;

        release_voice(voice);
        channel := *fm.channels[channel_id];
        channel.ref_count -= 1;
        update_port(channel);
        list_remove(*fm.active, voice);
        list_push(*fm.free, voice);
        break;
    }
}

apply_control_change :: (channel_id: u8, controller: u8, value: int) {
    channel := *fm.channels[channel_id];
    if controller == {
        case MIDI_CC_VOLUME;
            channel.volume = value;
            for i: 0..fm.active.count-1 {
                voice := fm.active.ids[i];
                if fm.voices[voice].channel == channel_id  set_voice_volume(voice, value);
            }
        case MIDI_CC_PAN;      channel.pan      = value;
        case MIDI_CC_NOTE_REQ; channel.note_req = value;
        case MIDI_CC_PRIORITY; channel.priority = value;
    }
}

// Re-pitches the channel's sounding notes; later notes start bent. The drum channel ignores
// bends.
bend_channel :: (channel_id: u8, value: int) {
    if channel_id == MIDI_DRUM_CHANNEL return;
    fm.channels[channel_id].pitch = value;
    for i: 0..fm.active.count-1 {
        voice := *fm.voices[fm.active.ids[i]];
        if voice.channel == channel_id  set_voice_pitch(voice.id, voice.key, (value - PITCH_CENTER) >> 1);
    }
}

update_port :: (channel: *Channel) {
    channel.port = ifx channel.ref_count > channel.note_req then 1 else 0;
}

// Takes the free voice added longest ago. With none free, steals from the active voices,
// walking newest first: a voice whose channel plays more notes than it reserved is always fair
// game, even against a lower-priority request; otherwise a voice can only be taken by a channel
// of at least its priority, and among those the last one at or below the best so far wins.
alloc_voice :: (channel_id: u8) -> int {
    voice := -1;
    if fm.free.count {
        voice = fm.free.ids[fm.free.count - 1];
        list_remove(*fm.free, xx voice);
    } else {
        best := -1;
        best_channel := *fm.channels[channel_id];
        for i: 0..fm.active.count-1 {
            candidate := fm.active.ids[i];
            channel := *fm.channels[fm.voices[candidate].channel];
            if channel.port == best_channel.port {
                if best_channel.priority >= channel.priority {
                    best = candidate;
                    best_channel = channel;
                }
            } else if channel.port {
                best = candidate;
                best_channel = channel;
            }
        }
        if best < 0 return -1;

        release_voice(xx best);
        stolen := *fm.channels[fm.voices[best].channel];
        stolen.ref_count -= 1;
        update_port(stolen);
        list_remove(*fm.active, xx best);
        voice = best;
    }
    list_push(*fm.active, xx voice);
    return voice;
}

start_voice :: (voice: u8, key: u8, velocity: u8, timbre: int, volume: int, pitch: int) {
    scaled_velocity := cast(int) fm_driver.velocity_to_volume[velocity >> 1] * 2;

    modulator_right, carrier_right := load_voice_side(.RIGHT, voice, timbre, scaled_velocity, volume);
    modulator_left,  carrier_left  := load_voice_side(.LEFT,  voice, timbre, scaled_velocity, volume);

    set_voice_pitch(voice, key, (pitch - PITCH_CENTER) >> 1);

    // The timbre left both operators at full attenuation over its own level bits; subtract the
    // computed levels from that.
    modulator := REG_LEVEL + fm_driver.modulator_offset[voice];
    carrier   := REG_LEVEL + fm_driver.carrier_offset[voice];
    write_register(.RIGHT, modulator, read_register(.RIGHT, modulator) - modulator_right);
    write_register(.RIGHT, carrier,   read_register(.RIGHT, carrier)   - carrier_right);
    write_register(.LEFT,  modulator, read_register(.LEFT,  modulator) - modulator_left);
    write_register(.LEFT,  carrier,   read_register(.LEFT,  carrier)   - carrier_left);

    write_register(.RIGHT, REG_KEYON_BLOCK + voice, read_register(.RIGHT, REG_KEYON_BLOCK + voice) | VALUE_KEYON);
    write_register(.LEFT,  REG_KEYON_BLOCK + voice, read_register(.LEFT,  REG_KEYON_BLOCK + voice) | VALUE_KEYON);
}

// Loads the timbre into one side and returns the modulator and carrier levels to apply.
// The modulator level only follows velocity and volume for additive (connection 1) timbres;
// otherwise it sets modulation depth and stays as the timbre has it.
load_voice_side :: (side: Side, voice: u8, timbre: int, velocity: int, volume: int) -> modulator: int, carrier: int {
    additive := get_timbre_field(side, timbre, FIELD_CONNECTION) == 1;

    carrier := ((get_timbre_field(side, timbre, FIELD_CARRIER_VELOCITY) + 1) * velocity) >> 6;
    carrier  = min(carrier + get_timbre_field(side, timbre, FIELD_CARRIER_LEVEL), MAX_ATTEN);
    fm.voices[voice].carrier_level[side] = carrier;

    modulator := ((get_timbre_field(side, timbre, FIELD_MODULATOR_VELOCITY) + 1) * velocity) >> 6;
    modulator  = min(modulator + get_timbre_field(side, timbre, FIELD_MODULATOR_LEVEL), MAX_ATTEN);

    carrier = fm_driver.velocity_to_volume[((carrier + 1) * volume) >> 7];
    if additive  modulator = fm_driver.velocity_to_volume[((modulator + 1) * volume) >> 7];

    set_voice_timbre(side, voice, timbre);
    return modulator, carrier;
}

release_voice :: (voice: u8) {
    write_register(.RIGHT, REG_KEYON_BLOCK + voice, read_register(.RIGHT, REG_KEYON_BLOCK + voice) & ~VALUE_KEYON);
    write_register(.LEFT,  REG_KEYON_BLOCK + voice, read_register(.LEFT,  REG_KEYON_BLOCK + voice) & ~VALUE_KEYON);
}

set_voice_volume :: (voice: u8, volume: int) {
    for side: Side.[.RIGHT, .LEFT] {
        level := fm.voices[voice].carrier_level[side];
        full  := cast(int) fm_driver.velocity_to_volume[((level + 1) * volume) >> 7];
        reg   := REG_LEVEL + fm_driver.carrier_offset[voice];
        write_register(side, reg, (read_register(side, reg) | MAX_ATTEN) - full);
    }
}

// pitch_offset is in 1/256 semitones. Both sides get the right side's key-on bit, so a pitch
// change doesn't retrigger or release the note.
set_voice_pitch :: (voice: u8, key: u8, pitch_offset: int) {
    index := clamp(cast(int) key + (pitch_offset >> 8) - 7, 0, 127);
    freq_index := fm_driver.key_to_freq_index[index] + ((pitch_offset >> 4) & 0x0F);
    fnum := fm_driver.freq_index_to_pitch[freq_index];
    low  := fnum & 0xFF;
    high := ((read_register(.RIGHT, REG_KEYON_BLOCK + voice) & VALUE_KEYON) | (fm_driver.key_to_block[index] << 2)) + (fnum >> 8);

    for side: Side.[.RIGHT, .LEFT] {
        write_register(side, REG_FNUM_LOW    + voice, low);
        write_register(side, REG_KEYON_BLOCK + voice, high);
    }
}

// Loads the operators at full attenuation; start_voice sets the real levels after.
set_voice_timbre :: (side: Side, voice: u8, timbre: int) {
    bank := get_timbre_bytes(side, timbre);
    modulator := fm_driver.modulator_offset[voice];
    carrier   := fm_driver.carrier_offset[voice];
    write_register(side, REG_LEVEL + modulator, VALUE_LEVEL_MASK);
    write_register(side, REG_LEVEL + carrier,   VALUE_LEVEL_MASK);

    for op: 0..1 {
        offset := ifx op == 0 then modulator else carrier;
        b := bank.data + op * 5;
        write_register(side, REG_ENABLE_WAVE  + offset, b[0]);
        write_register(side, REG_LEVEL        + offset, b[1] | VALUE_LEVEL_MASK);
        write_register(side, REG_ATTACK_DECAY + offset, ~b[2]);
        write_register(side, REG_SUSTAIN_REL  + offset, ~b[3]);
        write_register(side, REG_WAVE_SELECT  + offset, b[4]);
    }
    out := ifx side == .RIGHT then VALUE_OUT_RIGHT else VALUE_OUT_LEFT;
    write_register(side, REG_FEEDBACK + voice, bank[10] | out);
}

get_timbre_bytes :: (side: Side, timbre: int) -> [] u8 {
    assert(timbre >= 0 && timbre < TIMBRE_COUNT);
    bytes: [] u8;
    bytes.data  = (ifx side == .RIGHT then fm_driver.timbres_right.data else fm_driver.timbres_left.data) + timbre * TIMBRE_SIZE;
    bytes.count = TIMBRE_SIZE;
    return bytes;
}

get_timbre_field :: (side: Side, timbre: int, field: int) -> int {
    if timbre >= TIMBRE_COUNT return 0;
    bank  := get_timbre_bytes(side, timbre);
    entry := field * 3;
    offset, shift, mask := fm_driver.bank_fields[entry], fm_driver.bank_fields[entry + 1], fm_driver.bank_fields[entry + 2];
    return (bank[offset] & mask) >> shift;
}

read_register :: (side: Side, reg: int) -> int {
    return fm.registers[cast(int) side * REGISTER_COUNT + reg];
}

// Skips writes that wouldn't change the register.
write_register :: (side: Side, reg: int, value: s64) {
    index := cast(int) side * REGISTER_COUNT + reg;
    byte  := cast,trunc(u8) value;
    if fm.registers[index] == byte return;
    fm.registers[index] = byte;
    OPL3_WriteRegBuffered(*fm.chip, xx index, byte);
}

list_push :: (list: *Voice_List, voice: u8) {
    assert(list.count < FM_VOICE_COUNT);
    for < i: 1..list.count  list.ids[i] = list.ids[i - 1];
    list.ids[0] = voice;
    list.count += 1;
}

list_remove :: (list: *Voice_List, voice: u8) {
    for i: 0..list.count-1 {
        if list.ids[i] != voice continue;
        for j: i..list.count-2  list.ids[j] = list.ids[j + 1];
        list.count -= 1;
        return;
    }
    assert(false, "voice % not in list", voice);
}

#import "Basic";
#import "engine/vendor/NukedOPL3";
