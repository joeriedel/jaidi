// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tool: plays any of the game's cinematics, Original or Enhanced. CUTSCENE.LST lists scenes,
// each naming the scene that follows it; a cinematic is a chain of them, starting at a scene no
// other leads to. The cutscene shows as it does in play, the whole window, with a small window of
// controls over it, an audio player's: restart, previous and next scene, rewind and fast-forward
// while held, play, pause and stop; and the scene's in-betweens. The debug panel steps a frame
// at a time. Before playing it fits the in-betweens for the whole cinematic, with a
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
    // Held buttons count only while they're drawn held.
    t.rewinding, t.fast_forward = false, false;
    if ImGui.Begin("Cutscene Controls", flags = flags) {
        ImGui.SeparatorText("Cinematic");
        if draw_icon_button("restart", .RESTART, "Restart the cinematic")  start_tool_cutscene(t.playing);
        ImGui.SameLine();
        if draw_icon_button("previous", .PREVIOUS, "Restart the scene; in its first second, the scene before") {
            scene := cutscene_get_scene();
            previous := find_previous_scene(scene);
            if previous && t.time - t.scene_start < SCENE_BACK_NS  scene = previous;
            seek_tool_cutscene(scene, 1);
            cutscene_sync_music();
        }
        ImGui.SameLine();
        _, t.rewinding = draw_icon_button("rewind", .REWIND, "Rewind, held (picture only)");
        ImGui.SameLine();
        if draw_icon_button("play", .PLAY, "Play", enabled = t.paused)  t.paused = false;
        ImGui.SameLine();
        if draw_icon_button("pause", .PAUSE, "Pause", enabled = !t.paused)  t.paused = true;
        ImGui.SameLine();
        _, t.fast_forward = draw_icon_button("fast_forward", .FAST_FORWARD, "Fast-forward, held");
        ImGui.SameLine();
        if draw_icon_button("next", .NEXT, "The next scene")  cutscene_next();
        ImGui.SameLine();
        if draw_icon_button("stop", .STOP, "Stop") {
            cutscene_stop();
            t.driving = false;
        }
        film := "";
        for cutscene_get_list()  if it.id == cutscene_get_scene()  film = it.film;
        ImGui.Text("Scene % (%), cell %", cutscene_get_scene(), film, cutscene_get_cell());
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
    if t.driving && !cutscene_is_playing()  t.driving = false;
    fast := t.driving && t.fast_forward && !t.rewinding;
    set_audio_speed(ifx fast then cast(float) FAST_SPEED else 1);
    if !t.driving return;
    if cutscene_get_scene() != t.scene {
        t.scene = cutscene_get_scene();
        t.scene_start = t.time;
    }
    // Let go of rewind, the music is put back where the cues have it.
    if t.was_rewinding && !t.rewinding  cutscene_sync_music();
    t.was_rewinding = t.rewinding;
    if !t.rewinding  t.rewind_debt = 0;
    if t.rewinding           rewind_tool_cutscene(delta);
    else if fast             t.time += delta * FAST_SPEED;
    else if !t.paused        t.time += delta;
}

// While the tool plays a cutscene, the clock it runs on.
get_cutscene_tool_clock :: () -> u64, bool {
    t := *cutscene_tool;
    return t.time, t.driving;
}

// For the debug panel, while the tool plays a cutscene: its clock paused or not, and set.
set_cutscene_tool_paused :: (paused: bool) { cutscene_tool.paused = paused; }
// Rewinding holds the audio too, which can't run backwards; fast-forward runs through a pause.
is_cutscene_tool_paused :: () -> bool {
    t := *cutscene_tool;
    return (t.paused && !t.fast_forward) || t.rewinding;
}
set_cutscene_tool_time :: (time: u64) { cutscene_tool.time = time; }

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
    scene:         s32;     // The scene playing, and when on the clock it started.
    scene_start:   u64;
    rewinding:     bool;    // The held buttons, this frame.
    fast_forward:  bool;
    was_rewinding: bool;
    rewind_debt:   u64;     // Time rewound not yet a whole cell.
    audio_speed:   float = 1;
};

// Within this of a scene's start, the previous-scene button goes to the scene before, as an
// audio player's does.
SCENE_BACK_NS :: 1_000_000_000;
REWIND_SPEED  :: 4;
FAST_SPEED    :: 4;
TIMER_HZ      :: 1193182.0 / 8192.0;   // The game's clock, which Landru's frame delays count twice.

// The scene before this one in its chain, or 0.
find_previous_scene :: (id: s32) -> s32 {
    for cutscene_get_list()  if it.next == id && it.id != id  return it.id;
    return 0;
}

// The scene played up to the cell, the tool's clock carried on from there. The seek starts the
// cutscene's clock at 0, so the clock is the time into the scene.
seek_tool_cutscene :: (scene: s32, cell: s32) {
    t := *cutscene_tool;
    ok, time := cutscene_seek(scene, cell);
    if !ok {
        t.driving = false;
        return;
    }
    t.time = time;
    t.scene = scene;
    t.scene_start = 0;
}

// Back a cell at a time, REWIND_SPEED cells for each one's time held, by seeking: the film
// only plays forward. Past a scene's first cell, to the previous scene's last.
rewind_tool_cutscene :: (delta: u64) {
    t := *cutscene_tool;
    t.rewind_debt += delta * REWIND_SPEED;
    cell_ns := cast(u64) ((cutscene_get_frame_delay() + 1) / 2 / TIMER_HZ * 1_000_000_000);
    steps := t.rewind_debt / cell_ns;
    if !steps return;
    t.rewind_debt -= steps * cell_ns;
    scene, cell := cutscene_get_scene(), cutscene_get_cell() - cast(s32) min(steps, 1000);
    if cell < 1 {
        previous := find_previous_scene(scene);
        if previous  scene, cell = previous, S32_MAX;
        else         cell = 1;
    }
    if scene == cutscene_get_scene() && cell == cutscene_get_cell() return;
    seek_tool_cutscene(scene, cell);
}

set_audio_speed :: (ratio: float) {
    t := *cutscene_tool;
    if ratio == t.audio_speed return;
    audio_set_speed(ratio);
    t.audio_speed = ratio;
}

Icon :: enum u8 { RESTART; PREVIOUS; REWIND; PLAY; PAUSE; FAST_FORWARD; NEXT; STOP; }

// A button with a drawn icon (the font has none), and whether it's held.
draw_icon_button :: (id: string, icon: Icon, tip: string, enabled := true) -> pressed: bool, held: bool {
    ImGui.BeginDisabled(!enabled);
    height := ImGui.GetFrameHeight();
    pressed := ImGui.Button(temp_c_string(tprint("##%", id)), .{height * 1.4, height});
    held := ImGui.IsItemActive();
    ImGui.SetItemTooltip("%", tip);
    lo, hi := ImGui.GetItemRectMin(), ImGui.GetItemRectMax();
    draw_icon(ImGui.GetWindowDrawList(), icon, .{(lo.x + hi.x) / 2, (lo.y + hi.y) / 2}, height * 0.28, ImGui.GetColorU32(.Text));
    ImGui.EndDisabled();
    return pressed && enabled, held && enabled;
}

// In a square 2h across about c.
draw_icon :: (list: *ImDrawList, icon: Icon, c: ImVec2, h: float, color: u32) {
    // Pointing from a base at x0 to a tip at x1.
    triangle :: (x0: float, x1: float) #expand {
        fill_triangle(list, .{x0, c.y - h}, .{x1, c.y}, .{x0, c.y + h}, color);
    }
    bar :: (x0: float, x1: float) #expand {
        list.AddRectFilled(list, .{x0, c.y - h}, .{x1, c.y + h}, color);
    }
    if icon == {
      case .PLAY;          triangle(c.x - h * 0.8, c.x + h);
      case .PAUSE;         bar(c.x - h * 0.8, c.x - h * 0.25); bar(c.x + h * 0.25, c.x + h * 0.8);
      case .STOP;          list.AddRectFilled(list, .{c.x - h * 0.85, c.y - h * 0.85}, .{c.x + h * 0.85, c.y + h * 0.85}, color);
      case .PREVIOUS;      bar(c.x - h, c.x - h * 0.65); triangle(c.x + h, c.x - h * 0.65);
      case .NEXT;          bar(c.x + h * 0.65, c.x + h); triangle(c.x - h, c.x + h * 0.65);
      case .REWIND;        triangle(c.x, c.x - h * 1.1); triangle(c.x + h * 1.1, c.x);
      case .FAST_FORWARD;  triangle(c.x, c.x + h * 1.1); triangle(c.x - h * 1.1, c.x);
      case .RESTART;
        // An open circle turning back on itself, the arrowhead at its upper right.
        r := h * 0.8;
        thickness := h * 0.3;
        SEGMENTS :: 20;
        from, to := -0.25 * PI, 1.25 * PI;
        last := ImVec2.{c.x + r * cos(from), c.y + r * sin(from)};
        for 1..SEGMENTS {
            a := from + (to - from) * it / SEGMENTS;
            p := ImVec2.{c.x + r * cos(a), c.y + r * sin(a)};
            list.AddLine(list, last, p, color, thickness);
            last = p;
        }
        p := ImVec2.{c.x + r * cos(from), c.y + r * sin(from)};
        along := ImVec2.{sin(from), -cos(from)};     // Back along the circle, the way it turns.
        across := ImVec2.{-along.y, along.x};
        w := h * 0.55;
        fill_triangle(list, .{p.x + along.x * w, p.y + along.y * w}, .{p.x + across.x * w, p.y + across.y * w}, .{p.x - across.x * w, p.y - across.y * w}, color);
    }
}

// Clockwise on the screen, as ImGui's anti-aliased fill needs.
fill_triangle :: (list: *ImDrawList, a: ImVec2, b: ImVec2, c: ImVec2, color: u32) {
    if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) < 0  list.AddTriangleFilled(list, a, c, b, color);
    else                                                          list.AddTriangleFilled(list, a, b, c, color);
}

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
#import "Math";
#import "engine/dfAudio";
#import "engine/dfCutscene";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
