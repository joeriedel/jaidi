// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Cutscene music. A scene can start one of CUTMUSE.TXT's sequences, which loads every song its
// cues name; the film's custom actor then sends cue points, each of which moves the music
// along: the first starts its song, later ones fade, stop, switch songs, release a held loop
// through its hook, or jump to a chunk and measure if the song hasn't got there yet.
//
// The iMUSE calls run under audio_lock: the music plays on the audio thread.

// Stops the music and forgets the sequence.
cutscene_music_stop :: () {
    audio_lock();
    defer audio_unlock();
    imuse_stop_all();
    imuse_unload_all();
    cut_music = .{};
}

#scope_module

set_music_sequence :: (id: s32) {
    if id == cut_music.sequence_id return;
    audio_lock();
    defer audio_unlock();
    imuse_stop_all();
    imuse_unload_all();
    cut_music = .{};
    cut_music.sequence_id = id;
    sequence := find_sequence(id);
    if !sequence return;
    for sequence.cues  imuse_load_midi(it.song);
}

set_music_cue :: (cue: s32) {
    sequence := find_sequence(cut_music.sequence_id);
    if !sequence || cue < 0 || cue > sequence.cues.count || cue == cut_music.cue return;
    audio_lock();
    defer audio_unlock();
    defer cut_music.cue = cue;

    if cue == 0 {
        imuse_stop_all();
        cut_music.saved_song = 0;
        return;
    }
    new := *sequence.cues[cue - 1];
    new_song := imuse_find_midi(new.song);
    if !cut_music.cue {
        imuse_play(new_song);
        cut_music.saved_song = new_song;
        return;
    }

    imuse_clear_triggers();
    old_song := imuse_find_midi(sequence.cues[cut_music.cue - 1].song);
    if !old_song  old_song = cut_music.saved_song;
    else          cut_music.saved_song = old_song;

    // Chunks are letters, A for 1.
    from_chunk: s32 = new.from_chunk;
    to_chunk:   s32 = new.to_chunk;
    if from_chunk > #char "@"  from_chunk -= #char "@";
    if to_chunk   > #char "@"  to_chunk   -= #char "@";

    if from_chunk == #char "Z" - #char "@" {
        imuse_stop(old_song);
        cut_music.saved_song = 0;
    } else if from_chunk == #char "?" {
        imuse_fade_volume(old_song, 0, 60 * (pick_random_seconds() + 1));
    } else if from_chunk == #char "." {
        imuse_fade_volume(old_song, 0, 120);
    } else if from_chunk == #char "!" {
        imuse_fade_volume(old_song, 0, 60);
    } else if from_chunk == #char "0" {
    } else if from_chunk == #char "1" || (new.from_measure == 0 && new.to_measure == 0) {
        if old_song != new_song {
            switch_songs(old_song, new_song);
        } else {
            // Lets the song take its next hook-1 jump, out of a loop.
            imuse_set_hook(old_song, 1);
        }
    } else if old_song != new_song {
        switch_songs(old_song, new_song);
    } else {
        // Jumps only if the song hasn't reached the cue's chunk and measure yet.
        chunk, measure := imuse_get_position(old_song);
        if chunk < from_chunk || (chunk == from_chunk && measure < new.from_measure) {
            imuse_jump(new_song, to_chunk, new.to_measure, 1, 0);
            imuse_set_hook(old_song, 0);
        }
    }
}

cut_music: struct {
    sequence_id: s32;
    cue:         s32;
    saved_song:  Imuse_Song;
};

#scope_file

switch_songs :: (old_song: Imuse_Song, new_song: Imuse_Song) {
    imuse_stop(old_song);
    imuse_play(new_song);
    imuse_set_hook(old_song, 0);
}

find_sequence :: (id: s32) -> *Music_Sequence {
    if id <= 0 return null;
    for * cut.sequences  if it.id == id  return it;
    return null;
}

// 0 to 2.
pick_random_seconds :: () -> s32 {
    return cast(s32) (random_get() % 3);
}

#import "Basic";
#import "Random";
#import "engine/dfAudio";
#import "engine/dfIMuse";
