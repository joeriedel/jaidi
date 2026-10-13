// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tool: plays any of the game's cinematics, Original or Enhanced. CUTSCENE.LST lists scenes,
// each naming the scene that follows it; a cinematic is a chain of them, starting at a scene no
// other leads to. The cutscene shows as it does in play, the whole window, with a small window of
// controls over it: pause, step to the player's next event, restart, next scene, stop, and the
// scene's in-betweens. Before playing it fits the in-betweens for the whole cinematic, with a
// progress bar, so it plays with all of them from the start; Skip plays it at once, the rest
// fitting as it goes, and pairs not fitted yet hold. It runs the cutscene on a clock of its
// own, which stops while paused.

show_cutscene_tool :: (open: *bool, settings: *Cutscene_Settings) {
    t := *cutscene_tool;
    if t.pending_scene {
        play_tool_cinematic(t.pending_scene);
        t.pending_scene = 0;
    }

    ImGui.SetNextWindowSize(im_scale(.{620, 640}), .FirstUseEver);
    visible := ImGui.Begin("Cutscenes", open);
    defer ImGui.End();
    if !visible return;

    list := cutscene_get_list();
    if !list.count {
        ImGui.TextDisabled("No CUTSCENE.LST: cutscenes are off.");
        return;
    }
    if !t.selected  t.selected = list[0].id;

    ImGui.Checkbox("Enhanced", *settings.enhanced);

    if t.preparing {
        // Fitting the cinematic's in-betweens; it starts when they're all in, or on Skip.
        done, total := cutscene_get_prepared_fits(t.preparing);
        start := done >= total;
        if !start {
            overlay := temp_c_string(tprint("Fitting in-betweens: % of %", done, total));
            ImGui.ProgressBar(cast(float) done / total, overlay = overlay);
            start = ImGui.Button("Skip");
            ImGui.SameLine();
        }
        if start {
            scene := t.preparing;
            t.preparing = 0;
            start_tool_cutscene(scene);
            return;
        }
        if ImGui.Button("Cancel") {
            cutscene_drop_fits();
            t.preparing = 0;
        }
        return;
    }

    if ImGui.Button("Play")  play_tool_cinematic(t.selected);
    ImGui.SameLine();
    ImGui.TextDisabled("Double-click a cinematic to play it.");

    flags := ImGuiTableFlags.RowBg | .BordersInnerV | .ScrollY;
    if ImGui.BeginTable("cinematics", 3, flags) {
        ImGui.TableSetupScrollFreeze(0, 1);
        ImGui.TableSetupColumn("First scene", .WidthFixed);
        ImGui.TableSetupColumn("LFD", .WidthFixed);
        ImGui.TableSetupColumn("Films, in order", .WidthStretch);
        ImGui.TableHeadersRow();
        for list {
            if is_led_to(list, it.id) continue;
            ImGui.TableNextRow();
            ImGui.TableSetColumnIndex(0);
            label := temp_c_string(tprint("%", it.id));
            if ImGui.Selectable(label, it.id == t.selected, .SpanAllColumns | .AllowDoubleClick) {
                t.selected = it.id;
                if ImGui.IsMouseDoubleClicked(.Left)  play_tool_cinematic(it.id);
            }
            ImGui.TableSetColumnIndex(1);
            ImGui.Text("%", it.archive);
            ImGui.TableSetColumnIndex(2);
            ImGui.TextWrapped("%", get_chain_films(list, it.id));
        }
        ImGui.EndTable();
    }
}

// Over the cutscene while the tool plays one.
show_cutscene_tool_controls :: (settings: *Cutscene_Settings) {
    t := *cutscene_tool;
    if !t.driving return;
    ImGui.SetNextWindowPos(im_scale(.{16, 16}), .FirstUseEver);
    ImGui.SetNextWindowBgAlpha(0.8);
    flags := ImGuiWindowFlags.AlwaysAutoResize | .NoSavedSettings | .NoFocusOnAppearing;
    if ImGui.Begin("Cutscene Controls", flags = flags) {
        ImGui.Text("Scene %, cell %", cutscene_get_scene(), cutscene_get_cell());
        if ImGui.Button(temp_c_string(ifx t.paused then "Resume###pause" else "Pause###pause"))  t.paused = !t.paused;
        ImGui.SameLine();
        if ImGui.Button("Step") {
            t.paused = true;
            next := cutscene_get_next_event_time();
            if next > t.time  t.time = next;
        }
        ImGui.SameLine();
        if ImGui.Button("Restart")  start_tool_cutscene(t.playing);
        ImGui.SameLine();
        if ImGui.Button("Next scene")  cutscene_next();
        ImGui.SameLine();
        if ImGui.Button("Stop") {
            cutscene_stop();
            t.driving = false;
        }
        ImGui.Checkbox("Enhanced", *settings.enhanced);

        ImGui.SeparatorText("In-betweens");
        done, used, total := cutscene_get_fit_progress();
        if total {
            ImGui.Text("% pairs: % warped, % crossfaded", total, used, done - used);
            if done < total  ImGui.Text("% still fitting (held)", total - done);
        } else {
            ImGui.TextDisabled("None in this scene.");
        }
    }
    ImGui.End();
}

// Moves the tool's clock on by the time since the last frame, unless it is paused. Once a
// frame, before the cutscene is updated.
advance_cutscene_tool_clock :: (base: u64) {
    t := *cutscene_tool;
    delta := ifx t.last_base && base > t.last_base then base - t.last_base else 0;
    t.last_base = base;
    if !t.driving return;
    if !cutscene_is_playing() {
        t.driving = false;
        return;
    }
    if !t.paused  t.time += delta;
}

// While the tool plays a cutscene, the clock it runs on.
get_cutscene_tool_clock :: () -> u64, bool {
    t := *cutscene_tool;
    return t.time, t.driving;
}

// --tool cutscene with --scene: that scene, selected and playing.
request_tool_cutscene :: (scene: s32) {
    cutscene_tool.selected = scene;
    cutscene_tool.pending_scene = scene;
}

#scope_file

cutscene_tool: struct {
    selected:      s32;     // The cinematic's first scene.
    playing:       s32;     // The scene Play started at.
    pending_scene: s32;     // From the command line, started on the first frame.
    preparing:     s32;     // The scene whose cinematic's fits are being waited for.
    driving:       bool;    // The cutscene playing is the tool's, on its clock.
    paused:        bool;
    time:          u64;     // Nanoseconds, from when the tool first played.
    last_base:     u64;
};

// Some other scene's next.
is_led_to :: (list: [] Cutscene_Entry, id: s32) -> bool {
    for list  if it.next == id && it.id != id  return true;
    return false;
}

// The films a chain plays, "logo, swlogo, ...", stopping at a scene already passed.
get_chain_films :: (list: [] Cutscene_Entry, id: s32) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    seen: [..] s32;
    seen.allocator = temp;
    at := id;
    while at > 0 && !array_find(seen, at) {
        array_add(*seen, at);
        entry: *Cutscene_Entry;
        for * list  if it.id == at  entry = it;
        if !entry break;
        if seen.count > 1  append(*builder, ", ");
        append(*builder, entry.film);
        at = entry.next;
    }
    return builder_to_string(*builder,, temp);
}

// Whether shown Original or Enhanced, which can change while it plays. Fixed-step runs
// (screenshots) wait for each fit as it's drawn already.
play_tool_cinematic :: (scene: s32) {
    if !is_fixed_clock() {
        cutscene_prepare_fits(scene);
        cutscene_tool.preparing = scene;
        return;
    }
    start_tool_cutscene(scene);
}

start_tool_cutscene :: (scene: s32) {
    t := *cutscene_tool;
    if cutscene_is_playing()  cutscene_stop();
    t.playing = scene;
    t.paused = false;
    t.driving = cutscene_start(scene, t.time);
}

#import "Basic";
#import "engine/dfCutscene";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
