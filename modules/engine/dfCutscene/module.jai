// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Cutscenes, played the way the original's Landru system plays them. CUTSCENE.LST chains
// scenes; each is a FILM in its own LFD, whose objects (DELT and ANIM actors, palettes, the
// view, sounds) follow command streams cut into cells. Every frame the film steps one cell,
// the actors are drawn into a 320x200 canvas of palette indices, and the blit copies the
// canvas to the video buffer, running any fade on the way.
//
// Timing follows the original. A frame waits until its delay (by the scene's speed) has passed
// since the last wait ended, on the game's 145.6 Hz clock counted twice per tick, so odd delays
// round up. The blit runs a whole fade at once, each step that changes the palette waiting for
// the next vertical retrace (70 Hz), and the time it takes counts toward the next frame's
// delay. The caller passes the time, shows cutscene_get_video in cutscene_get_palette, and
// passes on the keys. Sounds play through iMUSE's digital side (sound.jai).

// The opening: LucasArts, Star Wars, the text crawl, Kyle's ship, the Dark Forces logo.
CUTSCENE_OPENING :: 10;

// Loads CUTSCENE.LST and CUTMUSE.TXT from the mounted GOBs.
cutscene_init :: () -> bool {
    cutscene_shutdown();
    text, found := gob_find("CUTSCENE.LST");
    if !found return false;
    cut.list = cutscene_list_parse(cast(string) text);
    muse, muse_found := gob_find("CUTMUSE.TXT");
    if muse_found  cut.sequences = cutmuse_parse(cast(string) muse);
    if !open_sound_archive()  log_error("No JEDISFX.LFD: cutscenes play without sound.");
    start_fitter();
    return true;
}

cutscene_shutdown :: () {
    close_scene();
    stop_fitter();
    close_sound_archive();
    cutscene_release_gpu();
    cutscene_list_free(*cut.list);
    cutmuse_free(*cut.sequences);
}

// Starts the scene and the ones that follow it. 'now' is in nanoseconds, on the clock
// cutscene_update gets.
cutscene_start :: (id: s32, now: u64) -> bool {
    // Every scene's in-betweens fitting from now, so later ones are ready when they come up.
    cutscene_prepare_fits(id);
    cut.start_ns = now;
    cut.clock = .{};
    cut.palette = .{};
    cut.fade = .{};
    emit_clear_canvas();
    emit_clear_video();
    start_scene(id);
    if !cut.scene return false;
    begin_frame();
    return true;
}

cutscene_is_playing :: () -> bool {
    return cut.scene != null;
}

// The scene playing, 0 for none.
cutscene_get_scene :: () -> s32 {
    return ifx cut.scene then cut.scene.id else 0;
}

// The scene's film cell, for reports.
cutscene_get_cell :: () -> s32 {
    return cut.film.cell;
}

// When the player next acts (a frame, or a fade step), on the clock cutscene_update gets.
cutscene_get_next_event_time :: () -> u64 {
    return cut.start_ns + cast(u64) (cut.clock.event * 1_000_000_000.0);
}

// Landru's frame delay, in its ticks, as the last scene set it: menus run at it too. 20 before
// any scene has played.
cutscene_get_frame_delay :: () -> s32 {
    return ifx cut.frame_delay then cut.frame_delay else 20;
}

cutscene_get_list :: () -> [] Cutscene_Entry {
    return cut.list;
}

cutscene_get_music_sequences :: () -> [] Music_Sequence {
    return cut.sequences;
}

// Plays up to 'now'. Returns false once the cutscene has ended.
cutscene_update :: (now: u64) -> bool {
    if !cut.scene return false;
    target := cast(float64) (now - cut.start_ns) / 1_000_000_000.0;
    // After a long stall (a dragged window, a breakpoint) the clock jumps rather than racing.
    if target - cut.clock.event > 0.5 {
        shift := target - cut.clock.event;
        cut.clock.event += shift;
        cut.clock.wait_tick += cast(s64) (shift * GAME_TICKS_PER_SECOND);
    }
    while cut.scene && cut.clock.event <= target  run_event();
    return cut.scene != null;
}

// Esc and Enter: on to the scene's skip id, which ends the cutscene for most.
cutscene_skip :: () { cut.skip_pressed = true; }

// Space: on to the next scene.
cutscene_next :: () { cut.next_pressed = true; }

// Ends the cutscene now.
cutscene_stop :: () {
    cutscene_drop_fits();
    close_scene();
    stop_sounds(keep_marked = false);
    cutscene_music_stop();
}

// What's on screen: palette indices, 320 x 200, top row first.
cutscene_get_video :: () -> [] u8 {
    return cut.video;
}

// The VGA palette, 6-bit values widened to 8 bits.
cutscene_get_palette :: () -> Palette {
    palette: Palette;
    for cut.palette.screen {
        palette.colors[it_index] = .{expand_6_bit(it.r), expand_6_bit(it.g), expand_6_bit(it.b)};
    }
    return palette;
}

#scope_module

// The game's timer runs the PIT at 1193182 / 8192 Hz; Landru counts each tick as two of its
// own (1193182 / 4096 Hz).
GAME_TICKS_PER_SECOND :: 1193182.0 / 8192.0;

// Mode 13h's refresh: the 25.175 MHz dot clock over 800 x 449.
RETRACES_PER_SECOND :: 25_175_000.0 / (800.0 * 449.0);

// 6-bit VGA DAC values.
Rgb :: struct { r, g, b: u8; }

Phase :: enum u8 {
    WAIT;       // For the frame delay; the blit follows.
    BLIT;       // Fade passes, some waiting for a retrace.
}

cut: struct {
    list:      [..] Cutscene_Entry;
    sequences: [..] Music_Sequence;

    scene:   *Cutscene_Entry;
    archive: *Archive;
    sound_archive: *Archive;
    sounds:  [..] *Cut_Sound;  // This scene's, and those kept from the last.
    next_sound_id: s32;
    film:    Film;
    crawl:   Crawl;

    canvas: [CANVAS_WIDTH * CANVAS_HEIGHT] u8;
    video:  [CANVAS_WIDTH * CANVAS_HEIGHT] u8;

    palette: struct {
        screen, working, source, dest: [256] Rgb;
    };
    fade: Fade_State;

    time: s32;                  // View frames since the scene started.
    frame_delay: s32;           // Landru ticks.
    aborted:     s32;           // Scene to go to after the cleanup fade a key starts; -1 none.

    start_ns: u64;
    clock: struct {
        event: float64;         // Seconds since the start: when run_event next acts.
        phase: Phase;
        wait_tick: s64;         // Game tick at which the last frame wait ended.
        last_frame_ticks: s32;  // Landru ticks the last wait counted.
    };
    skip_pressed, next_pressed: bool;
};

// The text crawl's actor, if the scene is the crawl's.
get_crawl_actor :: (entry: *Cutscene_Entry, film: *Film) -> *Actor {
    if entry.id != TEXT_CRAWL_SCENE return null;
    return film_find_actor(film, .DELT, "textcraw");
}

find_scene :: (id: s32) -> *Cutscene_Entry {
    for * cut.list  if it.id == id  return it;
    return null;
}

get_scene_archive_path :: (entry: *Cutscene_Entry) -> string {
    return tprint("%/LFD/%", find_dark_data_dir(), to_upper_copy(entry.archive,, temp));
}

#scope_file

// Ticks per frame by scene speed, 4 to 20. Not 291.3 / speed: the table was evidently set by
// eye.
FRAME_DELAYS :: s32.[42, 49, 40, 35, 31, 28, 25, 23, 20, 19, 17, 16, 15, 14, 13, 12, 12];
TEXT_CRAWL_SCENE :: 30;

start_scene :: (id: s32) {
    close_scene();
    if id < 1 return;
    entry := find_scene(id);
    if !entry return;

    if entry.music > 0  set_music_sequence(entry.music);

    archive, ok := archive_open(get_scene_archive_path(entry));
    if !ok return;
    cut.archive = archive;
    if !film_load(*cut.film, cut.archive, entry.film) {
        log_error("Cutscene % ('%') failed to load.", id, entry.film);
        close_scene();
        return;
    }
    queue_film_motions(*cut.film, cut.archive);
    cut.scene = entry;
    cut.frame_delay = FRAME_DELAYS[clamp(entry.speed, 4, 20) - 4];
    cut.time = 0;
    cut.aborted = -1;
    cut.skip_pressed, cut.next_pressed = false, false;
    actor := get_crawl_actor(entry, *cut.film);
    if actor  open_crawl(*cut.crawl, actor);
}

close_scene :: () {
    if cut.scene  stop_sounds();
    retire_gpu_textures();
    close_crawl(*cut.crawl);
    film_free(*cut.film);
    archive_close(cut.archive);
    cut.archive = null;
    cut.scene = null;
}

// The front half of the view loop: update the film and draw the canvas. Then the frame waits.
begin_frame :: () {
    if cut.time == 0  film_rewind(*cut.film);
    else              film_step(*cut.film);
    film_send_cues(*cut.film);
    film_sort_actors(*cut.film);
    emit_clear_canvas();
    film_draw(*cut.film);
    start_wait();
}

// The wait counts from the end of the last one, so time spent blitting counts too; any ticks
// past the delay are dropped.
start_wait :: () {
    cut.clock.phase = .WAIT;
    now_tick := cast(s64) (cut.clock.event * GAME_TICKS_PER_SECOND);
    due_tick := cut.clock.wait_tick + (cut.frame_delay + 1) / 2;
    if now_tick >= due_tick {
        cut.clock.last_frame_ticks = cast(s32) (2 * (now_tick - cut.clock.wait_tick));
        cut.clock.wait_tick = now_tick;
    } else {
        cut.clock.last_frame_ticks = cast(s32) (2 * (due_tick - cut.clock.wait_tick));
        cut.clock.wait_tick = due_tick;
        cut.clock.event = due_tick / GAME_TICKS_PER_SECOND;
    }
}

run_event :: () {
    if cut.clock.phase == .WAIT {
        cut.clock.phase = .BLIT;
        start_blit();
    }
    // Passes that don't touch the palette take no time.
    while cut.scene && cut.clock.phase == .BLIT {
        if !run_blit_pass() {
            cut.clock.event = get_next_retrace(cut.clock.event);
            return;
        }
        if is_blit_done()  end_frame();
    }
}

// Strictly after 'time': when 'time' is itself a retrace, rounding can put it a hair under, and
// the next would come out the same.
get_next_retrace :: (time: float64) -> float64 {
    n := floor(time * RETRACES_PER_SECOND) + 1;
    while n / RETRACES_PER_SECOND <= time  n += 1;
    return n / RETRACES_PER_SECOND;
}

// The back half: the blit is done, the player decides what follows.
end_frame :: () {
    if cut.aborted >= 0 {
        // The cleanup fade after a key is done.
        target := cut.aborted;
        cut.aborted = -1;
        go_to_scene(target);
        return;
    }
    entry := cut.scene;
    if cut.skip_pressed || cut.next_pressed {
        target := ifx cut.skip_pressed then entry.skip else entry.next;
        cut.skip_pressed, cut.next_pressed = false, false;
        // Out through black: the canvas cleared, a short fade to black and back.
        emit_clear_canvas();
        cut.aborted = target;
        start_cleanup_fade();
        return;
    }
    cut.time += 1;
    if cut.film.cell == cut.film.cell_count {
        go_to_scene(entry.next);
        return;
    }
    begin_frame();
}

go_to_scene :: (id: s32) {
    start_scene(id);
    if !cut.scene {
        stop_sounds(keep_marked = false);
        cutscene_music_stop();
        return;
    }
    begin_frame();
}

#load "lists.jai";
#load "film_format.jai";
#load "film.jai";
#load "draw.jai";
#load "fade.jai";
#load "crawl.jai";
#load "music.jai";
#load "sound.jai";
#load "gpu.jai";
#load "motion.jai";

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
