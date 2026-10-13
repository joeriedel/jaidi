// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Notes that ring on through a jump, as the original does it. When a song jumps with its
// sustain flag set, every note it's holding keeps sounding until the moment its note-off would
// have come had the song not jumped, found by reading ahead from where it was. If the music at
// the jump target strikes the same key on the same part first, the held note is cut 10 ticks
// before that. Held notes count down at their song's tempo.

#scope_module

Sustained_Note :: struct {
    player:   *Player;
    part:     int;
    key:      int;
    ticks:    int;  // Until its note-off.
    fraction: int;  // 16.16 remainder of the countdown.
}

MAX_SUSTAINED :: 24;

sustained:       [MAX_SUSTAINED] Sustained_Note;
sustained_count: int;  // In use, newest first.

// Called with the player's state from before the jump and after it (the target found).
sustain_through_jump :: (p: *Player, before: *Sequence, after: *Sequence) {
    part_channels: [IMUSE_PARTS] u16;  // Each part's output channel, as a bit.
    for * part, i: p.parts  if part.slot  part_channels[i] = cast(u16) (1 << part.slot.out.channel);

    // Notes the player holds now that aren't already ringing on from an earlier jump.
    held: [128] u16;
    count := get_held_keys(p, *held);
    for i: 0..sustained_count-1 {
        if !count break;
        s := *sustained[i];
        if s.player != p || !(held[s.key] & part_channels[s.part]) continue;
        held[s.key] &= ~part_channels[s.part];
        count -= 1;
    }

    if count {
        scan := Sustain_Scan.{player = p, held = *held, count = count, part_channels = *part_channels};
        scan_ahead(before, *scan, .FIND_NOTE_OFFS);
        if scan.count {
            // Note-offs the song doesn't reach; the original cuts these now.
            for key: 0..127 {
                if !held[key] continue;
                for part: 0..IMUSE_PARTS-1  if held[key] & part_channels[part]  stop_part_note(*p.parts[part], xx key);
            }
        }
    }

    longest := 0;
    for i: 0..sustained_count-1  longest = max(longest, sustained[i].ticks);

    for * held  it.* = 0;
    count = get_held_keys(p, *held);
    scan := Sustain_Scan.{player = p, held = *held, count = count, part_channels = *part_channels, longest = longest};
    scan_ahead(after, *scan, .FIND_RESTRIKES);
}

// Counts the held notes down by one interrupt, at their own song's tempo, and ends the ones
// that run out.
tick_sustained_notes :: () {
    i := 0;
    while i < sustained_count {
        s := *sustained[i];
        s.fraction += s.player.seq.step_fixed;
        s.ticks    -= s.fraction >> 16;
        s.fraction &= 0xFFFF;
        if s.ticks < 0 {
            p, part, key := s.player, s.part, s.key;
            remove_sustained(i);
            stop_part_note(*p.parts[part], xx key);
        } else {
            i += 1;
        }
    }
}

// Forgets a released player's held notes; releasing its parts already silenced them.
forget_sustained_notes :: (p: *Player) {
    i := 0;
    while i < sustained_count {
        if sustained[i].player == p  remove_sustained(i);
        else                         i += 1;
    }
}

clear_sustained_notes :: () {
    sustained_count = 0;
}

#scope_file

Scan_Mode :: enum u8 {
    FIND_NOTE_OFFS;  // From before the jump: when each held note would have ended.
    FIND_RESTRIKES;  // From the target: held notes struck again before they end.
}

Sustain_Scan :: struct {
    player:        *Player;
    held:          *[128] u16;  // Per key, the output channels still to account for.
    count:         int;
    part_channels: *[IMUSE_PARTS] u16;
    longest:       int;  // FIND_RESTRIKES stops past the longest held note.
    ticks:         int;  // Distance of the current event from the position reached.
    done:          bool;
}

// Reads events from where the sequence stands, without playing them, until the scan is done or
// the track ends.
scan_ahead :: (seq: *Sequence, scan: *Sustain_Scan, mode: Scan_Mode) {
    track := seq.gmd.chunks[seq.chunk];
    at := seq.at;
    scan.ticks = get_tick_distance(seq, seq.cur_tick, seq.next_tick);

    while !scan.done {
        if at >= track.count return;
        status := track[at];
        if status < 0x80 {
            return;
        } else if status < 0xF0 {
            size := MESSAGE_SIZE[(status >> 4) & 7];
            if at + size > track.count return;
            kind, part, key := status & 0xF0, cast(int) (status & 0x0F), track[at + 1];
            velocity := ifx size == 3 then track[at + 2] else 0;
            if mode == .FIND_NOTE_OFFS {
                if kind == MIDI_NOTE_OFF || (kind == MIDI_NOTE_ON && velocity == 0)  sustain_note(scan, part, key);
            } else if kind == MIDI_NOTE_ON {
                cut_restruck_note(scan, part, key);
            }
            at += size;
        } else if status == 0xFF || status == 0xF0 {
            header := ifx status == 0xFF then at + 2 else at + 1;
            if header > track.count return;
            if status == 0xFF && track[at + 1] == META_END_OF_TRACK  scan.done = true;
            length, body, ok := read_vlq(track, header);
            if !ok || body + length > track.count return;
            at = body + length;
        } else {
            return;
        }

        delta, next_at, ok := read_vlq(track, at);
        if !ok return;
        at = next_at;
        scan.ticks += delta;
    }
}

// A held note's note-off: it rings on until then.
sustain_note :: (scan: *Sustain_Scan, part: int, key: u8) {
    channel := scan.part_channels.*[part];
    if !(scan.held.*[key] & channel) return;
    scan.held.*[key] &= ~channel;
    scan.count -= 1;
    if !scan.count  scan.done = true;
    if sustained_count == MAX_SUSTAINED return;  // The original drops it, and the note sounds on.

    for < i: 1..sustained_count  sustained[i] = sustained[i - 1];
    sustained[0] = .{player = scan.player, part = part, key = key, ticks = scan.ticks};
    sustained_count += 1;
}

// A held note struck again: it ends 10 ticks before.
cut_restruck_note :: (scan: *Sustain_Scan, part: int, key: u8) {
    if scan.ticks > scan.longest {
        scan.done = true;
        return;
    }
    channel := scan.part_channels.*[part];
    if !(scan.held.*[key] & channel) return;
    scan.held.*[key] &= ~channel;
    for i: 0..sustained_count-1 {
        s := *sustained[i];
        if s.player != scan.player || s.part != part || s.key != key || scan.ticks - 10 > s.ticks continue;
        s.ticks = scan.ticks - 10;
        break;
    }
}

// The output channels holding each key for the player, on either side, and how many there are.
get_held_keys :: (p: *Player, held: *[128] u16) -> int {
    count := 0;
    for * out: out_channels {
        for * side: out.sides {
            if side.player != p continue;
            for key: 0..127 {
                if !side.keys_on[key] continue;
                held.*[key] |= cast(u16) (1 << out.channel);
                count += 1;
            }
        }
    }
    return count;
}

remove_sustained :: (i: int) {
    for j: i..sustained_count-2  sustained[j] = sustained[j + 1];
    sustained_count -= 1;
}

// The distance in ticks from position b to position a, the original's way. Its measure term
// multiplies by the beats-per-measure field still shifted left 16, wrapping at 32 bits, so
// across a measure boundary the distance comes out enormous: a note held through such a jump
// rings on until it's struck again or its song stops. Kept as is.
get_tick_distance :: (seq: *Sequence, a: int, b: int) -> int {
    per_measure := cast,trunc(u32) (seq.ticks_per_beat * seq.beats_per_measure);
    get_ticks :: (t: int) -> u32 #expand {
        measures := cast,trunc(u32) ((cast(u64) (t >> 20)) * per_measure);
        return cast,trunc(u32) ((t & 0xFFFF) + measures + ((t >> 16) & 0xF) * seq.ticks_per_beat);
    }
    return cast,no_check(s32) (get_ticks(a) - get_ticks(b));
}

#import "Basic";
#import "engine/dfFm";
