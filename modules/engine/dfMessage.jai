// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// MSG files: the game's numbered text strings with their priorities, TEXT.MSG (in DARK.GOB:
// what the HUD shows) and LOCAL.MSG (in the game's directory: the program's own strings).
// Read as DARK.EXE reads them (0x21cf4):
//
//   MSG 1.0
//   MSGS n
//   id priority: "text"         (n lines)
//   END
//
// Lines starting with '#' and blank lines are skipped. A line's numbers are read with
// "%d %d"; its text is what's between its first two quotes, where "\n" becomes a space and a
// line break and other backslashes stay. A count that doesn't match or a missing END fails.

Msg_Entry :: struct {
    id:       s32;
    priority: s32;              // Lower wins: a message replaces a shown one of the same or higher.
    text:     string;
}

Msg_File :: struct {
    messages: [..] Msg_Entry;
}

msg_parse :: (text: string) -> Msg_File, bool {
    file: Msg_File;
    ok := parse(*file, text);
    if !ok  msg_free(*file);
    return file, ok;
}

msg_free :: (file: *Msg_File) {
    for file.messages  free(it.text);
    array_free(file.messages);
    file.* = .{};
}

// The text of a message, or "" for none (0x1b90f).
msg_get_text :: (file: *Msg_File, id: s32) -> string {
    message := msg_find(file, id);
    return ifx message then message.text else "";
}

// The first message with the id (0x220ac), or null.
msg_find :: (file: *Msg_File, id: s32) -> *Msg_Entry {
    for * file.messages  if it.id == id return it;
    return null;
}

#scope_file

parse :: (file: *Msg_File, text: string) -> bool {
    s := text;
    line, found := next_line(*s);
    if !found return false;
    major, minor, ok := read_two_ints(trim(advance_word(line, "MSG")), #char ".");
    if !ok || major != 1 || minor != 0 return false;

    line, found = next_line(*s);
    if !found return false;
    count_text := advance_word(line, "MSGS");
    count, count_ok := string_to_int(trim(count_text));
    if !count_ok || count < 0 return false;

    for 1..count {
        line, found = next_line(*s);
        if !found return false;
        id, priority, numbers_ok := read_two_ints(line, #char " ");
        if !numbers_ok return false;
        message := array_add(*file.messages);
        message.id = xx id;
        message.priority = xx priority;
        found_open, _, after := split_from_left(line, #char "\"");
        if !found_open continue;
        found_close, inside := split_from_left(after, #char "\"");
        if !found_close continue;
        message.text = convert_line_breaks(inside);
    }

    line, found = next_line(*s);
    return found && equal_nocase(trim(line), "END");
}

// The next line that isn't blank or a comment.
next_line :: (s: *string) -> string, bool {
    while s.* {
        _, line, rest := split_from_left(s.*, #char "\n");
        s.* = rest;
        start := line;
        while start && (start[0] == #char " " || start[0] == #char "\t")  advance(*start);
        if !start || start[0] == #char "#" || start[0] == #char "\r" continue;
        return line, true;
    }
    return "", false;
}

// What follows the keyword at the start of the line, or "" if it isn't there.
advance_word :: (line: string, word: string) -> string {
    l := trim(line);
    if !begins_with_nocase(l, word) return "";
    return advance(l, word.count);
}

// Two integers, as sscanf's "%d %d" (or "%d.%d") reads them: each after optional white space,
// separated by the separator (white space matching any run of it).
read_two_ints :: (text: string, separator: u8) -> s64, s64, bool {
    s := text;
    a, ok := read_int(*s);
    if !ok return 0, 0, false;
    if separator == #char " " {
        while s && (s[0] == #char " " || s[0] == #char "\t")  advance(*s);
    } else {
        if !s || s[0] != separator return 0, 0, false;
        advance(*s);
    }
    b: s64;
    b, ok = read_int(*s);
    return a, b, ok;
}

read_int :: (s: *string) -> s64, bool {
    while s.* && (s.*[0] == #char " " || s.*[0] == #char "\t")  advance(s);
    negative := false;
    if s.* && (s.*[0] == #char "-" || s.*[0] == #char "+") {
        negative = s.*[0] == #char "-";
        advance(s);
    }
    value: s64;
    digits := 0;
    while s.* && s.*[0] >= #char "0" && s.*[0] <= #char "9" {
        value = value * 10 + s.*[0] - #char "0";
        advance(s);
        digits += 1;
    }
    return ifx negative then -value else value, digits > 0;
}

// "\n" to a space and a line break, as the original does in place.
convert_line_breaks :: (text: string) -> string {
    result := copy_string(text);
    for i: 0..result.count-2 {
        if result[i] == #char "\\" && result[i + 1] == #char "n" {
            result[i] = #char " ";
            result[i + 1] = #char "\n";
        }
    }
    return result;
}

#import "Basic";
#import "String";
