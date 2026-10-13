// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Players: two, each playing one song. The list order (newest first) is part of the behavior,
// since part allocation walks it and settles ties by it.

#scope_module

Player :: struct {
    song:   Imuse_Song;  // 0 while free.
    seq:    Sequence;
    shared: *Player;     // The song whose parts this one's share output channels with.

    priority:     int;
    volume:       int;
    hook:         int;
    marker:       int;  // Last marker's id; MARKER_TEXT for text markers, -1 before any.
    group_volume: int;  // Volume scaled by the music group's.
    pan:          int;
    detune:       int;
    transpose:    int;

    parts: [IMUSE_PARTS] Part;

    // For tools and tests.
    jumps:       int;
    notes:       int;
    marker_text: [MARKER_MAX] u8;
}

players:      [IMUSE_PLAYERS] Player;
player_list:  [IMUSE_PLAYERS] *Player;  // Playing ones, newest first.
player_count: int;

find_player :: (song: Imuse_Song) -> *Player {
    if !song return null;
    for i: 0..player_count-1  if player_list[i].song == song  return player_list[i];
    return null;
}

start_player :: (song: Imuse_Song, requested_priority: int) -> bool {
    priority := clamp(requested_priority, 0, 127);
    p := get_free_player(priority);
    if !p return false;

    p.* = .{};
    p.priority     = priority;
    p.volume       = 127;
    p.group_volume = music_volume;
    p.pan          = 64;
    p.marker       = -1;
    for * p.parts {
        it.* = .{};
        it.total_priority = p.priority;
        it.final_volume   = p.group_volume;
    }

    p.seq.player = p;
    if !start_sequence(*p.seq, *songs[song - 1].gmd) return false;
    p.song = song;

    for < i: 1..player_count  player_list[i] = player_list[i - 1];
    player_list[0] = p;
    player_count += 1;
    return true;
}

// Takes a free player. With both busy, the original releases the one with the lowest priority
// (the oldest of equals) if the new song's is at least as high.
get_free_player :: (priority: int) -> *Player {
    for * players  if !it.song  return it;

    lowest: *Player;
    lowest_priority := 127;
    for i: 0..player_count-1 {
        p := player_list[i];
        if p.priority <= lowest_priority {
            lowest = p;
            lowest_priority = p.priority;
        }
    }
    if !lowest || lowest_priority > priority return null;
    release_player(lowest);
    return lowest;
}

release_player :: (p: *Player) {
    if !p.song return;

    for i: 0..player_count-1 {
        if player_list[i] != p continue;
        for j: i..player_count-2  player_list[j] = player_list[j + 1];
        player_count -= 1;
        player_list[player_count] = null;
        break;
    }

    clear_fades(p.song);
    clear_triggers(p.song, IMUSE_ANY, null);
    forget_sustained_notes(p);
    for * p.parts  release_slot(it);
    p.song = 0;
    advance_stopped = true;
    if p.shared {
        p.shared.shared = null;
        p.shared = null;
    }
    allocate_parts();
}
