// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Cutscene sounds: a film's VOIC objects, played through iMUSE's digital side at priority 64,
// as sound effects (group 1) or, with VAR2 set to 1, as voices (group 2). The sounds come from
// the scene's LFD or JEDISFX.LFD (BIGSFX.LFD where it exists), which stays open while
// cutscenes play.
//
// When a scene ends its sounds stop, except those marked to keep (VAR1 = 1): they play on
// through the next scene, and stop at its end.

Cut_Sound :: struct {
    id:   s32;          // iMUSE's id for it.
    name: string;
    data: [] u8;        // A copy of the VOC.
    var1, var2: s32;
    keep: bool;
}

#scope_module

open_sound_archive :: () -> bool {
    close_sound_archive();
    dark_dir := find_dark_data_dir();
    for string.["BIGSFX.LFD", "JEDISFX.LFD"] {
        path := tprint("%/LFD/%", dark_dir, it);
        if !file_exists(path) continue;
        archive, ok := archive_open(path);
        if ok { cut.sound_archive = archive; return true; }
    }
    return false;
}

close_sound_archive :: () {
    stop_sounds(keep_marked = false);
    archive_close(cut.sound_archive);
    cut.sound_archive = null;
}

// A film's sound object: the scene's LFD first, then the sound effects LFD.
load_sound :: (scene_archive: *Archive, name: string) -> *Cut_Sound {
    entry := archive_find(scene_archive, tprint("%.VOIC", name));
    if !entry && cut.sound_archive  entry = archive_find(cut.sound_archive, tprint("%.VOIC", name));
    if !entry return null;
    sound := New(Cut_Sound);
    sound.name = copy_string(name);
    sound.data = array_copy(entry.data);
    cut.next_sound_id += 1;
    sound.id = IMUSE_DIGITAL_FIRST + cut.next_sound_id;
    array_add(*cut.sounds, sound);
    return sound;
}

// Scene end: sounds marked to keep play on, losing the mark; the rest stop and go.
stop_sounds :: (keep_marked := true) {
    audio_lock();
    defer audio_unlock();
    i := 0;
    while i < cut.sounds.count {
        sound := cut.sounds[i];
        if keep_marked && sound.keep {
            sound.keep = false;
            i += 1;
            continue;
        }
        imuse_stop_digital(sound.id);
        free(sound.name);
        array_free(sound.data);
        free(sound);
        array_ordered_remove_by_index(*cut.sounds, i);
    }
}

rewind_sound :: (sound: *Cut_Sound) {
    audio_lock();
    imuse_stop_digital(sound.id);
    audio_unlock();
    sound.var1, sound.var2 = 0, 0;
}

run_sound_command :: (sound: *Cut_Sound, op: Film_Op, args: [] u8) {
    arg :: (i: s64) -> s32 #expand { return film_get_arg(args, i); }
    // Seeking, only what the sound is to do later.
    if cut.seeking {
        if op == .SOUND_VAR1 { sound.var1 = arg(0); if sound.var1 == 1  sound.keep = true; }
        if op == .SOUND_VAR2  sound.var2 = arg(0);
        return;
    }
    audio_lock();
    defer audio_unlock();
    if op == {
      case .SOUND_START;
        start_sound(sound);
      case .SOUND_STOP;
        imuse_stop_digital(sound.id);
      case .VOLUME;
        imuse_set_param(sound.id, .VOLUME, arg(0));
      case .SOUND_FADE;
        imuse_fade_param(sound.id, .VOLUME, arg(0), arg(1));
      case .SOUND_VAR1;
        sound.var1 = arg(0);
        if sound.var1 == 1  sound.keep = true;
      case .SOUND_VAR2;
        sound.var2 = arg(0);
      case .SOUND_CMD; #through;
      case .SOUND_CMD2;
        // Each part acts only when its arguments aren't zero.
        if arg(0)  start_sound(sound);
        if arg(1)  imuse_set_param(sound.id, .VOLUME, arg(1));
        if arg(2) || arg(3)  imuse_fade_param(sound.id, .VOLUME, arg(2), arg(3));
        if op == .SOUND_CMD2 {
            if arg(4)  imuse_set_param(sound.id, .PAN, arg(4));
            if arg(5) || arg(6)  imuse_fade_param(sound.id, .PAN, arg(5), arg(6));
        }
    }
}

#scope_file

SOUND_PRIORITY :: 64;
GROUP_SOUND_EFFECTS :: 1;
GROUP_VOICES        :: 2;

start_sound :: (sound: *Cut_Sound) {
    if !imuse_start_digital(sound.id, sound.data, SOUND_PRIORITY) return;
    imuse_set_param(sound.id, .GROUP, ifx sound.var2 == 1 then GROUP_VOICES else GROUP_SOUND_EFFECTS);
}

#import "Basic";
#import "File_Utilities";
#import "engine/dfArchive";
#import "engine/dfAudio";
#import "engine/dfIMuse";
