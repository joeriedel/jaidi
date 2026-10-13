// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// iMUSE music. Songs are GMD files, loaded by name into a small table. Up to two play at once,
// each through its own player: a sequencer (tempo, measure/beat/tick clock, jumps, markers) and
// 16 parts, one per MIDI channel in the file. Parts don't own output channels. The FM driver has
// 15 melodic ones (0-8 and 10-15), which go to the highest-priority parts of both players;
// a part that never got a program change plays drums on channel 9.
//
// Behavior here follows the original engine, checked against its code: part allocation, the
// volume and priority math and the sequencer's integer timing. Keep it that way.
//
// Songs talk back through markers: a trigger set on a song runs once when the song reaches a
// marker it matches. Jumps in a song can wait on a hook the game sets. Stops can be delayed and
// volumes faded, counted in 60 Hz frames.
// A jump can let the notes sounding at that moment ring on into the music it jumps to, and two
// songs can share parts, so that one takes over from the other on the same output channels.
//
// Digital sounds (VOC) play on their own tracks and are mixed as the original mixed them for
// the Sound Blaster 16; see digital.jai.
//
// imuse_tick and imuse_mix_digital run on the audio thread. Call everything else under
// audio_lock.

IMUSE_TICK_US   :: 6944;  // The original's sequencer interrupt period, about 144 Hz.
IMUSE_MAX_SONGS :: 16;
IMUSE_PLAYERS   :: 2;
IMUSE_PARTS     :: 16;

Imuse_Song :: s32;  // 0 is no song.

IMUSE_ANY :: -1;  // Wildcard for songs and markers.

// Markers carry either a one-byte id or text; text markers have the id MARKER_TEXT.
Imuse_Marker :: struct {
    id:   int;
    text: string;  // Points into the song's data.
}

MARKER_TEXT :: 0x80;

// Runs on the audio thread, inside the song's event loop, so it calls imuse_* directly, without
// audio_lock. It may set itself again.
Imuse_Trigger_Proc :: #type (song: Imuse_Song, marker: Imuse_Marker);

// Resets everything and sets up the FM driver's channels. Call before anything else.
imuse_init :: () {
    fm_reset();
    for * songs  it.* = .{};
    song_count = 0;
    music_volume = 127;
    paused = false;
    for * players  it.* = .{};
    for * player_list  it.* = null;
    player_count = 0;
    clear_triggers_and_timers();
    clear_sustained_notes();
    init_out_channels();
    stop_all_digital();
    digital.mixed_at = digital.mixed.count;
}

// Loads NAME.GMD from the mounted GOBs, or returns the song if it's already loaded. 0 when the
// file is missing or damaged, or the table is full.
imuse_load_midi :: (name: string) -> Imuse_Song {
    song := imuse_find_midi(name);
    if song return song;
    data, found := gob_find(tprint("%.GMD", name));
    if !found return 0;
    return imuse_load_midi_from_memory(name, data);
}

// Loads a song from memory. 'data' must stay valid until imuse_unload_all (GOB and LFD entries
// do while their archive stays open).
imuse_load_midi_from_memory :: (name: string, data: [] u8) -> Imuse_Song {
    if song_count == IMUSE_MAX_SONGS || name.count > SONG_NAME_MAX return 0;
    gmd, ok := gmd_parse(data);
    if !ok return 0;
    s := *songs[song_count];
    s.gmd = gmd;
    memcpy(s.name.data, name.data, name.count);
    s.name_count = name.count;
    song_count += 1;
    return xx song_count;
}

imuse_find_midi :: (name: string) -> Imuse_Song {
    for 0..song_count-1 {
        if equal_nocase(get_song_name(*songs[it]), name)  return xx (it + 1);
    }
    return 0;
}

// Stops everything first.
imuse_unload_all :: () {
    imuse_stop_all();
    song_count = 0;
}

// Priority 0-127 decides which song's parts get output channels, and which player is taken
// when both are busy. The game starts its songs at 64.
imuse_play :: (song: Imuse_Song, priority := 64) -> bool {
    if song <= 0 || song > song_count return false;
    return start_player(song, priority);
}

// After 'frames' 60 Hz frames, or now. False when the 8 delayed stops are all taken. A delayed
// stop counts down even if the song stops and starts again in between.
imuse_stop :: (song: Imuse_Song, frames := 0) -> bool {
    if frames <= 0 {
        stop_song(song);
        return true;
    }
    return stop_song_later(song, frames);
}

// Songs and digital sounds. Also drops every trigger, delayed stop and fade.
imuse_stop_all :: () {
    clear_triggers_and_timers();
    while player_count  release_player(player_list[0]);
    stop_all_digital();
}

// Jumps a playing song to a 1-based chunk, measure and beat. With sustain, the notes sounding
// ring on until they'd have ended. False when the song isn't playing or the target is invalid.
imuse_jump :: (song: Imuse_Song, chunk: int, measure: int, beat: int, tick: int, sustain := false) -> bool {
    p := find_player(song);
    if !p return false;
    return jump(*p.seq, chunk, measure, beat, tick, sustain);
}

// Pairs two playing songs' parts by MIDI channel: each part of one plays on the other side of
// the output channel its counterpart holds, so the new song takes over the old one's channels
// (and with them its voices) instead of competing for others. Lasts until either stops. False
// unless both are playing and neither shares already.
imuse_share_parts :: (a: Imuse_Song, b: Imuse_Song) -> bool {
    pa, pb := find_player(a), find_player(b);
    if !pa || !pb || pa == pb || pa.shared || pb.shared return false;
    pa.shared = pb;
    pb.shared = pa;
    allocate_parts();
    return true;
}

// Hooks hold back a song's jumps; see take_hook. 0-128 (HOOK_SKIP_NEXT skips one jump).
imuse_set_hook :: (song: Imuse_Song, hook: int) {
    p := find_player(song);
    if p && hook >= 0 && hook <= HOOK_SKIP_NEXT  p.hook = hook;
}

// marker: 0 for any, an id, or MARKER_TEXT for any text marker. The song needn't be playing.
// False when all 16 triggers are taken.
imuse_set_trigger :: (song: Imuse_Song, marker: int, proc: Imuse_Trigger_Proc) -> bool {
    if song <= 0 || !proc return false;
    for * triggers {
        if it.song continue;
        it.* = .{song, marker, proc};
        return true;
    }
    return false;
}

// IMUSE_ANY and a null proc match anything.
imuse_count_triggers :: (song: Imuse_Song = IMUSE_ANY, marker := IMUSE_ANY, proc: Imuse_Trigger_Proc = null) -> int {
    count := 0;
    for * triggers  if is_matching_trigger(it, song, marker, proc)  count += 1;
    return count;
}

imuse_clear_triggers :: (song: Imuse_Song = IMUSE_ANY, marker := IMUSE_ANY, proc: Imuse_Trigger_Proc = null) {
    clear_triggers(song, marker, proc);
}

// 1-based chunk, measure and beat, as in the files. ok is false when the song isn't playing.
imuse_get_position :: (song: Imuse_Song) -> chunk: int, measure: int, beat: int, tick: int, ok: bool {
    p := find_player(song);
    if !p return 0, 0, 0, 0, false;
    t := p.seq.next_tick;
    return p.seq.chunk + 1, (t >> 20) + 1, ((t >> 16) & 0xF) + 1, t & 0xFFFF, true;
}

// Volume 0-127 of one playing song. A fade in progress carries on from the new volume.
imuse_set_volume :: (song: Imuse_Song, volume: int) {
    set_song_volume(song, volume);
}

// Over 'frames' 60 Hz frames. Reaching 0 stops the song. False when it isn't playing or all
// 16 fades are taken.
imuse_fade_volume :: (song: Imuse_Song, volume: int, frames: int) -> bool {
    if volume < 0 || volume > 127 || frames < 0 return false;
    return start_fade(song, volume, frames);
}

// Volume 0-127 of all music.
imuse_set_music_volume :: (volume: int) {
    if volume < 0 || volume > 127 return;
    music_volume = volume;
    for i: 0..player_count-1 {
        p := player_list[i];
        p.group_volume = ((p.volume + 1) * music_volume) >> 7;
        for * p.parts  update_part_volume(p, it);
    }
}

// Stops the music's clock and the digital tracks where they are, until imuse_resume; the
// game mutes the music first, so held notes don't sound.
imuse_pause :: () { paused = true; }

imuse_resume :: () { paused = false; }

imuse_get_music_volume :: () -> int { return music_volume; }

imuse_tick :: () {
    if paused return;
    // Copied, because a player that reaches its end releases itself and leaves the list.
    list := player_list;
    count := player_count;
    for i: 0..count-1  if list[i].song  tick_sequence(*list[i].seq);
    tick_sustained_notes();
    tick_frame_clock();
}

Imuse_Part_State :: struct {
    has_program: bool;  // False for parts that play drums.
    program:     int;
    priority:    int;   // The part's own plus its player's.
    volume:      int;   // As sent to the driver.
    channel:     int;   // Output channel, or -1 without one.
    shared:      bool;  // Playing on the second side of a channel another song's part also uses.
    held_notes:  int;   // Keys down on its channel side (drums aren't tracked).
}

Imuse_Player_State :: struct {
    song:     Imuse_Song;
    name:     string;  // Points into the song table.
    priority: int;
    volume:   int;
    chunk:    int;     // 1 is the song; higher chunks are transition pieces.
    measure:  int;     // 1-based, like iMUSE's jump targets.
    beat:     int;     // 1-based.
    tick:     int;
    tempo_us: int;     // Microseconds per beat.
    hook:     int;
    marker_id: int;    // Last marker's id: MARKER_TEXT for text, -1 before any.
    jumps:    int;
    notes:    int;
    sustained: int;    // Notes ringing on from a jump.
    trigger_markers: [16] int;  // Markers its triggers wait for (0 any, MARKER_TEXT any text).
    trigger_count:   int;
    stop_in:  int;     // Frames to its next delayed stop, or -1.
    fade_to:  int;     // Target of a fade in progress, or -1.
    fade_frames: int;  // Frames left of it.
    marker:   [MARKER_MAX] u8;  // Last marker as text ("#12" for ids), zero-terminated.
    parts:    [IMUSE_PARTS] Imuse_Part_State;
}

// Playing songs, newest first.
Imuse_Status :: struct {
    players:      [IMUSE_PLAYERS] Imuse_Player_State;
    player_count: int;
}

MARKER_MAX :: 32;

imuse_get_status :: () -> Imuse_Status {
    s: Imuse_Status;
    s.player_count = player_count;
    for i: 0..player_count-1 {
        p := player_list[i];
        ps := *s.players[i];
        ps.song     = p.song;
        ps.name     = get_song_name(*songs[p.song - 1]);
        ps.priority = p.priority;
        ps.volume   = p.volume;
        ps.chunk, ps.measure, ps.beat, ps.tick = imuse_get_position(p.song);
        ps.tempo_us = p.seq.tempo;
        ps.hook     = p.hook;
        ps.marker_id = p.marker;
        ps.jumps    = p.jumps;
        ps.notes    = p.notes;
        for j: 0..sustained_count-1  if sustained[j].player == p  ps.sustained += 1;
        for triggers  if it.song == p.song {
            ps.trigger_markers[ps.trigger_count] = it.marker;
            ps.trigger_count += 1;
        }
        ps.stop_in = -1;
        for delayed_stops  if it.frames && it.song == p.song && (ps.stop_in < 0 || it.frames < ps.stop_in)  ps.stop_in = it.frames;
        ps.fade_to = -1;
        for fades  if it.active && it.song == p.song {
            ps.fade_to     = it.target;
            ps.fade_frames = it.remaining;
        }
        ps.marker   = p.marker_text;
        for * part, j: p.parts {
            out := *ps.parts[j];
            out.has_program = part.has_program;
            out.program     = part.program;
            out.priority    = part.total_priority;
            out.volume      = part.final_volume;
            out.channel     = ifx part.slot then cast(int) part.slot.out.channel else -1;
            out.shared      = part.slot && part.slot != *part.slot.out.sides[0];
            if part.slot  for part.slot.keys_on  if it  out.held_notes += 1;
        }
    }
    return s;
}

#scope_module

SONG_NAME_MAX :: 12;

Song :: struct {
    gmd:        Gmd;
    name:       [SONG_NAME_MAX] u8;
    name_count: int;
}

songs:      [IMUSE_MAX_SONGS] Song;
song_count: int;

// Volume of the music group, 0-127.
music_volume: int = 127;
paused: bool;                   // imuse_pause.

get_song_name :: (s: *Song) -> string {
    return .{s.name_count, s.name.data};
}

#load "gmd.jai";
#load "sequencer.jai";
#load "players.jai";
#load "parts.jai";
#load "triggers.jai";
#load "sustain.jai";
#load "digital.jai";

#import "Basic";
#import "String";
#import "engine/dfArchive";
#import "engine/dfFm";
