// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

SAMPLE :: #string DONE
MSG 1.0
# A comment.
MSGS 3

  12   0:  "Off"
300 1: "Two\nlines"
  8 2  "Keeps a \t backslash"
END
DONE

messages_parse :: () {
    file, ok := msg_parse(SAMPLE);
    defer msg_free(*file);
    if !check(ok && file.messages.count == 3, "% messages", file.messages.count)  return;
    check(msg_get_text(*file, 12) == "Off" && msg_find(*file, 12).priority == 0, "message 12: %", msg_get_text(*file, 12));
    check(msg_get_text(*file, 300) == "Two \nlines" && msg_find(*file, 300).priority == 1, "message 300: '%'", msg_get_text(*file, 300));
    check(msg_get_text(*file, 8) == "Keeps a \\t backslash" && msg_find(*file, 8).priority == 2, "message 8: '%'", msg_get_text(*file, 8));
    check(msg_get_text(*file, 99) == "", "a missing message isn't empty");
} @test

messages_reject_damage :: () {
    _, ok := msg_parse(replace(SAMPLE, "MSGS 3", "MSGS 4",, temp));
    check(!ok, "accepted fewer messages than counted");
    _, ok = msg_parse(replace(SAMPLE, "MSG 1.0", "MSG 1.1",, temp));
    check(!ok, "accepted version 1.1");
    _, ok = msg_parse(replace(SAMPLE, "\nEND", "\nFIN",, temp));
    check(!ok, "accepted no END");
} @test

retail_messages_parse :: () {
    skip_without_dark();
    gob_unmount_all();
    defer gob_unmount_all();
    if !check(gob_mount_retail(find_dark_data_dir()), "couldn't mount the retail GOBs")  return;
    data, found := gob_find("TEXT.MSG");
    if !check(found, "no TEXT.MSG")  return;
    text, ok := msg_parse(cast(string) data);
    defer msg_free(*text);
    check(ok && text.messages.count == 112, "TEXT.MSG: % messages", text.messages.count);
    check(msg_get_text(*text, 0) == "Joystick Off" && msg_find(*text, 710).priority == 1, "TEXT.MSG: '%'", msg_get_text(*text, 0));

    contents, read := read_entire_file(tprint("%/LOCAL.MSG", find_dark_data_dir()));
    if !check(read, "no LOCAL.MSG")  return;
    local: Msg_File;
    local, ok = msg_parse(contents);
    defer msg_free(*local);
    check(ok && local.messages.count == 38, "LOCAL.MSG: % messages", local.messages.count);
} @test

#import "Basic";
#import "File";
#import "String";
#import "engine/dfArchive";
#import "engine/dfMessage";
