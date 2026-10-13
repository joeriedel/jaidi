// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Times of the main loop's parts, for the debug panel's frame graphs: zones opened and closed
// in order within a frame, nested, and the last 300 frames kept. Always on: a zone is two
// reads of the clock.

PROFILE_FRAMES :: 301;          // Slots: the last 300 frames and the one being recorded.
PROFILE_ZONES  :: 32;

Profile_Zone :: struct {
    name:       string;
    start, end: u64;            // Nanoseconds, SDL's clock.
    depth:      s32;
}

Profile_Frame :: struct {
    start, end: u64;
    zones: [PROFILE_ZONES] Profile_Zone;
    count: s32;
}

// Ends the frame being recorded and starts the next, at the top of the main loop.
profile_begin_frame :: () {
    p := *profile;
    now := SDL_GetTicksNS();
    frame := *p.frames[p.current];
    if frame.start {
        frame.end = now;
        p.current = (p.current + 1) % PROFILE_FRAMES;
        // One slot is always the frame being recorded.
        p.recorded = min(p.recorded + 1, PROFILE_FRAMES - 1);
    }
    frame = *p.frames[p.current];
    frame.start = now;
    frame.end = 0;
    frame.count = 0;
    p.depth = 0;
}

// Times the rest of the enclosing scope.
profile_zone :: (name: string) #expand {
    zone := profile_open_zone(name);
    `defer profile_close_zone(zone);
}

// A finished frame, 0 the last; null when there aren't that many yet.
profile_get_frame :: (age: s32) -> *Profile_Frame {
    p := *profile;
    if age < 0 || age >= p.recorded return null;
    return *p.frames[(p.current - 1 - age + PROFILE_FRAMES) % PROFILE_FRAMES];
}

profile_get_frame_count :: () -> s32 { return profile.recorded; }

// For a zone that doesn't fit a scope: its index in the frame, or -1 when the frame is full,
// to close it with.
profile_open_zone :: (name: string) -> s32 {
    p := *profile;
    frame := *p.frames[p.current];
    p.depth += 1;
    if frame.count >= PROFILE_ZONES return -1;
    index := frame.count;
    frame.count += 1;
    frame.zones[index] = .{name, SDL_GetTicksNS(), 0, p.depth - 1};
    return index;
}

profile_close_zone :: (index: s32) {
    p := *profile;
    p.depth -= 1;
    if index >= 0  p.frames[p.current].zones[index].end = SDL_GetTicksNS();
}

#scope_file

profile: struct {
    frames:   [PROFILE_FRAMES] Profile_Frame;
    current:  s32;              // The frame being recorded.
    recorded: s32;              // Finished frames kept.
    depth:    s32;
};

#import "Basic";
#import "engine/vendor/SDL3";
