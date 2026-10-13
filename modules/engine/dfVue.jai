// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// VUE: paths for objects, exported from 3D Studio. Each "transform" line is one frame of one
// 3DS object: a 3x3 matrix and a position, in 3DS's space (z up). Everything else in the
// file (the version, "frame N", cameras, "top") is skipped; frames go in the order the lines
// come.
//
// Read as DARK.EXE reads it (0x3051a): a line counts only when all thirteen fields scan, the
// name is compared without case, quotes and all, and "*" takes every name. Numbers go
// through a float into 16.16, truncated, and the frame is turned into the game's space (y
// down) by the original's integer math.

Vue_Frame :: struct {
    matrix: [9] Fixed;          // Row by row: a model's point p goes to matrix * p.
    position: Fixed3;
    first: bool;                // The marker that starts each file's frames.
}

// Adds a marker and then the frames of the named object (or of all, for "*") to frames.
vue_parse :: (text: string, name: string, frames: *[..] Vue_Frame) {
    array_add(frames, .{first = true});
    rest_of_file := text;
    while rest_of_file {
        line: string;
        found, before, after := split_from_left(rest_of_file, #char "\n");
        if found { line = before; rest_of_file = after; }
        else     { line = rest_of_file; rest_of_file = ""; }
        if !begins_with(line, "transform") continue;
        words: [13] string;
        rest := advance(line, "transform".count);
        count := 0;
        while count < 13 {
            rest = eat_spaces(rest);
            if !rest break;
            end := 0;
            while end < rest.count && !is_space(rest[end])  end += 1;
            words[count] = slice(rest, 0, end);
            rest = advance(rest, end);
            count += 1;
        }
        if count < 13 continue;
        numbers: [12] Fixed;
        all := true;
        for 0..11 {
            if !is_scan_number(words[it + 1]) { all = false; break; }
            numbers[it] = fixed_from_text(words[it + 1]);
        }
        if !all continue;
        if name != "*" && !equal_nocase(words[0], name) continue;

        // 3DS's z up to the game's y down: R^T F^T R, with R a turn about x by -1.57077
        // radians, which comes to one unit short of a quarter turn in 16.16.
        R :: Fixed.[0x10000, 0, 0,  0, 1, 0xFFFF,  0, -0xFFFF, 1];
        f: [9] Fixed;
        for 0..8  f[it] = numbers[it];
        frame := array_add(frames);
        frame.matrix = multiply_transposed(multiply_transposed(R, f), R);
        frame.position = .{numbers[9], -numbers[11], numbers[10]};
    }
}

#scope_file

// b^T a, each product truncated before the sum (0x89970).
multiply_transposed :: (a: [9] Fixed, b: [9] Fixed) -> [9] Fixed {
    out: [9] Fixed;
    for r: 0..2  for c: 0..2 {
        out[r * 3 + c] = mul16(a[c], b[r]) + mul16(a[3 + c], b[3 + r]) + mul16(a[6 + c], b[6 + r]);
    }
    return out;
}

eat_spaces :: (s: string) -> string {
    i := 0;
    while i < s.count && is_space(s[i])  i += 1;
    return advance(s, i);
}

is_scan_number :: (s: string) -> bool {
    _, ok := string_to_float64(s);
    return ok;
}

#import "Basic";
#import "String";
#import "engine/dfFixed";
#import "engine/dfLevel";
