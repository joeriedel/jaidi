// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The debug panel, in every build: a window over the game with what's going on in it. The
// frame times, from profile.jai's zones, as a graph of the last frames and a flame graph of
// one. In a cutscene, the scene, its cell, the timing and fades, the music and sounds, the
// actors and the palette, with controls to pause, step, go to a cell or a scene of the
// cinematic. In a level, the player and the sector it's in, the agent's stats and inventory,
// the enemies and the world's counts, with the command line that starts a level where the
// player stands. It starts hidden and costs nothing until opened.
//
// While a level runs the panel takes no input, so the mouse still looks around; with the
// level paused (the Pause key) the pointer is free and the panel takes it. Over the original's menus,
// which draw their own cursor, the panel has the mouse only while the pointer is over it.

DEBUG_PANEL_KEY :: SDLK_INSERT;

// The cutscene's clock held, the panel's or, while it plays one, the Cutscenes tool's.
is_cutscene_paused :: () -> bool {
    #if DEV {
        _, driving := get_cutscene_tool_clock();
        if driving return is_cutscene_tool_paused();
    }
    return debug_panel.clock.paused;
}

set_cutscene_paused :: (paused: bool) {
    #if DEV {
        _, driving := get_cutscene_tool_clock();
        if driving { set_cutscene_tool_paused(paused); return; }
    }
    c := *debug_panel.clock;
    if paused == c.paused return;
    base := get_base_clock();
    if paused  c.paused_at = get_debug_panel_clock(base);
    else       c.shift = cast(s64) c.paused_at - cast(s64) base;
    c.paused = paused;
}

toggle_debug_panel :: () { debug_panel.open = !debug_panel.open; }

// Whether it wants the desktop's cursor and the mouse's buttons.
is_debug_panel_using_mouse :: () -> bool {
    if !debug_panel.open || (game.playing && !game.paused) return false;
    if is_menu_shown() return ImGui.GetIO().WantCaptureMouse;
    return true;
}

// The cutscene's clock: the base clock, unless the panel paused or moved it.
get_debug_panel_clock :: (base: u64) -> u64 {
    c := *debug_panel.clock;
    if c.paused return c.paused_at;
    return cast(u64) (cast(s64) base + c.shift);
}

show_debug_panel :: () {
    d := *debug_panel;
    if !d.open return;
    viewport := ImGui.GetMainViewport();
    ImGui.SetNextWindowPos(.{viewport.WorkPos.x + viewport.WorkSize.x - im_scale(16), viewport.WorkPos.y + im_scale(16)}, .FirstUseEver, .{1, 0});
    ImGui.SetNextWindowSize(im_scale(ImVec2.{460, 640}), .FirstUseEver);
    ImGui.SetNextWindowBgAlpha(0.85);
    flags := ImGuiWindowFlags.NoFocusOnAppearing;
    if game.playing && !game.paused  flags |= .NoInputs;
    if ImGui.Begin("Debug", null, flags) {
        draw_frame_times();
        if game.playing {
            ImGui.TextDisabled(ifx game.paused then "Paused. Pause resumes." else "Pause the level (the Pause key) to use the panel.");
            draw_level_info();
        } else if cutscene_is_playing() {
            draw_cutscene_info();
        } else {
            ImGui.TextDisabled("No level or cutscene running.");
        }
    }
    ImGui.End();
}

#scope_file

debug_panel: struct {
    open:   bool;
    selected_mob: s32 = -1;     // Its object.

    // Frozen, the graphs show a copy of the frames as they were.
    frozen: bool;
    frames: [PROFILE_FRAMES] Profile_Frame;
    frame_count: s32;
    selected_frame: s32;        // Its age, 0 the last, in the flame graph.

    clock: struct {
        shift: s64;             // From the base clock.
        paused: bool;
        paused_at: u64;
    };
};

draw_frame_times :: () {
    d := *debug_panel;
    if !ImGui.CollapsingHeader("Frame time", .DefaultOpen) return;
    if ImGui.Checkbox("Freeze", *d.frozen) {
        if d.frozen  freeze_frames();
        else         d.selected_frame = 0;
    }
    count := ifx d.frozen then d.frame_count else profile_get_frame_count();
    if !count return;

    total, worst: float64;
    for 0..count-1 {
        ms := get_frame_ms(get_frame(xx it));
        total += ms;
        worst = max(worst, ms);
    }
    ImGui.SameLine();
    ImGui.Text("average % ms (% fps), worst % ms", formatFloat(total / count, trailing_width = 2), formatFloat(1000 * count / total, trailing_width = 0),
               formatFloat(worst, trailing_width = 2));

    // The last frames, the newest on the right, each a bar of its top zones stacked; the line
    // is 60 fps. Up to 30 fps or three times the average fits, so one slow frame (a level
    // loading) doesn't flatten the rest; anything over is cut off at the top.
    draw_list := ImGui.GetWindowDrawList();
    origin := ImGui.GetCursorScreenPos();
    width := ImGui.GetContentRegionAvail().x;
    height := im_scale(70.0);
    scale := max(cast(float) (3 * total / count), 1000.0 / 30);
    bar := width / (PROFILE_FRAMES - 1);
    draw_list.AddRectFilled(draw_list, origin, .{origin.x + width, origin.y + height}, 0x60000000);
    for age: 0..count-1 {
        frame := get_frame(xx age);
        x := origin.x + width - (age + 1) * bar;
        bottom := origin.y + height;
        for zone: frame.zones {
            if it_index >= frame.count break;
            if zone.depth != 0 || !zone.end continue;
            h := cast(float) ((zone.end - zone.start) / 1_000_000.0) / scale * height;
            draw_list.AddRectFilled(draw_list, .{x, max(bottom - h, origin.y)}, .{x + max(bar - 1, 1), bottom}, get_zone_color(zone.name));
            bottom = max(bottom - h, origin.y);
        }
        top := max(origin.y + height - cast(float) get_frame_ms(frame) / scale * height, origin.y);
        if bottom > top  draw_list.AddRectFilled(draw_list, .{x, top}, .{x + max(bar - 1, 1), bottom}, 0xFF808080);
        if d.frozen && age == d.selected_frame  draw_list.AddRect(draw_list, .{x - 1, top - 1}, .{x + bar, origin.y + height}, 0xFFFFFFFF);
    }
    line := origin.y + height - (1000.0 / 60) / scale * height;
    draw_list.AddLine(draw_list, .{origin.x, line}, .{origin.x + width, line}, 0x8000FFFF);
    ImGui.InvisibleButton("frames", .{width, height});
    if ImGui.IsItemHovered() {
        age := cast(s32) ((origin.x + width - ImGui.GetMousePos().x) / bar);
        if age >= 0 && age < count {
            ImGui.SetTooltip("% ms, % frames ago%", formatFloat(get_frame_ms(get_frame(age)), trailing_width = 2), age, ifx d.frozen then "" else " (click to freeze)");
            if ImGui.IsItemClicked() {
                if !d.frozen { freeze_frames(); d.frozen = true; }
                d.selected_frame = age;
            }
        }
    }

    // The frame's zones, nested ones under the zone they're in.
    frame := get_frame(min(d.selected_frame, count - 1));
    span := cast(float) (frame.end - frame.start);
    if span <= 0 return;
    row := ImGui.GetTextLineHeightWithSpacing();
    depth := 0;
    for 0..frame.count-1  depth = max(depth, frame.zones[it].depth + 1);
    origin = ImGui.GetCursorScreenPos();
    ImGui.InvisibleButton("flame", .{width, row * max(depth, 1)});
    hovered := ImGui.IsItemHovered();
    mouse := ImGui.GetMousePos();
    for zone: frame.zones {
        if it_index >= frame.count break;
        if !zone.end continue;
        p0 := ImVec2.{origin.x + (zone.start - frame.start) / span * width, origin.y + zone.depth * row};
        p1 := ImVec2.{origin.x + (zone.end - frame.start) / span * width, p0.y + row - 1};
        p1.x = max(p1.x, p0.x + 1);
        draw_list.AddRectFilled(draw_list, p0, p1, get_zone_color(zone.name));
        draw_list.PushClipRect(draw_list, p0, p1, true);
        draw_list.AddText(draw_list, ImVec2.{p0.x + 3, p0.y}, 0xFF000000, zone.name);
        draw_list.PopClipRect(draw_list);
        if hovered && mouse.x >= p0.x && mouse.x < p1.x && mouse.y >= p0.y && mouse.y < p1.y {
            ImGui.SetTooltip("% % ms", zone.name, formatFloat((zone.end - zone.start) / 1_000_000.0, trailing_width = 3));
        }
    }
}

freeze_frames :: () {
    d := *debug_panel;
    d.frame_count = profile_get_frame_count();
    for 0..d.frame_count-1  d.frames[it] = profile_get_frame(xx it).*;
    d.selected_frame = 0;
}

// Its age, 0 the last.
get_frame :: (age: s32) -> *Profile_Frame {
    if debug_panel.frozen return *debug_panel.frames[age];
    return profile_get_frame(age);
}

get_frame_ms :: (frame: *Profile_Frame) -> float64 { return (frame.end - frame.start) / 1_000_000.0; }

// A zone's color by its name, the same every frame.
get_zone_color :: (name: string) -> u32 {
    COLORS :: u32.[0xFF6FB6E8, 0xFF7FD48A, 0xFFE89A6F, 0xFFD47FC4, 0xFF6FE0E0, 0xFFB0A0F0, 0xFF80C0FF, 0xFFA0E0B0];
    hash: u32 = 2166136261;
    for 0..name.count-1  hash = (hash ^ name[it]) * 16777619;
    return COLORS[hash % COLORS.count];
}

draw_level_info :: () {
    player := world_get_player();
    level := world_get_level();
    tick := world_get_tick();
    ImGui.Text("%, tick % (% s)", world_get_name(), tick, formatFloat(tick / TIMER_HZ, trailing_width = 2));

    if ImGui.CollapsingHeader("Player", .DefaultOpen) {
        x, y, z := fixed_to_float(player.position.x), fixed_to_float(player.position.y), fixed_to_float(player.position.z);
        yaw := player.object_yaw * 360.0 / 16384;
        pitch := player.pitch * 360.0 / 16384;
        ImGui.Text("Feet  %, %, %", format_coordinate(x), format_coordinate(y), format_coordinate(z));
        ImGui.Text("Yaw %  pitch %  eye height %", format_coordinate(yaw), format_coordinate(pitch), format_coordinate(fixed_to_float(player.height)));
        ImGui.Text("Velocity %, %  up %", format_coordinate(fixed_to_float(player.velocity.x)), format_coordinate(fixed_to_float(player.velocity.z)), format_coordinate(fixed_to_float(player.up_velocity)));
        ImGui.Text("On floor %  in water %", player.on_floor, player.in_water);
        // The place and time, as the command line that starts a level there.
        command := tprint("--level % --level-at %,%,% --level-yaw % --level-pitch % --level-tick %", world_get_name(),
                          format_coordinate(x), format_coordinate(y), format_coordinate(z), format_coordinate(yaw), format_coordinate(pitch), tick);
        if ImGui.Button("Copy")  ImGui.SetClipboardText(temp_c_string(command));
        ImGui.SameLine();
        ImGui.TextWrapped("%", command);
    }

    if ImGui.CollapsingHeader("Cheats and views", .DefaultOpen) {
        state := world_get_player_state();
        god := state.invincible == -2;
        if ImGui.Checkbox("God mode", *god)  state.invincible = ifx god then cast(s32) -2 else 0;
        ImGui.SameLine();
        if ImGui.Button("Give everything")  world_give_everything();
        ImGui.SameLine();
        ImGui.TextDisabled("(weapons, ammo, keys, gear)");
        // The light alone, white at its level: only Enhanced lights in color.
        if game.draw.original  ImGui.BeginDisabled();
        ImGui.Checkbox("Show lighting only", *game.draw.light_only);
        if game.draw.original {
            ImGui.EndDisabled();
            ImGui.SameLine();
            ImGui.TextDisabled("(Enhanced Mode)");
        }
    }

    if ImGui.CollapsingHeader("Sector", .DefaultOpen) {
        draw_sector_info(level, player.sector, "In");
        if player.floor_sector != player.sector  draw_sector_info(level, player.floor_sector, "Over");
    }

    if ImGui.CollapsingHeader("Agent", .DefaultOpen) {
        agent := world_get_agent();
        state := world_get_player_state();
        ImGui.Text("Health %1  shields %2  lives %3  battery %4%5", agent.health, agent.shields, agent.lives, agent.battery * 100 / BATTERY_FULL, "%");
        ImGui.Text("Weapon %1%2", state.current_weapon, ifx world_is_weapon_holstered() then " (holstered)" else "");
        builder: String_Builder;
        builder.allocator = temp;
        for agent.ammo  print_to_builder(*builder, "% % ", cast(Ammo) it_index, it);
        ImGui.TextWrapped("Ammo %", builder_to_string(*builder,, temp));
        for agent.items {
            if it <= 0 || it_index == 0 continue;
            print_to_builder(*builder, "% ", cast(Item_Slot) it_index);
        }
        items := builder_to_string(*builder,, temp);
        ImGui.TextWrapped("Items %", ifx items then items else "none");
        if state.headlamp     append(*builder, "headlamp ");
        if state.goggles_on   append(*builder, "goggles ");
        if state.mask_on      append(*builder, "mask ");
        if state.cleats_on    append(*builder, "cleats ");
        if state.invincible   append(*builder, "invincible ");
        if state.supercharged append(*builder, "supercharged ");
        on := builder_to_string(*builder,, temp);
        ImGui.Text("On: %", ifx on then on else "nothing");
        ImGui.Text("Secrets %1 of %2 (%3%4)  mission %5", state.secrets_found, state.secrets, world_get_secrets_percent(), "%",
                   ifx world_is_mission_complete() then "complete" else "not complete");
    }

    if ImGui.CollapsingHeader("Enemies", .DefaultOpen) {
        mobs := world_list_mobs();
        flags := ImGuiTableFlags.RowBg | .BordersInnerV | .ScrollY | .SizingFixedFit;
        height := ImGui.GetTextLineHeightWithSpacing() * (min(mobs.count, 12) + 1.5);
        if mobs.count && ImGui.BeginTable("mobs", 6, flags, .{0, height}) {
            ImGui.TableSetupScrollFreeze(0, 1);
            ImGui.TableSetupColumn("Object");
            ImGui.TableSetupColumn("Art");
            ImGui.TableSetupColumn("Sector");
            ImGui.TableSetupColumn("Distance");
            ImGui.TableSetupColumn("HP");
            ImGui.TableSetupColumn("State", .WidthStretch);
            ImGui.TableHeadersRow();
            eye := Vector2.{fixed_to_float(player.position.x), fixed_to_float(player.position.z)};
            for mobs {
                ImGui.TableNextRow();
                ImGui.TableSetColumnIndex(0);
                label := temp_c_string(tprint("%", it.object));
                if ImGui.Selectable(label, it.object == debug_panel.selected_mob, .SpanAllColumns) {
                    debug_panel.selected_mob = ifx it.object == debug_panel.selected_mob then -1 else it.object;
                }
                ImGui.TableSetColumnIndex(1);
                ImGui.Text("% (%)", it.art, it.kind);
                ImGui.TableSetColumnIndex(2);
                ImGui.Text("%", it.sector);
                ImGui.TableSetColumnIndex(3);
                at := Vector2.{fixed_to_float(it.position.x), fixed_to_float(it.position.z)};
                ImGui.Text("%", formatFloat(length(at - eye), trailing_width = 1));
                ImGui.TableSetColumnIndex(4);
                ImGui.Text("%", formatFloat(fixed_to_float(it.hp), trailing_width = 0));
                ImGui.TableSetColumnIndex(5);
                ImGui.Text("%", it.state);
            }
            ImGui.EndTable();
        }
        ImGui.Text("% enemies", mobs.count);
        for mobs {
            if it.object != debug_panel.selected_mob continue;
            ImGui.SeparatorText(temp_c_string(tprint("Object %", it.object)));
            ImGui.Text("% %", it.kind, it.art);
            ImGui.Text("At %, %, %  sector %", format_coordinate(fixed_to_float(it.position.x)), format_coordinate(fixed_to_float(it.position.y)),
                       format_coordinate(fixed_to_float(it.position.z)), it.sector);
            o := world_get_objects()[it.object];
            ImGui.Text("Yaw %  action %  frame %  lit %", format_coordinate(o.yaw * 360.0 / 16384), o.anim, o.frame, o.lit);
            actor := world_get_actor(it.object);
            if actor {
                ImGui.Text("Flags 0x%  aware range %", formatInt(actor.flags, base = 16), format_coordinate(fixed_to_float(actor.aware_range)));
                ImGui.Text("Last saw the player at %, %", format_coordinate(fixed_to_float(actor.last_seen.x)), format_coordinate(fixed_to_float(actor.last_seen.z)));
            }
        }
    }

    if ImGui.CollapsingHeader("World") {
        objects := 0;
        for world_get_objects()  if it && it.used  objects += 1;
        elevators, triggers, teleports := world_get_inf_counts();
        ImGui.Text("Objects %  projectiles %  actors %", objects, world_get_projectile_count(), world_get_actor_count());
        ImGui.Text("Tasks %", world_get_task_order().count);
        ImGui.Text("INF: % elevators, % triggers, % teleports", elevators, triggers, teleports);
        ImGui.Text("Sectors %  textures %", level.sectors.count, level.textures.count);
    }
}

draw_cutscene_info :: () {
    c, playing := cutscene_get_debug();
    if !playing return;
    if ImGui.CollapsingHeader("Scene", .DefaultOpen) {
        draw_cutscene_controls(c);
        ImGui.Text("Scene %  film %  (%)", c.scene.id, c.scene.film, c.scene.archive);
        ImGui.Text("Next %  skip %  speed %  frame delay % ticks", c.scene.next, c.scene.skip, c.scene.speed, c.frame_delay);
        ImGui.Text("Cell % of %  at % s, %", c.cell, c.cell_count, formatFloat(c.seconds, trailing_width = 3), ifx c.blitting then "blitting" else "waiting");
        ImGui.Text("Fade % (% of %)  color % (% of %)", c.fade, c.fade_step, c.fade_length, c.color_fade, c.color_step, c.color_length);
        ImGui.Text("Music sequence %, cue %", c.music_sequence, c.music_cue);
        builder: String_Builder;
        builder.allocator = temp;
        for c.sounds  print_to_builder(*builder, "%1%2%3 ", it.name, ifx it.voice then " (voice)" else "", ifx it.keep then " (kept)" else "");
        sounds := builder_to_string(*builder,, temp);
        ImGui.TextWrapped("Sounds %", ifx sounds then sounds else "none");
    }

    if ImGui.CollapsingHeader("Actors", .DefaultOpen) {
        actors := cutscene_list_actors();
        flags := ImGuiTableFlags.RowBg | .BordersInnerV | .ScrollY | .SizingFixedFit;
        height := ImGui.GetTextLineHeightWithSpacing() * (min(actors.count, 14) + 1.5);
        if actors.count && ImGui.BeginTable("actors", 7, flags, .{0, height}) {
            ImGui.TableSetupScrollFreeze(0, 1);
            ImGui.TableSetupColumn("Name");
            ImGui.TableSetupColumn("Kind");
            ImGui.TableSetupColumn("At");
            ImGui.TableSetupColumn("Z");
            ImGui.TableSetupColumn("Cell");
            ImGui.TableSetupColumn("Moving");
            ImGui.TableSetupColumn("Clip", .WidthStretch);
            ImGui.TableHeadersRow();
            for actors {
                ImGui.TableNextRow();
                if !it.visible  ImGui.PushStyleColor(.Text, ImGui.GetColorU32(.TextDisabled));
                ImGui.TableSetColumnIndex(0);
                ImGui.Text("%1%2", it.name, ifx it.flip then " (flipped)" else "");
                ImGui.TableSetColumnIndex(1);
                ImGui.Text("%", it.kind);
                ImGui.TableSetColumnIndex(2);
                ImGui.Text("%, %", it.x, it.y);
                ImGui.TableSetColumnIndex(3);
                ImGui.Text("%", it.z);
                ImGui.TableSetColumnIndex(4);
                if it.kind == .ANIM  ImGui.Text("% of %", it.state, it.cells);
                else if it.kind == .CUSTOM  ImGui.Text("var % %", it.var1, it.var2);
                ImGui.TableSetColumnIndex(5);
                if it.x_vel || it.y_vel || it.state_vel  ImGui.Text("%, % / %", it.x_vel, it.y_vel, it.state_vel);
                ImGui.TableSetColumnIndex(6);
                ImGui.Text("% % % %", it.clip.left, it.clip.top, it.clip.right, it.clip.bottom);
                if !it.visible  ImGui.PopStyleColor();
            }
            ImGui.EndTable();
        }
        ImGui.TextDisabled("% actors, the back first; hidden ones greyed.", actors.count);
    }

    if ImGui.CollapsingHeader("Palette") {
        palette := cutscene_get_palette();
        draw_list := ImGui.GetWindowDrawList();
        origin := ImGui.GetCursorScreenPos();
        cell := min(ImGui.GetContentRegionAvail().x / 16, im_scale(14.0));
        for palette.colors {
            x := origin.x + (it_index % 16) * cell;
            y := origin.y + (it_index / 16) * cell;
            color := 0xFF000000 | (cast(u32) it.b << 16) | (cast(u32) it.g << 8) | it.r;
            draw_list.AddRectFilled(draw_list, .{x, y}, .{x + cell - 1, y + cell - 1}, color);
        }
        ImGui.InvisibleButton("palette", .{cell * 16, cell * 16});
        if ImGui.IsItemHovered() {
            mouse := ImGui.GetMousePos();
            index := cast(s32) ((mouse.y - origin.y) / cell) * 16 + cast(s32) ((mouse.x - origin.x) / cell);
            if index >= 0 && index < 256 {
                c := palette.colors[index];
                ImGui.SetTooltip("% (%, %, %)", index, c.r, c.g, c.b);
            }
        }
    }
}

// Seeking replays the scene from its start, so a cell shows as it does when the cinematic
// starts at that scene.
draw_cutscene_controls :: (c: Cutscene_Debug) {
    paused := is_cutscene_paused();
    if ImGui.Button(temp_c_string(ifx paused then "Resume###pause" else "Pause###pause"))  set_cutscene_paused(!paused);
    ImGui.SameLine();
    if ImGui.Button("Step") {
        // On to the player's next event: a frame, or a step of a fade.
        set_cutscene_paused(true);
        next := cutscene_get_next_event_time();
        if next > get_clock()  set_cutscene_time(next);
    }
    ImGui.SameLine();
    if ImGui.Button("<")  seek_cutscene(c.scene.id, c.cell - 1);
    ImGui.SameLine();
    if ImGui.Button(">")  seek_cutscene(c.scene.id, c.cell + 1);
    ImGui.SameLine();
    cell := c.cell;
    ImGui.SetNextItemWidth(-1);
    if ImGui.SliderInt("##cell", *cell, 1, max(c.cell_count, 1), "cell %d")  seek_cutscene(c.scene.id, cell);

    // The cinematic's scenes: back to the one no other leads to, then on by each next.
    list := cutscene_get_list();
    first := c.scene.id;
    seen: [..] s32;
    seen.allocator = temp;
    while !array_find(seen, first) {
        array_add(*seen, first);
        before: s32;
        for list  if it.next == first && it.id != first  before = it.id;
        if !before break;
        first = before;
    }
    array_reset(*seen);
    id := first;
    ImGui.AlignTextToFramePadding();
    ImGui.Text("Scenes");
    while id > 0 && !array_find(seen, id) {
        array_add(*seen, id);
        entry: *Cutscene_Entry;
        for * list  if it.id == id  entry = it;
        if !entry break;
        ImGui.SameLine();
        label := temp_c_string(tprint("%1 %2##scene%1", id, entry.film));
        if id == c.scene.id  ImGui.PushStyleColor(.Button, ImGui.GetColorU32(.ButtonActive));
        if ImGui.Button(label)  seek_cutscene(id, 1);
        if id == c.scene.id  ImGui.PopStyleColor();
        id = entry.next;
    }
}

seek_cutscene :: (scene: s32, cell: s32) {
    ok, time := cutscene_seek(scene, max(cell, 1));
    if ok  set_cutscene_time(time);
}

// The clock cutscene_update gets, set to a time.
set_cutscene_time :: (time: u64) {
    #if DEV {
        _, driving := get_cutscene_tool_clock();
        if driving { set_cutscene_tool_time(time); return; }
    }
    c := *debug_panel.clock;
    if c.paused  c.paused_at = time;
    else         c.shift = cast(s64) time - cast(s64) get_base_clock();
}

draw_sector_info :: (level: *Level, index: s32, label: string) {
    if index < 0 || index >= level.sectors.count {
        ImGui.Text("% no sector", label);
        return;
    }
    s := *level.sectors[index];
    ImGui.Text("%1 sector %2%3  layer %4", label, index, ifx s.name then tprint(" (%)", s.name) else "", s.layer);
    ImGui.Text("  Floor %  ceiling %  second %  light %", format_coordinate(fixed_to_float(s.floor.altitude)), format_coordinate(fixed_to_float(s.ceiling.altitude)),
               format_coordinate(fixed_to_float(s.second_altitude)), format_coordinate(fixed_to_float(s.ambient)));
    ImGui.Text("  Floor % ceiling %", get_texture_name(level, s.floor.texture), get_texture_name(level, s.ceiling.texture));
    ImGui.TextWrapped("  Flags 0x% 0x% 0x% %", formatInt(s.flags[0], base = 16), formatInt(s.flags[1], base = 16), formatInt(s.flags[2], base = 16), get_sector_flag_names(s.flags[0]));
}

get_texture_name :: (level: *Level, texture: s32) -> string {
    if texture < 0 || texture >= level.textures.count return "-";
    return level.textures[texture];
}

get_sector_flag_names :: (flags: u32) -> string {
    NAMES :: struct { flag: u32; name: string; }.[
        .{SECTOR_EXTERIOR, "exterior"}, .{SECTOR_DOOR, "door"}, .{SECTOR_MAG_SEAL, "mag seal"},
        .{SECTOR_EXTERIOR_ADJ, "exterior adjoin"}, .{SECTOR_ICE, "ice"}, .{SECTOR_SNOW, "snow"},
        .{SECTOR_EXPLODING_WALL, "exploding wall"}, .{SECTOR_PIT, "pit"}, .{SECTOR_PIT_ADJ, "pit adjoin"},
        .{SECTOR_CRUSHING, "crushing"}, .{SECTOR_NO_WALLS, "no walls"}, .{SECTOR_LOW_DAMAGE, "low damage"},
        .{SECTOR_HIGH_DAMAGE, "high damage"}, .{SECTOR_NO_SMART, "no smart"}, .{SECTOR_SMART, "smart"},
        .{SECTOR_SAFE, "safe"}, .{SECTOR_SEEN, "seen"}, .{SECTOR_SECRET, "secret"},
    ];
    builder: String_Builder;
    builder.allocator = temp;
    for NAMES  if flags & it.flag  print_to_builder(*builder, " %", it.name);
    return builder_to_string(*builder,, temp);
}

// Two places, enough for a unit's tenth and to find the spot again.
format_coordinate :: (f: float) -> string {
    s := tprint("%", formatFloat(f, trailing_width = 2, zero_removal = .NO));
    while s.count && s[s.count - 1] == #char "0"  s.count -= 1;
    if s.count && s[s.count - 1] == #char "."  s.count -= 1;
    if s == "-0"  s = "0";
    return s;
}

#import "Basic";
#import "Math";
#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "engine/dfImGui";
#import "engine/dfLevel";
#import "engine/dfFixed";
#import "engine/dfWorld";
#import "engine/dfCutscene";
#import "engine/dfImage";
