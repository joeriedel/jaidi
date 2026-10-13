// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Triggers, delayed stops and fades, as the original runs them. Triggers fire from inside a
// song's event loop when it reaches a marker. Delayed stops and fades count in frames of a
// 60 Hz clock that runs off the sequencer interrupt. Fades work on songs' volume and on any
// parameter of a digital sound.

#scope_module

Trigger :: struct {
    song:   Imuse_Song;  // 0 while free.
    marker: int;
    proc:   Imuse_Trigger_Proc;
}

Delayed_Stop :: struct {
    frames: int;  // 0 while free.
    song:   Imuse_Song;
}

Fade :: struct {
    active:    bool;
    song:      Imuse_Song;  // Or a digital sound.
    param:     Imuse_Param;
    value:     int;
    target:    int;  // For tools.
    frames:    int;  // Length of the whole fade.
    remaining: int;
    step:      int;  // Change per frame, rounded toward zero...
    remainder: int;  // ...and what that leaves over, spread out as single extra steps.
    error:     int;
    direction: int;
}

triggers:      [16] Trigger;
delayed_stops: [8] Delayed_Stop;
fades:         [16] Fade;

frame_time_us: int;  // Toward the next 60 Hz frame.

FRAME_US :: 16667;

clear_triggers_and_timers :: () {
    for * triggers       it.* = .{};
    for * delayed_stops  it.* = .{};
    for * fades          it.* = .{};
    frame_time_us = 0;
}

// Runs the triggers set on the player's song for this marker. Each fires once; a trigger may
// set itself again, and the slot it frees is the first a new one takes, so it can't fire twice
// for one marker.
fire_triggers :: (p: *Player, marker: Imuse_Marker) {
    p.marker = marker.id;
    set_marker_text(p, marker);
    // A trigger takes any marker (0), one id, or text markers (MARKER_TEXT, which also takes
    // stray ids past 7 bits).
    wanted := ifx marker.id < MARKER_TEXT then marker.id else MARKER_TEXT;
    for * triggers {
        if !it.song || it.song != p.song continue;
        if it.marker != 0 && it.marker != wanted continue;
        proc := it.proc;
        it.song = 0;
        proc(p.song, marker);
    }
}

// Called every interrupt.
tick_frame_clock :: () {
    frame_time_us += IMUSE_TICK_US;
    while frame_time_us >= FRAME_US {
        frame_time_us -= FRAME_US;
        tick_fades();
        tick_delayed_stops();
    }
}

// The value moves every frame, but reaches the song only on every sixth, counted down from
// the end: the original's way of sparing the driver.
tick_fades :: () {
    for * fades {
        if !it.active continue;
        it.remaining -= 1;
        if it.remaining == 0  it.active = false;

        value := it.value + it.step;
        it.error += it.remainder;
        if it.error >= it.frames {
            it.error -= it.frames;
            value += it.direction;
        }
        if value == it.value continue;
        it.value = value;
        if it.remaining % 6 != 0 continue;

        if it.param == .VOLUME && value == 0  stop_sound(it.song);
        else                                  set_sound_param(it.song, it.param, value);
    }
}

tick_delayed_stops :: () {
    for * delayed_stops {
        if !it.frames continue;
        it.frames -= 1;
        if !it.frames  stop_song(it.song);
    }
}

start_fade :: (song: Imuse_Song, target: int, frames: int) -> bool {
    return start_param_fade(song, .VOLUME, target, frames);
}

// From the parameter's value now. A song's only parameter here is its volume.
start_param_fade :: (sound: Imuse_Song, param: Imuse_Param, target: int, frames: int) -> bool {
    value, ok := get_sound_param(sound, param);
    if !ok return false;
    clear_fades(sound, xx param);
    if frames == 0 {
        if param == .VOLUME && target == 0  stop_sound(sound);
        else                                set_sound_param(sound, param, target);
        return true;
    }

    for * fades {
        if it.active continue;
        change := target - value;
        it.* = .{active = true, song = sound, param = param, value = value, target = target, frames = frames, remaining = frames};
        it.step      = change / frames;
        it.direction = ifx change >= 0 then 1 else -1;
        it.remainder = abs(change) % frames;
        return true;
    }
    return false;
}

// IMUSE_ANY and a null proc match anything.
clear_triggers :: (song: Imuse_Song, marker: int, proc: Imuse_Trigger_Proc) {
    for * triggers  if is_matching_trigger(it, song, marker, proc)  it.song = 0;
}

is_matching_trigger :: (t: *Trigger, song: Imuse_Song, marker: int, proc: Imuse_Trigger_Proc) -> bool {
    return t.song && (song == IMUSE_ANY || song == t.song) && (marker == IMUSE_ANY || marker == t.marker) &&
           (!proc || proc == t.proc);
}

// IMUSE_ANY for every parameter.
clear_fades :: (song: Imuse_Song, param: int = IMUSE_ANY) {
    for * fades  if it.active && it.song == song && (param == IMUSE_ANY || param == xx it.param)  it.active = false;
}

stop_sound :: (sound: Imuse_Song) {
    if is_digital(sound)  imuse_stop_digital(sound);
    else                  stop_song(sound);
}

get_sound_param :: (sound: Imuse_Song, param: Imuse_Param) -> int, bool {
    if is_digital(sound) {
        value, ok := get_digital_param(sound, param);
        return value, ok;
    }
    p := find_player(sound);
    if !p || param != .VOLUME return 0, false;
    return p.volume, true;
}

set_sound_param :: (sound: Imuse_Song, param: Imuse_Param, value: int) {
    if is_digital(sound)    set_digital_param(sound, param, value);
    else if param == .VOLUME  set_song_volume(sound, value);
}

stop_song_later :: (song: Imuse_Song, frames: int) -> bool {
    for * delayed_stops {
        if it.frames continue;
        it.* = .{frames, song};
        return true;
    }
    return false;
}

stop_song :: (song: Imuse_Song) {
    p := find_player(song);
    if p  release_player(p);
}

set_song_volume :: (song: Imuse_Song, volume: int) {
    p := find_player(song);
    if !p || volume < 0 || volume > 127 return;
    p.volume = volume;
    p.group_volume = (music_volume * (volume + 1)) >> 7;
    for * p.parts  update_part_volume(p, it);
}

set_marker_text :: (p: *Player, marker: Imuse_Marker) {
    text := ifx marker.id == MARKER_TEXT then marker.text else tprint("#%", marker.id);
    n := min(text.count, MARKER_MAX - 1);
    memcpy(p.marker_text.data, text.data, n);
    p.marker_text[n] = 0;
}

#import "Basic";
#import "Math";
