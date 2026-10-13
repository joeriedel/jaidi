// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

SAMPLE :: #string END
vue 1
frame 0
transform "ship" 1 0 0 0 1 0 0 0 1 10.5 -2 3
transform "other" 1 0 0 0 1 0 0 0 1 0 0 0
camera 0 0 0 1 1 1 0 50
frame 1
transform "SHIP" 0 -1 0 1 0 0 0 0 1 11 -2 3.25
transform "ship" 1 0 0 0 1 0 0 0 1 not a number
  transform "ship" 1 0 0 0 1 0 0 0 1 0 0 0
END

vue_frames_parse :: () {
    frames: [..] Vue_Frame;
    defer array_free(frames);
    vue_parse(SAMPLE, "\"SHIP\"", *frames);
    // The marker, then the two whole lines for "ship" in either case at a line's start.
    if !check(frames.count == 3 && frames[0].first && !frames[1].first, "% frames", frames.count) return;
    // 3DS's (x, y, z) is the game's (x, -z, y).
    p := frames[1].position;
    check(p.x == 0xA8000 && p.y == -0x30000 && p.z == -0x20000, "position %", p);
    // The identity comes out a little off, from the turn's sine and cosine rounded to 1 and
    // 0xFFFF and each product truncated.
    m := frames[1].matrix;
    check(m[0] == 0x10000 && m[4] == 0xFFFE && m[8] == 0xFFFE && m[5] == -1 && m[7] == -1, "matrix %", m);
    // A turn about 3DS's z (up) is a turn about the game's y.
    t := frames[2].matrix;
    check(t[0] == 0 && t[2] == 0xFFFF && t[4] == 0xFFFE && t[6] == -0xFFFF && t[8] == 0, "turned matrix %", t);

    vue_parse(SAMPLE, "*", *frames);
    check(frames.count == 3 + 1 + 3, "every object: % frames", frames.count - 3);
} @test

#import "Basic";
#import "engine/dfFixed";
#import "engine/dfVue";
