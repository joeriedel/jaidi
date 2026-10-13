// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// --ci-test DIR, in every build, ship included: checks a build as it is shipped, with nobody at
// the screen. It runs as the dev screenshots do (window hidden, silent, unsynced, on a clock of
// 1/60 s a frame), plays the opening and saves frames of it, then plays SECBASE, walking and
// turning, and saves frames of that, each Enhanced and then Original on the frame after.
// DIR/ci-test.txt gets a line per check, and the program exits with 0 when every check
// passed, 1 otherwise. The checks only catch what is plainly broken (data or tables missing,
// a blank frame, the level not running); the frames are there to be looked at.

// Reads --ci-test before SDL starts, which decides how it starts.
parse_ci_test_command_line :: () {
    args := get_command_line_arguments();
    for args  if it == "--ci-test" && it_index + 1 < args.count {
        ci.active = true;
        ci.dir = args[it_index + 1];
        make_directory_if_it_does_not_exist(ci.dir, recursive = true);
        add_ci_note("version", tprint("% %", GAME_NAME, VERSION));
        add_ci_note("build", ifx SHIP then "ship" else "dev");
        add_ci_note("os", tprint("%", OS));
    }
}

is_ci_test :: () -> bool {
    return ci.active;
}

add_ci_check :: (name: string, ok: bool, detail := "") {
    if !ci.active return;
    if !ok  ci.failed = true;
    array_add(*ci.lines, sprint("% %%", ifx ok then "PASS" else "FAIL", name, ifx detail then tprint(": %", detail) else ""));
}

add_ci_note :: (name: string, detail: string) {
    if !ci.active return;
    array_add(*ci.lines, sprint("INFO %: %", name, detail));
}

// The run's clock: a fixed step a frame.
get_ci_clock :: () -> u64 {
    return cast(u64) (ci.frame * 1_000_000_000 / 60);
}

// Once a frame, before anything is updated: moves the script on.
begin_ci_frame :: (window: *SDL_Window, cutscenes: *Cutscene_Settings) {
    if !ci.active return;
    f := ci.frame;
    if f == 0 {
        cutscene_start(CUTSCENE_OPENING, get_clock());
        add_ci_check("opening started", cutscene_is_playing());
    }
    // The crawl goes on for minutes: past it, the scene with Kyle's ship, for actors moving
    // over a background rather than text.
    if f == CI_SHIP_SCENE_START {
        cutscene_start(CI_SHIP_SCENE, get_clock());
        add_ci_check(tprint("scene % started", CI_SHIP_SCENE), cutscene_is_playing());
    }

    // Each picture Enhanced, and Original on the frame after.
    ci.capture_name = "";
    cutscenes.enhanced = true;
    for CI_CUTSCENE_FRAMES {
        if f == it  ci.capture_name = tprint("cutscene_%_enhanced", formatInt(it, minimum_digits = 5));
        if f == it + 1 {
            ci.capture_name = tprint("cutscene_%_original", formatInt(it, minimum_digits = 5));
            cutscenes.enhanced = false;
        }
    }

    if f == CI_LEVEL_START {
        ok := start_level(window, CI_LEVEL, false);
        add_ci_check(tprint("level % loaded", CI_LEVEL), ok);
        if !ok  ci.done = true;
    }
    if f < CI_LEVEL_START return;
    l := f - CI_LEVEL_START;
    if !world_is_loaded() return;
    player := world_get_player();
    if l == CI_LEVEL_SHOTS[0] {
        ci.start_position = player.position;
        ci.start_yaw = player.yaw;
    }
    if l == CI_LEVEL_HEADLIGHT  world_toggle_headlight();
    for CI_LEVEL_SHOTS {
        if l == it      ci.capture_name = tprint("level_%_enhanced", formatInt(l, minimum_digits = 4));
        if l == it + 1 {
            ci.capture_name = tprint("level_%_original", formatInt(it, minimum_digits = 4));
            cutscenes.enhanced = false;
        }
    }
    if l == CI_LEVEL_END {
        moved := player.position.x != ci.start_position.x || player.position.z != ci.start_position.z;
        add_ci_check("player walked", moved, tprint("from % % to % %, sector %", fixed_to_float(ci.start_position.x), fixed_to_float(ci.start_position.z),
                                                    fixed_to_float(player.position.x), fixed_to_float(player.position.z), player.sector));
        add_ci_check("player turned", player.yaw != ci.start_yaw);
        add_ci_check("player alive", !world_has_failed() && world_get_agent().health > 0, tprint("health %, shields %", world_get_agent().health, world_get_agent().shields));
        ci.done = true;
    }
}

// The level's keys while it runs: forward, then turning right.
apply_ci_level_input :: (input: *World_Input) {
    if !ci.active || ci.frame < CI_LEVEL_START return;
    l := ci.frame - CI_LEVEL_START;
    if l >= CI_LEVEL_WALK_FROM && l < CI_LEVEL_WALK_TO  input.forward = true;
    if l >= CI_LEVEL_TURN_FROM && l < CI_LEVEL_TURN_TO  input.turn_right = true;
}

// Called with the frame's command buffer once the window is drawn.
capture_ci_frame :: (device: *SDL_GPUDevice, command_buffer: *SDL_GPUCommandBuffer, draw_data: *ImDrawData, format: SDL_GPUTextureFormat) {
    if !ci.active || !ci.capture_name return;
    queue_frame_capture(*ci.capture, device, command_buffer, draw_data, format);
}

// After the frame is submitted: saves a queued frame and checks it. Returns false when the run
// is over.
end_ci_frame :: (device: *SDL_GPUDevice) -> bool {
    if !ci.active return true;
    if is_frame_capture_queued(ci.capture) {
        file := tprint("%.png", ci.capture_name);
        ok, lit, colors := write_frame_capture(*ci.capture, device, tprint("%/%", ci.dir, file));
        // The name is the frame's temporary storage, which lasts until the frame ends.
        detail := tprint("% colors, % percent of the pixels lit", colors, cast(int) (lit * 100 + 0.5));
        if !ok  add_ci_check(file, false, "couldn't be written");
        else    add_ci_check(file, lit >= CI_MIN_LIT && colors >= CI_MIN_COLORS, detail);
        if begins_with(ci.capture_name, "cutscene")  add_ci_check(tprint("% shows a cutscene", file), cutscene_is_playing(), tprint("scene %", cutscene_get_scene()));
        ci.capture_name = "";
    }
    ci.frame += 1;
    if ci.done || ci.frame > CI_LEVEL_START + CI_LEVEL_END + 1 {
        write_ci_report();
        return false;
    }
    return true;
}

// Writes DIR/ci-test.txt. Also called when the program can't start, before it exits.
write_ci_report :: () {
    if !ci.active return;
    builder: String_Builder;
    for ci.lines  print_to_builder(*builder, "%\n", it);
    print_to_builder(*builder, "RESULT %\n", ifx ci.failed then "FAIL" else "PASS");
    report := builder_to_string(*builder);
    path := tprint("%/ci-test.txt", ci.dir);
    if !write_entire_file(path, report)  print("Couldn't write %\n", path);
    print("%", report);
}

get_ci_exit_code :: () -> s32 {
    return xx ifx ci.failed then 1 else 0;
}

#scope_file

// Frames of the cutscenes to save: the logo, the title, the crawl, then Kyle's ship.
CI_CUTSCENE_FRAMES :: int.[300, 1500, 2700, 3300, 3600];
CI_SHIP_SCENE :: 40;
CI_SHIP_SCENE_START :: 2702;
CI_LEVEL_START :: 3602;

// Frames from the level's start.
CI_LEVEL :: "SECBASE";
CI_LEVEL_SHOTS :: int.[10, 120];
CI_LEVEL_WALK_FROM, CI_LEVEL_WALK_TO :: 12, 72;
CI_LEVEL_TURN_FROM, CI_LEVEL_TURN_TO :: 72, 96;
CI_LEVEL_HEADLIGHT :: 100;
CI_LEVEL_END :: 122;

// A frame with less is taken for blank.
CI_MIN_LIT    :: 0.02;
CI_MIN_COLORS :: 16;

ci: struct {
    active: bool;
    dir: string;
    frame: int;
    done: bool;
    failed: bool;
    lines: [..] string;
    capture: Frame_Capture;
    capture_name: string;
    start_position: Fixed3;
    start_yaw: s32;
};

fixed_to_float :: (x: s32) -> float { return x / 65536.0; }

#import "Basic";
#import "File";
#import "String";
#import "Build_Config";
#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "engine/dfCutscene";
#import "engine/dfWorld";
#import "engine/dfFixed";
#import "engine/dfLevel";
