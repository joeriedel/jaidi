// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tool: the game's level music, switched between stalk and fight to hear the transitions,
// and any GMD song played on its own. Shows and drives iMUSE: positions, markers, hooks, jumps,
// delayed stops and fades, and which output channel each part holds.

show_music_tool :: (open: *bool) {
    ImGui.SetNextWindowSize(im_scale(.{900, 640}), .FirstUseEver);
    visible := ImGui.Begin("Music", open);
    defer ImGui.End();
    if !open.* {
        stop_everything();
        free_music_entries();
    }
    if !visible return;

    if !mounted_gobs {
        ImGui.TextUnformatted("No GOBs mounted: the game data wasn't found in dark/.");
        return;
    }

    // The mounted GOBs don't change while the tool is open.
    if !music.listed  build_music_entries();
    entries := music.entries;
    draw_music_list(entries);
    ImGui.SameLine();

    ImGui.BeginGroup();
    defer ImGui.EndGroup();

    selected := find_selected_entry(entries);
    ImGui.BeginDisabled(selected == null);
    if ImGui.Button("Play")  start_entry(selected);
    ImGui.EndDisabled();
    ImGui.SameLine();
    if ImGui.Button("Stop")  stop_everything();
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(120));
    if ImGui.SliderFloat("Gain", *music.gain, 0, 2, "%.2f")  audio_set_music_volume(music.gain);
    if music.failed  ImGui.TextColored(.{1, 0.4, 0.4, 1}, "Couldn't play %.", music.failed);

    draw_paired_music();

    audio_lock();
    s := imuse_get_status();
    voices := fm_get_voice_state();
    audio_unlock();

    ImGui.SeparatorText("Songs playing");
    if !s.player_count  ImGui.TextDisabled("Nothing playing.");
    for i: 0..s.player_count-1  draw_player(*s.players[i]);

    ImGui.SeparatorText("FM voices");
    for voices {
        if it.active ImGui.Text("%: ch % key %", it_index, it.channel + 1, it.key);
        else         ImGui.TextDisabled("%: free", it_index);
    }
}

#scope_file

// A stalk song with its fight song, played as the game plays a level's music, or a song on its
// own.
Music_Entry :: struct {
    key:   string;  // What the selection remembers: the pair's number or the song's name.
    label: string;
    stalk: string;  // For pairs.
    fight: string;
    song:  string;  // For single songs.
}

// Per song, the values typed into its controls.
Controls :: struct {
    chunk:   s32 = 1;
    measure: s32 = 1;
    beat:    s32 = 1;
    tick:    s32;
    sustain: bool = true;
    hook:    s32 = 1;
    frames:  s32 = 60;  // For delayed stops and fades.
}

music: struct {
    entries:  [..] Music_Entry;  // Built when the tool opens, freed when it closes.
    listed:   bool;
    selected: [32] u8;  // Key of the selected entry, zero-terminated.
    failed:   string;
    gain:     float = 1;
    controls: [IMUSE_MAX_SONGS + 1] Controls;  // By song.
};

// Every GMD in the mounted GOBs, once each: a STALK-x with a FIGHT-x makes a pair, named after
// level x in JEDI.LVL when there is one; everything else is a single song.
build_music_entries :: () {
    free_music_entries();
    music.listed = true;
    for get_music_entries() {
        entry := array_add(*music.entries);
        entry.key   = copy_string(it.key);
        entry.label = copy_string(it.label);
        entry.stalk = copy_string(it.stalk);
        entry.fight = copy_string(it.fight);
        entry.song  = copy_string(it.song);
    }
}

free_music_entries :: () {
    for music.entries {
        free(it.key);
        free(it.label);
        free(it.stalk);
        free(it.fight);
        free(it.song);
    }
    array_reset(*music.entries);
    music.listed = false;
}

// Builds the list in temporary storage.
get_music_entries :: () -> [] Music_Entry {
    names: [..] string;
    names.allocator = temp;
    for < archive: mounted_gobs {
        for archive.entries {
            if !ends_with(it.name, ".GMD") continue;
            name := path_strip_extension(it.name);
            if !array_find(names, name)  array_add(*names, name);
        }
    }
    quick_sort(names, compare);

    level_names := get_level_names();
    entries: [..] Music_Entry;
    entries.allocator = temp;
    paired: [..] string;
    paired.allocator = temp;
    for names {
        if !begins_with(it, "STALK-") continue;
        number := slice(it, 6, it.count - 6);
        fight := tprint("FIGHT-%", number);
        if !array_find(names, fight) continue;

        entry := array_add(*entries);
        entry.key   = tprint("pair %", number);
        entry.stalk = it;
        entry.fight = fight;
        digits := number;
        level, ok := parse_int(*digits);
        has_name := ok && level >= 1 && level <= level_names.count;
        entry.label = ifx has_name then tprint("%  %", number, level_names[level - 1]) else number;
        array_add(*paired, it, fight);
    }
    for names {
        if array_find(paired, it) continue;
        entry := array_add(*entries);
        entry.key   = it;
        entry.label = it;
        entry.song  = it;
    }
    return entries;
}

// The level names in JEDI.LVL: "LEVELS 14", then a line per level, "Secret Base, SECBASE, ...".
get_level_names :: () -> [..] string {
    names: [..] string;
    names.allocator = temp;
    data, found := gob_find("JEDI.LVL");
    if !found return names;
    text := cast(string) data;
    line, ok := consume_next_line(*text);
    if !ok || !begins_with(line, "LEVELS") return names;
    advance(*line, "LEVELS".count);
    count := parse_int(*line);
    for 1..count {
        line, ok = consume_next_line(*text);
        if !ok break;
        comma := find_index_from_left(line, #char ",");
        array_add(*names, trim(ifx comma >= 0 then slice(line, 0, comma) else line));
    }
    return names;
}

draw_music_list :: (entries: [] Music_Entry) {
    if ImGui.BeginChild("music", im_scale(.{220, 0}), .ResizeX | .Borders) {
        selected := to_string(music.selected.data);
        pairs_done := false;
        ImGui.SeparatorText("Levels");
        for * entries {
            if !it.stalk && !pairs_done {
                ImGui.SeparatorText("Songs");
                pairs_done = true;
            }
            if ImGui.Selectable(temp_c_string(it.label), it.key == selected, .AllowDoubleClick) {
                select_entry(it);
                if ImGui.IsMouseDoubleClicked(.Left)  start_entry(it);
            }
        }
    }
    ImGui.EndChild();
}

select_entry :: (entry: *Music_Entry) {
    n := min(entry.key.count, music.selected.count - 1);
    memcpy(music.selected.data, entry.key.data, n);
    music.selected[n] = 0;
}

find_selected_entry :: (entries: [] Music_Entry) -> *Music_Entry {
    selected := to_string(music.selected.data);
    for * entries  if it.key == selected  return it;
    return null;
}

start_entry :: (entry: *Music_Entry) {
    set_failed("");
    if entry.stalk {
        music_start_songs(entry.stalk, entry.fight);
        if !music_get_status().stalk_song  set_failed(entry.label);
    } else {
        play(entry.song);
    }
}

// Paired music, as the game plays it: a state change waits for the old song's next transition
// point, plays the transition and hands over to the new song.
draw_paired_music :: () {
    status := music_get_status();
    if !status.stalk_song return;

    ImGui.SeparatorText(temp_c_string(tprint("% / %", status.stalk_song, status.fight_song)));
    fighting := status.state == .FIGHT;
    label := ifx fighting then "Back to stalk" else "Fight!";
    if ImGui.Button(temp_c_string(label), im_scale(.{120, 0})) {
        music_set_state(ifx fighting then Music_State.STALK else .FIGHT);
    }
    ImGui.SameLine();
    ImGui.Text("State %   (was %)", status.state, status.old_state);
    if status.step == {
        case .WAITING;    ImGui.TextColored(.{1, 0.8, 0.4, 1}, "Waiting for the song's next transition point...");
        case .TRANSITION; ImGui.TextColored(.{1, 0.8, 0.4, 1}, "Playing the transition...");
        case .ENTERING;   ImGui.TextColored(.{1, 0.8, 0.4, 1}, "New song started; picking where it continues...");
        case;             ImGui.TextDisabled("Settled.");
    }
    if status.last_transition || status.last_entry {
        ImGui.Text("Last picks: transition measure %, entry measure %", status.last_transition, status.last_entry);
    }
}

draw_player :: (p: *Imuse_Player_State) {
    ImGui.PushID(p.song);
    defer ImGui.PopID();
    c := *music.controls[p.song];

    ImGui.SeparatorText(temp_c_string(p.name));
    ImGui.Text("Chunk % at %.%.%   Tempo % BPM   Priority %   Volume %", p.chunk, p.measure, p.beat,
               formatInt(p.tick, minimum_digits = 3), get_bpm_text(p.tempo_us), p.priority, p.volume);
    ImGui.Text("Marker '%'   Hook %   Jumps %   Notes %   Ringing on %", to_string(p.marker.data),
               p.hook, p.jumps, p.notes, p.sustained);
    draw_waits(p);

    if ImGui.Button("Stop") {
        audio_lock();
        imuse_stop(p.song);
        audio_unlock();
    }
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(90));
    ImGui.InputInt("frames", *c.frames, 15, 60);
    c.frames = clamp(c.frames, 0, 6000);
    ImGui.SameLine();
    if ImGui.Button("Stop later") {
        audio_lock();
        imuse_stop(p.song, c.frames);
        audio_unlock();
    }
    ImGui.SameLine();
    if ImGui.Button("Fade out") {
        audio_lock();
        imuse_fade_volume(p.song, 0, c.frames);
        audio_unlock();
    }
    ImGui.SameLine();
    if ImGui.Button("Fade in") {
        audio_lock();
        imuse_fade_volume(p.song, 127, c.frames);
        audio_unlock();
    }

    draw_number_field("chunk", *c.chunk, 1, 16);
    ImGui.SameLine();
    draw_number_field("measure", *c.measure, 1, 999);
    ImGui.SameLine();
    draw_number_field("beat", *c.beat, 1, 12);
    ImGui.SameLine();
    draw_number_field("tick", *c.tick, 0, 479);
    ImGui.SameLine();
    ImGui.Checkbox("sustain", *c.sustain);
    ImGui.SameLine();
    if ImGui.Button("Jump") {
        audio_lock();
        imuse_jump(p.song, c.chunk, c.measure, c.beat, c.tick, c.sustain);
        audio_unlock();
    }
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(80));
    ImGui.InputInt("##hook", *c.hook, 1, 10);
    c.hook = clamp(c.hook, 0, 128);
    ImGui.SameLine();
    if ImGui.Button("Set hook") {
        audio_lock();
        imuse_set_hook(p.song, c.hook);
        audio_unlock();
    }

    draw_part_table(p);
}

draw_number_field :: (label: string, value: *s32, low: s32, high: s32) {
    ImGui.SetNextItemWidth(im_scale(80));
    ImGui.InputInt(temp_c_string(label), value, 1, 10);
    value.* = clamp(value.*, low, high);
}

// What the song is waiting on: triggers, a delayed stop, a fade.
draw_waits :: (p: *Imuse_Player_State) {
    builder: String_Builder;
    builder.allocator = temp;
    if p.trigger_count {
        append(*builder, "Triggers on");
        for i: 0..p.trigger_count-1 {
            marker := p.trigger_markers[i];
            if marker == 0                 append(*builder, " any");
            else if marker == MARKER_TEXT  append(*builder, " text");
            else                           print_to_builder(*builder, " #%", marker);
        }
        append(*builder, "   ");
    }
    if p.stop_in >= 0    print_to_builder(*builder, "Stops in % frames   ", p.stop_in);
    if p.fade_to >= 0    print_to_builder(*builder, "Fading to % over % frames", p.fade_to, p.fade_frames);
    text := builder_to_string(*builder,, temp);
    if text  ImGui.TextColored(.{1, 0.8, 0.4, 1}, "%", text);
}

draw_part_table :: (p: *Imuse_Player_State) {
    flags := ImGuiTableFlags.Borders | .RowBg | .SizingFixedFit;
    if !ImGui.BeginTable("parts", 6, flags) return;
    defer ImGui.EndTable();

    for string.["Part", "Program", "Priority", "Volume", "Channel", "Notes"]  ImGui.TableSetupColumn(temp_c_string(it));
    ImGui.TableHeadersRow();
    for part, i: p.parts {
        ImGui.TableNextRow();
        ImGui.TableNextColumn(); ImGui.Text("%", i + 1);
        ImGui.TableNextColumn();
        if part.has_program  ImGui.Text("%", part.program);
        else                 ImGui.TextDisabled("drums");
        ImGui.TableNextColumn(); ImGui.Text("%", part.priority);
        ImGui.TableNextColumn(); ImGui.Text("%", part.volume);
        ImGui.TableNextColumn();
        if part.channel >= 0      ImGui.Text("%%", part.channel + 1, ifx part.shared then " (shared)" else "");
        else if part.has_program  ImGui.TextColored(.{1, 0.4, 0.4, 1}, "none");
        else                      ImGui.TextDisabled("10");
        ImGui.TableNextColumn();
        ImGui.Text("%", part.held_notes);
    }
}

stop_everything :: () {
    music_stop();
    audio_lock();
    imuse_stop_all();
    audio_unlock();
}

get_bpm_text :: (tempo_us: int) -> string {
    if !tempo_us return "-";
    return tprint("%", formatFloat(60_000_000.0 / tempo_us, trailing_width = 1));
}

// A song on its own, so paired music stops first.
play :: (name: string) {
    music_stop();
    audio_lock();
    defer audio_unlock();
    imuse_unload_all();
    song := imuse_load_midi(name);
    if !song || !imuse_play(song)  set_failed(name);
    else                           music.controls[song] = .{};
}

set_failed :: (name: string) {
    free(music.failed);
    music.failed = copy_string(name);
}

#import "Basic";
#import "Sort";
#import "String";
#import "Text_File_Handler";
#import "engine/dfArchive";
#import "engine/dfAudio";
#import "engine/dfFm";
#import "engine/dfIMuse";
#import "engine/dfMusic";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
