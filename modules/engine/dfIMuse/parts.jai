// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Parts and output channels. Each player has 16 parts, one per MIDI channel in its song. The
// driver has 15 melodic output channels, and each has two sides, so that two songs sharing
// parts can play on one channel at once. A part plays only while it holds a side; the
// allocator hands sides to the highest-priority parts and takes them back when priorities or
// volumes change. Parts that never got a program change play drums on channel 9 instead.
//
// Every value sent to the driver goes through the channel's cache, so unchanged values aren't
// resent, as in the original.

#scope_module

Part :: struct {
    slot:           *Slot;  // The side it plays on, or null.
    has_program:    bool;   // Set by its first program change.
    program:        int = 128;
    trim:           int = 127;
    priority:       int;    // CC18.
    total_priority: int;    // Its own plus its player's, not clamped.
    note_req:       int = 1;    // CC17: voices the driver should reserve for it.
    volume:         int = 127;  // CC7.
    final_volume:   int;    // Scaled by the trim and the player's volume; what the driver gets.
    pan:            int = 64;
    modulation:     int;
    pedal:          int;    // CC64.
    bend:           int;    // Pitch bend in detune units, or a volume swell when bend_range is 0.
    bend_range:     int = 2;  // CC16, in semitones.
    detune:         int;    // Transpose, detune and bend together.
}

// One side of an output channel.
Slot :: struct {
    out:    *Out_Channel;
    twin:   *Slot;
    player: *Player;
    part:   *Part;
    pedal:  int;
    keys_on:    [128] bool;
    keys_pedal: [128] bool;  // Released while the pedal was down.
}

Out_Channel :: struct {
    channel: u8;
    sides:   [2] Slot;

    // Last values sent to the driver.
    program:    int;
    priority:   int;
    note_req:   int;
    volume:     int;
    pan:        int;
    modulation: int;
    detune:     int;
}

OUT_CHANNEL_COUNT :: 15;
DRUM_CHANNEL      :: 9;

out_channels: [OUT_CHANNEL_COUNT] Out_Channel;

// Last values sent on the drum channel.
drums: struct {
    priority: int;
    note_req: int;
    volume:   int;
};

init_out_channels :: () {
    for * out, i: out_channels {
        out.* = .{};
        out.channel = xx ifx i < DRUM_CHANNEL then i else i + 1;
        out.volume  = 127;
        out.pan     = 64;
        out.sides[0].out  = out;
        out.sides[1].out  = out;
        out.sides[0].twin = *out.sides[1];
        out.sides[1].twin = *out.sides[0];

        send_program(out.channel, out.program);
        send_control(out.channel, CC_PRIORITY,   out.priority);
        send_control(out.channel, CC_NOTE_REQ,   out.note_req);
        send_control(out.channel, CC_VOLUME,     out.volume);
        send_control(out.channel, CC_PAN,        out.pan);
        send_control(out.channel, CC_MODULATION, out.modulation);
        send_detune(out.channel, out.detune);
    }

    drums.priority = 0;
    drums.note_req = 1;
    drums.volume   = 127;
    send_control(DRUM_CHANNEL, CC_PRIORITY, drums.priority);
    send_control(DRUM_CHANNEL, CC_NOTE_REQ, drums.note_req);
    send_control(DRUM_CHANNEL, CC_VOLUME,   drums.volume);
}

play_channel_message :: (p: *Player, status: u8, data1: u8, data2: u8) {
    part := *p.parts[status & 0x0F];
    if (status >> 4) & 7 == {
        case 0;
            stop_part_note(part, data1);
        case 1;
            if data2 == 0 {
                stop_part_note(part, data1);
            } else {
                p.notes += 1;
                start_part_note(part, data1, data2);
            }
        case 3;
            change_part_control(p, part, data1, data2);
        case 4;
            change_part_program(part, data1);
        case 6;
            bend_part(p, part, data1, data2);
        // Key and channel pressure are ignored.
    }
}

start_part_note :: (part: *Part, key: u8, velocity: u8) {
    if !part.has_program {
        if drums.priority != part.total_priority {
            drums.priority = part.total_priority;
            send_control(DRUM_CHANNEL, CC_PRIORITY, drums.priority);
        }
        if drums.note_req != part.note_req {
            drums.note_req = part.note_req;
            send_control(DRUM_CHANNEL, CC_NOTE_REQ, drums.note_req);
        }
        if drums.volume != part.final_volume {
            drums.volume = part.final_volume;
            send_control(DRUM_CHANNEL, CC_VOLUME, drums.volume);
        }
        send_note_on(DRUM_CHANNEL, key, velocity);
    } else if part.slot {
        start_slot_note(part.slot, key, velocity);
    }
}

stop_part_note :: (part: *Part, key: u8) {
    if !part.has_program  send_note_off(DRUM_CHANNEL, key);
    else if part.slot     stop_slot_note(part.slot, key);
}

change_part_control :: (p: *Player, part: *Part, controller: u8, value: u8) {
    if controller == {
        case CC_MODULATION;
            part.modulation = value;
            set_out_modulation(part.slot, value);
        case CC_VOLUME;
            part.volume = value;
            update_part_volume(p, part);
        case CC_PAN;
            part.pan = value;
            if part.slot  set_out_pan(part.slot, clamp(part.pan + p.pan - 64, 0, 127));
        case CC_BEND_RANGE;
            if value <= 12 {
                part.bend_range = value;
                bend_part(p, part, 0, 0x40);
            }
        case CC_NOTE_REQ;
            part.note_req = value;
            set_out_note_req(part.slot, value);
        case CC_PRIORITY;
            part.priority = value;
            update_part_priority(p, part);
            allocate_parts();
        case CC_PEDAL;
            part.pedal = value;
            set_slot_pedal(part.slot, value);
        case CC_ALL_NOTES_OFF;
            part.pedal = 0;
            silence_slot(part.slot);
        // Everything else is dropped.
    }
}

// The first program change is what makes a part melodic.
change_part_program :: (part: *Part, program: u8) {
    part.program = program;
    if !part.has_program {
        part.has_program = true;
        allocate_parts();
    } else if part.slot {
        set_out_program(part.slot, program);
    }
}

// With a range of 0 the bend swells the volume instead, up toward 127 or down toward 0.
bend_part :: (p: *Player, part: *Part, low: u8, high: u8) {
    value := (((cast(int) high) << 7) | low) - 0x2000;
    if part.bend_range == 0 {
        part.bend = value >> 6;
        update_part_volume(p, part);
    } else {
        part.bend = (value * part.bend_range) >> 5;
        update_part_detune(p, part);
    }
}

// Cuts every note of a player: the original sends each part all-notes-off, and resets its
// modulation and bend.
stop_all_part_notes :: (p: *Player) {
    for * p.parts {
        change_part_control(p, it, CC_ALL_NOTES_OFF, 0);
        change_part_control(p, it, CC_MODULATION, 0);
        bend_part(p, it, 0, 0x40);
    }
}

update_part_volume :: (p: *Player, part: *Part) {
    volume := part.volume;
    if part.bend_range == 0 {
        room := ifx part.bend < 0 then part.volume else 127 - part.volume;
        volume = (((room + 1) * part.bend) >> 7) + part.volume;
    }
    part.final_volume = ((volume + 1) * (part.trim + 1) * p.group_volume) >> 14;

    if !p.group_volume || !part.trim || !part.volume {
        if !part.slot return;
        release_slot(part);
    } else if part.slot {
        set_out_volume(part.slot, part.final_volume);
        return;
    }
    allocate_parts();
}

update_part_priority :: (p: *Player, part: *Part) {
    part.total_priority = part.priority + p.priority;
    set_out_priority(part.slot, part.total_priority);
}

update_part_detune :: (p: *Player, part: *Part) {
    part.detune = p.detune + part.bend + p.transpose * 256;
    set_out_detune(part.slot, part.detune);
}

// Gives free channel sides to the waiting parts with the highest priority, taking them from
// lower-priority parts when none is free, until nothing changes. Players are walked newest
// first and that order settles ties, as in the original.
allocate_parts :: () {
    while true {
        new_player, held_player: *Player;
        new_part, held_part: *Part;
        last_was_held := false;

        for i: 0..player_count-1 {
            p := player_list[i];
            for * part, m: p.parts {
                shared := ifx p.shared then *p.shared.parts[m] else null;

                // A part whose counterpart in the shared song holds a side takes the other one.
                if shared {
                    if part.slot && !shared.slot {
                        if is_part_audible(p.shared, shared)  assign_slot(p.shared, shared, part.slot.twin);
                    } else if !part.slot && shared.slot && is_part_audible(p, part) {
                        assign_slot(p, part, shared.slot.twin);
                    }
                }

                if !part.slot {
                    if is_part_audible(p, part) && (!new_part || new_part.total_priority < part.total_priority) {
                        new_player, new_part = p, part;
                        last_was_held = false;
                    }
                } else if (!shared || !shared.slot || shared.total_priority <= part.total_priority) &&
                          (!held_part || part.total_priority <= held_part.total_priority) {
                    held_player, held_part = p, part;
                    last_was_held = true;
                }
            }
        }
        if !new_part return;

        slot := get_free_slot();
        if !slot {
            if !held_part return;
            if new_part.total_priority <= held_part.total_priority {
                if new_part.total_priority != held_part.total_priority  return;
                if !last_was_held || new_player == held_player  return;
            }
            slot = held_part.slot;
            release_slot(held_part);
            if slot.twin.part  release_slot(slot.twin.part);
        }
        assign_slot(new_player, new_part, slot);
    }
}

// Whether a part wants a channel: melodic, and not silenced by its own or its player's volume.
is_part_audible :: (p: *Player, part: *Part) -> bool {
    return part.has_program && p.group_volume && part.trim && part.volume;
}

get_free_slot :: () -> *Slot {
    for * out_channels  if !it.sides[0].player && !it.sides[1].player  return *it.sides[0];
    return null;
}

assign_slot :: (p: *Player, part: *Part, slot: *Slot) {
    part.slot   = slot;
    slot.player = p;
    slot.part   = part;
    set_out_program(slot, part.program);
    set_out_priority(slot, part.total_priority);
    set_out_note_req(slot, part.note_req);
    set_out_volume(slot, part.final_volume);
    set_out_pan(slot, part.pan);
    set_out_modulation(slot, part.modulation);
    set_out_detune(slot, part.detune);
    set_slot_pedal(slot, part.pedal);
}

release_slot :: (part: *Part) {
    slot := part.slot;
    if !slot return;
    silence_slot(slot);
    slot.player = null;
    slot.part   = null;
    part.slot   = null;
}

start_slot_note :: (slot: *Slot, key: u8, velocity: u8) {
    channel := slot.out.channel;
    if !slot.keys_on[key] {
        slot.keys_on[key] = true;
        if !slot.keys_pedal[key] {
            send_note_on(channel, key, velocity);
            return;
        }
        slot.keys_pedal[key] = false;
    }
    // Already sounding: restart it.
    send_note_off(channel, key);
    send_note_on(channel, key, velocity);
}

stop_slot_note :: (slot: *Slot, key: u8) {
    if !slot.keys_on[key] return;
    slot.keys_on[key] = false;
    if slot.pedal  slot.keys_pedal[key] = true;
    else           send_note_off(slot.out.channel, key);
}

set_slot_pedal :: (slot: *Slot, value: int) {
    if !slot return;
    slot.pedal = value;
    if value return;
    for key: 0..127 {
        if !slot.keys_pedal[key] continue;
        slot.keys_pedal[key] = false;
        send_note_off(slot.out.channel, xx key);
    }
}

silence_slot :: (slot: *Slot) {
    if !slot return;
    slot.pedal = 0;
    for key: 0..127 {
        if slot.keys_on[key] {
            send_note_off(slot.out.channel, xx key);
            slot.keys_on[key] = false;
        } else if slot.keys_pedal[key] {
            send_note_off(slot.out.channel, xx key);
            slot.keys_pedal[key] = false;
        }
    }
}

set_out_program :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.program return;
    slot.out.program = value;
    send_program(slot.out.channel, value);
}

set_out_priority :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.priority return;
    slot.out.priority = value;
    send_control(slot.out.channel, CC_PRIORITY, value);
}

set_out_note_req :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.note_req return;
    slot.out.note_req = value;
    send_control(slot.out.channel, CC_NOTE_REQ, value);
}

set_out_volume :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.volume return;
    slot.out.volume = value;
    send_control(slot.out.channel, CC_VOLUME, value);
}

set_out_pan :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.pan return;
    slot.out.pan = value;
    send_control(slot.out.channel, CC_PAN, value);
}

set_out_modulation :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.modulation return;
    slot.out.modulation = value;
    send_control(slot.out.channel, CC_MODULATION, value);
}

set_out_detune :: (slot: *Slot, value: int) {
    if !slot || value == slot.out.detune return;
    slot.out.detune = value;
    send_detune(slot.out.channel, value);
}

send_note_on :: (channel: u8, key: u8, velocity: u8) {
    fm_send_midi(MIDI_NOTE_ON | channel, key, velocity);
}

send_note_off :: (channel: u8, key: u8) {
    fm_send_midi(MIDI_NOTE_OFF | channel, key, 0);
}

send_control :: (channel: u8, controller: u8, value: int) {
    fm_set_control(channel, controller, value);
}

send_program :: (channel: u8, program: int) {
    fm_send_midi(MIDI_PROGRAM_CHANGE | channel, cast,trunc(u8) program);
}

// The driver gets the detune as a pitch bend, two units per detune step around 0x2000.
send_detune :: (channel: u8, detune: int) {
    value := detune * 2 + 0x2000;
    fm_send_midi(MIDI_PITCH_BEND | channel, cast,trunc(u8) (value & 0x7F), cast,trunc(u8) ((value >> 7) & 0x7F));
}

CC_MODULATION    :: 1;
CC_VOLUME        :: 7;
CC_PAN           :: 10;
CC_BEND_RANGE    :: 16;
CC_NOTE_REQ      :: 17;
CC_PRIORITY      :: 18;
CC_PEDAL         :: 64;
CC_ALL_NOTES_OFF :: 123;

#import "Basic";
#import "engine/dfFm";
