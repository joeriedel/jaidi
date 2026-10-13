// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The sequencer clock follows the original's integer math so songs keep the same timing:
// positions pack measure, beat and tick into one integer, and each interrupt advances a 16.16
// fixed-point tick count derived from the tempo.

#scope_module

Sequence :: struct {
    player: *Player;
    gmd:    *Gmd;

    chunk:     int;  // 0-based.
    at:        int;  // Offset of the next event in the chunk.
    cur_tick:  int;  // Position of that event.
    next_tick: int;  // Position playback has reached.

    tick_accum: int;  // 16.16 fraction of a tick.
    tempo:      int;  // Microseconds per beat.
    step:       int;  // 16.16 ticks per interrupt at speed 128.
    speed:      int;
    step_fixed: int;

    ticks_per_beat:    int;
    beats_per_measure: int;  // In the beat field's position (<< 16).
}

start_sequence :: (seq: *Sequence, gmd: *Gmd) -> bool {
    seq.gmd = gmd;
    seq.tick_accum = 0;
    seq.speed = 128;
    set_tempo(seq, 500000);  // 120 BPM until the song says otherwise.
    seq.ticks_per_beat    = 480;
    seq.beats_per_measure = 4 << 16;
    return set_sequence(seq, 0);
}

// Advances by one interrupt and plays what falls in it.
tick_sequence :: (seq: *Sequence) {
    seq.tick_accum += seq.step_fixed;
    seq.next_tick  += seq.tick_accum >> 16;
    seq.tick_accum &= 0xFFFF;
    if seq.next_tick & 0xFFFF >= seq.ticks_per_beat  seq.next_tick = fixup(seq, seq.next_tick);

    if seq.cur_tick < seq.next_tick  advance(seq, .PLAY);
}

// Reduces both terms below 2^16 before dividing, as the original does; this rounding is part
// of the song timing.
set_tempo :: (seq: *Sequence, tempo: int) {
    if tempo <= 0 return;
    ticks := IMUSE_TICK_US * 480;
    t := tempo;
    while (ticks & 0xFFFF0000) || (t & 0xFFFF0000) {
        ticks >>= 1;
        t >>= 1;
    }
    if t == 0 return;
    seq.tempo = tempo;
    seq.step  = (ticks << 16) / t;
    seq.step_fixed = (seq.speed * seq.step) >> 7;
}

set_sequence :: (seq: *Sequence, chunk: int) -> bool {
    if chunk < 0 || chunk >= seq.gmd.chunk_count return false;
    delta, at, ok := read_vlq(seq.gmd.chunks[chunk], 0);
    if !ok return false;
    seq.chunk     = chunk;
    seq.at        = at;
    seq.cur_tick  = fixup(seq, delta);
    seq.next_tick = 0;
    return true;
}

// Carries ticks into beats and beats into measures. Beats only carry along with a tick carry,
// as in the original.
fixup :: (seq: *Sequence, value: int) -> int {
    v := value;
    while v & 0xFFFF >= seq.ticks_per_beat {
        v = v - seq.ticks_per_beat + (1 << 16);
        while v & 0xF0000 >= seq.beats_per_measure  v = v - seq.beats_per_measure + (1 << 20);
    }
    return v;
}

Advance_Mode :: enum u8 {
    PLAY;  // Send everything.
    SEEK;  // Fast-forward for a jump: only tempo, time signature and the end of track count.
}

// Set when a sequence must stop where it is: a jump replaced its state, its player was
// released, or (while seeking) the track ended. The original keeps one such flag for all
// players and checks it after every meta and sysex event, so a trigger that jumps or stops a
// song from inside the event loop ends that loop, without saving its position. Mirrored as is.
advance_stopped: bool;

// Plays the events from cur_tick up to next_tick. Returns false if it stopped early.
advance :: (seq: *Sequence, mode: Advance_Mode) -> bool {
    advance_stopped = false;
    track := seq.gmd.chunks[seq.chunk];
    at    := seq.at;
    tick  := seq.cur_tick;

    while tick < seq.next_tick {
        if at >= track.count return stop_damaged(seq);
        status := track[at];

        if status < 0x80 {
            // Stray data byte; STALK-04 and STALK-10 end a track this way.
            return stop_damaged(seq);
        } else if status < 0xF0 {
            size := MESSAGE_SIZE[(status >> 4) & 7];
            if at + size > track.count return stop_damaged(seq);
            if mode == .PLAY  play_channel_message(seq.player, status, track[at + 1], ifx size == 3 then track[at + 2] else 0);
            at += size;
        } else if status == 0xFF {
            if at + 2 > track.count return stop_damaged(seq);
            kind := track[at + 1];
            length, body, ok := read_vlq(track, at + 2);
            if !ok || body + length > track.count return stop_damaged(seq);
            if kind == {
                case META_END_OF_TRACK;
                    // Playing, the song is over; seeking, the jump failed.
                    if mode == .PLAY  release_player(seq.player);
                    advance_stopped = true;
                case META_TEMPO;
                    if length >= 3  set_tempo(seq, ((cast(int) track[body]) << 16) | ((cast(int) track[body + 1]) << 8) | track[body + 2]);
                case META_TIME_SIGNATURE;
                    if length >= 2 && track[body + 1] >= 1 {
                        seq.ticks_per_beat    = 960 >> (track[body + 1] - 1);
                        seq.beats_per_measure = (cast(int) track[body]) << 16;
                    }
            }
            at = body + length;
            if advance_stopped return false;
        } else if status == 0xF0 {
            length, body, ok := read_vlq(track, at + 1);
            if !ok || body + length > track.count return stop_damaged(seq);
            if mode == .PLAY  handle_sysex(seq, array_view(track, body, length));
            at = body + length;
            if advance_stopped return false;
        } else {
            return stop_damaged(seq);
        }

        delta, next_at, ok := read_vlq(track, at);
        if !ok return stop_damaged(seq);
        at = next_at;
        tick += delta;
        if tick & 0xFFFF >= seq.ticks_per_beat  tick = fixup(seq, tick);
    }

    seq.cur_tick = tick;
    seq.at = at;
    return true;
}

// The original releases the player when its data turns out damaged, even mid-jump.
stop_damaged :: (seq: *Sequence) -> bool {
    release_player(seq.player);
    advance_stopped = true;
    return false;
}

handle_sysex :: (seq: *Sequence, body: [] u8) {
    if body.count < 2 || body[0] != IMUSE_SYSEX_ID return;
    p := seq.player;
    if body[1] == {
        case SYSEX_MARKER;
            if body.count < 3 return;
            fire_triggers(p, .{id = body[2]});
        case SYSEX_JUMP;
            if body.count < 10 return;
            if !take_hook(p, body[2]) return;
            d := body.data + 3;
            jump(seq, d[0], ((cast(int) d[1]) << 7) | d[2], d[3], ((cast(int) d[4]) << 7) | d[5], d[6] != 0);
        case SYSEX_TEXT_MARKER;
            fire_triggers(p, .{id = MARKER_TEXT, text = get_marker_text(array_view(body, 2, body.count - 2))});
    }
}

// A jump with hook h is taken only when the player's hook is h, which it then clears. A jump
// with hook 0 is taken unless the player's hook is 0x80, which skips one and clears.
take_hook :: (p: *Player, hook: u8) -> bool {
    if hook {
        if hook != p.hook return false;
        p.hook = 0;
        return true;
    }
    if p.hook == HOOK_SKIP_NEXT {
        p.hook = 0;
        return false;
    }
    return true;
}

// The text runs to its terminating zero, or the end of the sysex.
get_marker_text :: (bytes: [] u8) -> string {
    n := 0;
    while n < bytes.count && bytes[n] != 0 && bytes[n] != 0xF7  n += 1;
    return .{n, bytes.data};
}

// 1-based chunk, measure and beat, as in the files. With sustain, notes ring on through the
// jump (see sustain.jai); without, they're cut. Returns false, changing nothing, when the
// target is invalid.
jump :: (seq: *Sequence, chunk: int, measure: int, beat: int, tick: int, sustain: bool) -> bool {
    m, b, c := measure - 1, beat - 1, chunk - 1;
    if m < 0 || m >= 1000 || b < 0 || b >= 12 || tick >= 480 return false;

    next := seq.*;
    target := fixup(*next, (m << 20) + (b << 16) + tick);
    if c != next.chunk || target < next.next_tick {
        if !set_sequence(*next, c) return false;
    }
    next.next_tick = target;
    if !advance(*next, .SEEK) return false;

    p := seq.player;
    if sustain {
        for * p.parts {
            change_part_control(p, it, CC_PEDAL, 0);
            change_part_control(p, it, CC_MODULATION, 0);
            bend_part(p, it, 0, 0x40);
        }
        // Before the jump, the sequence still stands where this interrupt began, as in the
        // original: the scan for note-offs starts there.
        sustain_through_jump(p, seq, *next);
    } else {
        stop_all_part_notes(p);
    }
    p.jumps += 1;
    seq.* = next;
    advance_stopped = true;
    return true;
}

read_vlq :: (bytes: [] u8, at: int) -> value: int, next: int, ok: bool {
    value := 0;
    i := at;
    for 1..4 {
        if i >= bytes.count return 0, i, false;
        b := bytes[i];
        i += 1;
        value = (value << 7) | (b & 0x7F);
        if !(b & 0x80) return value, i, true;
    }
    return value, i, true;
}

// Bytes in a channel message, by (status >> 4) & 7.
MESSAGE_SIZE :: int.[3, 3, 3, 3, 2, 2, 3, 0];

META_END_OF_TRACK   :: 0x2F;
META_TEMPO          :: 0x51;
META_TIME_SIGNATURE :: 0x58;

IMUSE_SYSEX_ID     :: 0x7D;
SYSEX_MARKER       :: 0;  // A one-byte marker id.
SYSEX_JUMP         :: 1;
SYSEX_TEXT_MARKER  :: 3;

HOOK_SKIP_NEXT :: 0x80;

#import "Basic";
