// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tool: plays notes, a scale and a drum pattern through the FM driver, and shows what the
// 9 voices are doing.

show_fm_test :: (open: *bool) {
    ImGui.SetNextWindowSize(im_scale(.{460, 560}), .FirstUseEver);
    visible := ImGui.Begin("FM Test", open);
    defer ImGui.End();
    if !open.* stop_all();
    if !visible return;

    play_due_events();

    ImGui.SeparatorText("Channel");
    channel_display := test.channel + 1;
    if ImGui.SliderInt("Channel", *channel_display, 1, 16)  test.channel = channel_display - 1;
    if test.channel == MIDI_DRUM_CHANNEL ImGui.TextDisabled("Channel 10 plays drums: the key picks the drum.");
    if ImGui.SliderInt("Program", *test.program[test.channel], 0, 127) {
        send(MIDI_PROGRAM_CHANGE, xx test.program[test.channel]);
    }
    if ImGui.SliderInt("Volume", *test.volume[test.channel], 0, 127) {
        send(MIDI_CONTROL_CHANGE, MIDI_CC_VOLUME, xx test.volume[test.channel]);
    }

    ImGui.SeparatorText("Note");
    ImGui.SliderInt("Key", *test.key, 0, 127, temp_c_string(get_note_name(test.key)));
    ImGui.SliderInt("Velocity", *test.velocity, 1, 127);

    ImGui.Button("Hold to play", im_scale(.{140, 0}));
    if ImGui.IsItemActivated()    send(MIDI_NOTE_ON, xx test.key, xx test.velocity);
    if ImGui.IsItemDeactivated()  send(MIDI_NOTE_OFF, xx test.key);
    ImGui.SameLine();
    if ImGui.Button("Scale")  schedule_scale();
    ImGui.SameLine();
    if ImGui.Button("Drums")  schedule_drums();
    ImGui.SameLine();
    if ImGui.Button("All notes off")  stop_all();

    ImGui.SeparatorText("Output");
    if ImGui.SliderFloat("Music gain", *test.gain, 0, 2, "%.2f")  audio_set_music_volume(test.gain);

    ImGui.SeparatorText("Voices");
    if ImGui.BeginTable("voices", 3, .RowBg | .BordersInnerV | .SizingStretchSame) {
        ImGui.TableSetupColumn("Voice");
        ImGui.TableSetupColumn("Channel");
        ImGui.TableSetupColumn("Key");
        ImGui.TableHeadersRow();
        audio_lock();
        states := fm_get_voice_state();
        audio_unlock();
        for states {
            ImGui.TableNextRow();
            ImGui.TableSetColumnIndex(0);
            ImGui.Text("%", it_index);
            if !it.active {
                ImGui.TableSetColumnIndex(1);
                ImGui.TextDisabled("free");
                continue;
            }
            ImGui.TableSetColumnIndex(1);
            ImGui.Text("%", it.channel + 1);
            ImGui.TableSetColumnIndex(2);
            ImGui.Text("% (%)", get_note_name(it.key), it.key);
        }
        ImGui.EndTable();
    }
}

#scope_file

Event :: struct {
    time_ms: u64;
    status, data1, data2: u8;
}

test: struct {
    channel:  s32;
    program:  [16] s32;
    volume:   [16] s32 = .[127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127];
    key:      s32 = 60;
    velocity: s32 = 100;
    gain:     float = 1;
    events:   [..] Event;  // Sorted by time.
};

send :: (kind: u8, data1: u8, data2: u8 = 0) {
    audio_lock();
    fm_send_midi(kind | cast(u8) test.channel, data1, data2);
    audio_unlock();
}

stop_all :: () {
    array_reset(*test.events);
    audio_lock();
    fm_stop_all_notes();
    audio_unlock();
}

play_due_events :: () {
    now := SDL_GetTicks();
    due := 0;
    audio_lock();
    while due < test.events.count && test.events[due].time_ms <= now {
        e := test.events[due];
        fm_send_midi(e.status, e.data1, e.data2);
        due += 1;
    }
    audio_unlock();
    if due {
        for i: due..test.events.count-1  test.events[i - due] = test.events[i];
        test.events.count -= due;
    }
}

add_note :: (at_ms: u64, length_ms: u64, channel: s32, key: s32, velocity: s32) {
    add_event(at_ms, MIDI_NOTE_ON | cast(u8) channel, xx key, xx velocity);
    add_event(at_ms + length_ms, MIDI_NOTE_OFF | cast(u8) channel, xx key, 0);
}

add_event :: (time_ms: u64, status: u8, data1: u8, data2: u8) {
    i := test.events.count;
    array_add(*test.events, .{});
    while i > 0 && test.events[i - 1].time_ms > time_ms {
        test.events[i] = test.events[i - 1];
        i -= 1;
    }
    test.events[i] = .{time_ms, status, data1, data2};
}

schedule_scale :: () {
    STEPS :: s32.[0, 2, 4, 5, 7, 9, 11, 12];
    start := SDL_GetTicks();
    for STEPS  add_note(start + cast(u64) (it_index * 250), 230, test.channel, test.key + it, test.velocity);
}

schedule_drums :: () {
    KICK  :: 36;
    SNARE :: 38;
    HAT   :: 42;
    STEP_MS :: 150;
    start := SDL_GetTicks();
    for bar: 0..1 {
        for step: 0..7 {
            at := start + cast(u64) ((bar * 8 + step) * STEP_MS);
            add_note(at, 100, MIDI_DRUM_CHANNEL, HAT, 80);
            if step == 0 || step == 5  add_note(at, 100, MIDI_DRUM_CHANNEL, KICK, 120);
            if step == 2 || step == 6  add_note(at, 100, MIDI_DRUM_CHANNEL, SNARE, 110);
        }
    }
}

get_note_name :: (key: int) -> string {
    NAMES :: string.["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    return tprint("%1%2", NAMES[key % 12], key / 12 - 1);
}

#import "Basic";
#import "engine/dfAudio";
#import "engine/dfFm";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
#import "engine/vendor/SDL3";
