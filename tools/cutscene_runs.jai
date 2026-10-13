// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// --cutscene-diff: plays the opening (or from --scene) as fast as the machine goes, like Quake's
// timedemo: frames aren't held to the display's refresh, and the cutscene's clock moves 1/60 s
// per frame whatever the time. Both presenters run, and after every frame the GPU's video
// image is read back and compared with the CPU's, index for index. Stops at the first
// difference, at the end, or after --diff-frames, prints what it found and how long it took,
// and quits.

FIXED_STEP_NS :: 1_000_000_000 / 60;

start_cutscene_diff :: () {
    runs.running = true;
}

// 0 for the whole cutscene.
set_cutscene_diff_frames :: (frames: int) {
    runs.limit = frames;
}

is_fixed_cutscene_run :: () -> bool {
    return runs.running;
}

get_fixed_run_clock :: () -> u64 {
    return cast(u64) (runs.frame * FIXED_STEP_NS);
}

// After the frame is submitted. Returns false when the run is over.
check_fixed_cutscene_run :: () -> bool {
    r := *runs;
    if !r.running return true;
    if !r.started_ns  r.started_ns = SDL_GetTicksNS();
    if !cutscene_is_playing() || (r.limit && r.frame >= r.limit) {
        seconds := (SDL_GetTicksNS() - r.started_ns) / 1_000_000_000.0;
        print("Cutscene diff: % frames compared, all match, in % s (% frames a second).\n", r.frame, formatFloat(seconds, trailing_width = 1), formatFloat(r.frame / seconds, trailing_width = 0));
        r.running = false;
        return false;
    }
    if !compare_frame() {
        r.running = false;
        return false;
    }
    r.frame += 1;
    return true;
}

#scope_file

runs: struct {
    running: bool;
    frame: int;
    limit: int;
    started_ns: u64;
};

compare_frame :: () -> bool {
    gpu := cutscene_read_gpu_video();
    cpu := cutscene_get_video();
    if gpu.count != cpu.count {
        print("Cutscene diff: no GPU image to compare.\n");
        return false;
    }
    for cpu {
        if gpu[it_index] == cast(u16) it + 1 continue;
        x, y := it_index % 320, it_index / 320;
        print("Cutscene diff: frame % (scene %, cell %) differs at (%, %): CPU index %, GPU %.\n",
              runs.frame, cutscene_get_scene(), cutscene_get_cell(), x, y, it, cast(int) gpu[it_index] - 1);
        return false;
    }
    return true;
}

#import "Basic";
#import "engine/dfCutscene";
#import "engine/vendor/SDL3";
