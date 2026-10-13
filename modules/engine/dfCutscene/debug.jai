// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// What the debug panel shows of the cutscene playing.

Cutscene_Debug :: struct {
    scene: Cutscene_Entry;
    cell, cell_count: s32;
    frame_delay: s32;           // Landru ticks.
    seconds: float64;           // Since the cutscene started: when the player next acts.
    blitting: bool;             // In the blit's fade passes, rather than waiting for the delay.
    fade: Fade_Type;
    fade_step, fade_length: s32;
    color_fade: Color_Fade;
    color_step, color_length: s32;
    music_sequence, music_cue: s32;
    sounds: [..] Cutscene_Debug_Sound;
}

Cutscene_Debug_Sound :: struct {
    name: string;
    keep: bool;                 // Plays on into the next scene.
    voice: bool;
}

Cutscene_Debug_Actor :: struct {
    name: string;
    kind: Actor_Kind;
    x, y, z: s32;
    x_vel, y_vel: s32;
    state, state_vel: s32;      // For an ANIM, its cell.
    cells: s64;
    visible, flip: bool;
    clip: Rect;
    var1, var2: s32;
}

// False when none is playing. The sounds are in temporary storage.
cutscene_get_debug :: () -> Cutscene_Debug, bool {
    d: Cutscene_Debug;
    if !cut.scene return d, false;
    d.scene = cut.scene.*;
    d.cell, d.cell_count = cut.film.cell, cut.film.cell_count;
    d.frame_delay = cut.frame_delay;
    d.seconds = cut.clock.event;
    d.blitting = cut.clock.phase == .BLIT;
    d.fade, d.fade_step, d.fade_length = cut.fade.type, cut.fade.step, cut.fade.length;
    d.color_fade, d.color_step, d.color_length = cut.fade.color, cut.fade.color_step, cut.fade.color_length;
    d.music_sequence, d.music_cue = cut_music.sequence_id, cut_music.cue;
    d.sounds.allocator = temp;
    for cut.sounds  array_add(*d.sounds, .{it.name, it.keep, it.var2 == 1});
    return d, true;
}

// The film's actors in drawing order (the back first), in temporary storage.
cutscene_list_actors :: () -> [..] Cutscene_Debug_Actor {
    actors: [..] Cutscene_Debug_Actor;
    actors.allocator = temp;
    if !cut.scene return actors;
    for cut.film.actors {
        array_add(*actors, .{it.name, it.kind, it.x, it.y, it.z, it.x_vel, it.y_vel, it.state, it.state_vel,
                             it.frames.count, it.visible, it.flip_h, it.frame, it.var1, it.var2});
    }
    return actors;
}
