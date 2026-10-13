// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Viewer windows for single assets, opened from the archive browser: each kind with what makes
// sense for it (sprites by action, view and frame; 3D objects turning; sounds played; LFD art
// frame by frame), and the original's lighting to try on anything drawn: the sector's light,
// the world light, the headlight and the distance, through the level's colormap. Every viewer
// also shows the file's bytes.

open_asset_viewer :: (asset: *Asset) {
    for viewers if it.asset == asset {
        ImGui.SetWindowFocus(temp_c_string(get_viewer_title(it)));
        return;
    }
    viewer := New(Viewer);
    viewer.asset = asset;
    viewer.id = next_viewer_id;
    next_viewer_id += 1;
    asset.pinned += 1;
    // Lit, at a typical sector's light, so the colormap shows; 31 would skip it.
    if asset.kind == .MODEL || asset.kind == .WAX || asset.kind == .FRAME  viewer.preview.lit = true;
    viewer.preview.lighting.sector_ambient = 24;
    array_add(*viewers, viewer);
}

show_asset_viewers :: () {
    for viewers {
        if !show_viewer(it) {
            close_viewer(it);
            remove it;
        }
    }
}

close_asset_viewers :: () {
    for viewers close_viewer(it);
    array_reset(*viewers);
}

// A sound's waveform, with a playhead at the sample given (-1 for none).
draw_waveform :: (draw_list: *ImDrawList, asset: *Asset, a: ImVec2, b: ImVec2, playhead: s64) {
    middle := (a.y + b.y) * 0.5;
    half := (b.y - a.y) * 0.5;
    draw_list.AddLine(draw_list, .{a.x, middle}, .{b.x, middle}, 0xFF404040);
    if !asset.waveform return;
    width := b.x - a.x;
    sound := *asset.sound;
    if sound.loop_start >= 0 && sound.samples.count {
        x0 := a.x + width * sound.loop_start / sound.samples.count;
        x1 := a.x + width * sound.loop_end / sound.samples.count;
        draw_list.AddRectFilled(draw_list, .{x0, a.y}, .{x1, b.y}, 0x30FFB040);
    }
    columns := max(cast(s64) width, 1);
    for x: 0..columns-1 {
        c0 := x * WAVEFORM_COLUMNS / columns;
        c1 := max((x + 1) * WAVEFORM_COLUMNS / columns, c0 + 1);
        lo, hi: u8 = 255, 0;
        for c: c0..min(c1, WAVEFORM_COLUMNS)-1 {
            lo = min(lo, asset.waveform[c][0]);
            hi = max(hi, asset.waveform[c][1]);
        }
        y0 := middle - (cast(float) hi - 128) / 128.0 * half;
        y1 := middle - (cast(float) lo - 128) / 128.0 * half;
        draw_list.AddLine(draw_list, .{a.x + x + 0.5, y0}, .{a.x + x + 0.5, y1 + 1}, 0xFF60D0A0);
    }
    if playhead >= 0 && sound.samples.count {
        x := a.x + width * playhead / sound.samples.count;
        draw_list.AddLine(draw_list, .{x, a.y}, .{x, b.y}, 0xFFFFFFFF);
    }
}

// 16 x 16 swatches. A PLTT only sets a range; the rest is drawn hatched.
draw_palette_grid :: (draw_list: *ImDrawList, palette: *Palette, a: ImVec2, b: ImVec2, partial := false, pltt: [] u8 = .[]) -> hovered: s32 {
    first, last := 0, 255;
    if partial && pltt.count >= 2  first, last = pltt[0], pltt[1];
    cell := ImVec2.{(b.x - a.x) / 16, (b.y - a.y) / 16};
    hovered: s32 = -1;
    mouse := ImGui.GetMousePos();
    for i: 0..255 {
        p0 := ImVec2.{a.x + (i % 16) * cell.x, a.y + (i / 16) * cell.y};
        p1 := ImVec2.{p0.x + cell.x, p0.y + cell.y};
        if i < first || i > last {
            draw_list.AddLine(draw_list, p0, p1, 0xFF404040);
        } else {
            draw_list.AddRectFilled(draw_list, p0, p1, get_color_u32(palette.colors[i]));
        }
        if mouse.x >= p0.x && mouse.x < p1.x && mouse.y >= p0.y && mouse.y < p1.y  hovered = xx i;
    }
    return hovered;
}

// The colormap's 32 light levels (darkest at the top) through the palette, every step-th
// column of each.
draw_colormap :: (draw_list: *ImDrawList, colormap: *Colormap, palette: *Palette, a: ImVec2, b: ImVec2, columns: s32) {
    step := 256 / columns;
    cell := ImVec2.{(b.x - a.x) / columns, (b.y - a.y) / LIGHT_LEVELS};
    for level: 0..LIGHT_LEVELS-1 {
        for column: 0..columns-1 {
            index := colormap.levels[level][column * step];
            p0 := ImVec2.{a.x + column * cell.x, a.y + level * cell.y};
            draw_list.AddRectFilled(draw_list, p0, .{p0.x + cell.x + 0.5, p0.y + cell.y + 0.5}, get_color_u32(palette.colors[index]));
        }
    }
}

// The first glyphs of a 1-bit LFD font, scaled to fit.
draw_lfd_font_sample :: (draw_list: *ImDrawList, font: *Lfd_Font, a: ImVec2, b: ImVec2, text := "ABC abc 123") {
    if !font.widths return;
    total: s32;
    for text {
        c := cast(s32) it - font.first;
        if c >= 0 && c < font.widths.count  total += font.widths[c];
    }
    scale := max(floor(min((b.x - a.x) / max(total, 1), (b.y - a.y) / max(font.height, 1))), 1.0);
    x := a.x + ((b.x - a.x) - total * scale) * 0.5;
    y := a.y + ((b.y - a.y) - font.height * scale) * 0.5;
    for text {
        c := cast(s32) it - font.first;
        if c < 0 || c >= font.widths.count continue;
        for row: 0..font.height-1 {
            bits := font.rows[c * font.height + row];
            for col: 0..font.widths[c]-1 {
                if bits & (0x8000 >> col) {
                    p0 := ImVec2.{x + col * scale, y + row * scale};
                    draw_list.AddRectFilled(draw_list, p0, .{p0.x + scale, p0.y + scale}, 0xFFE0E0E0);
                }
            }
        }
        x += font.widths[c] * scale;
    }
}

get_color_u32 :: (c: Color) -> u32 {
    return 0xFF000000 | ((cast(u32) c.b) << 16) | ((cast(u32) c.g) << 8) | c.r;
}

#scope_file

Viewer :: struct {
    asset:   *Asset;
    id:      s64;
    view:    View;
    preview: Preview;
    clock:   float64;           // The viewer's own time, paused with the animation.
    animate: bool = true;
    turn:    bool = true;       // Turn a 3D object, or step a sprite through its views.
    turn_speed: float = 0.6;    // Radians per second.
    flash: s32;                 // Weapon flash, 0..31.
    loop_sound: bool;
    zoom:    s32;               // Texture and art: 0 fits; otherwise pixels per texel.
}

viewers: [..] *Viewer;
next_viewer_id: s64;

get_viewer_title :: (viewer: *Viewer) -> string {
    return tprint("% (%)##viewer%", viewer.asset.entry.name, path_filename(viewer.asset.archive.path), viewer.id);
}

close_viewer :: (viewer: *Viewer) {
    if viewer.asset.kind == .SOUND  audio_stop_sound();
    render_release_view(*viewer.view);
    viewer.asset.pinned -= 1;
    free(viewer);
}

show_viewer :: (viewer: *Viewer) -> bool {
    asset := viewer.asset;
    open := true;
    ImGui.SetNextWindowSize(im_scale(.{720, 560}), .FirstUseEver);
    visible := ImGui.Begin(temp_c_string(get_viewer_title(viewer)), *open);
    defer ImGui.End();
    if !open return false;
    if !visible return true;

    if viewer.animate  viewer.clock += ImGui.GetIO().DeltaTime;
    if viewer.turn     viewer.preview.yaw += viewer.turn_speed * ImGui.GetIO().DeltaTime;
    viewer.preview.time = viewer.clock;
    // As DARK.EXE sets it each frame: the light source is the brighter of the headlight (31
    // with a charged battery) and a weapon flash.
    source := max(cast(s32) (ifx viewer.preview.lighting.headlight then 31 else 0), viewer.flash);
    viewer.preview.lighting.world_ambient = 31 - source;

    ok := load_asset(asset, get_browser_frame());
    ImGui.Text("% bytes in %, %", asset.entry.data.count, asset.archive.path, ASSET_KIND_LABELS[asset.kind]);
    if asset.shadowed ImGui.TextColored(.{1, 0.7, 0.3, 1}, "Shadowed: a GOB mounted later has a file of this name, and the game loads that one.");

    if ImGui.BeginTabBar("tabs") {
        if ok && asset.kind != .OTHER && asset.kind != .MUSIC && ImGui.BeginTabItem("View") {
            draw_viewer_contents(viewer);
            ImGui.EndTabItem();
        }
        if asset.kind == .TEXT || asset.kind == .MODEL {
            if ImGui.BeginTabItem("Text") {
                if ImGui.BeginChild("text", child_flags = .Borders, window_flags = .HorizontalScrollbar)  ImGui.TextUnformatted(cast(string) asset.entry.data);
                ImGui.EndChild();
                ImGui.EndTabItem();
            }
        }
        if ImGui.BeginTabItem("Bytes") {
            if ImGui.BeginChild("hex", child_flags = .Borders, window_flags = .HorizontalScrollbar)  draw_hex_view(asset.entry.data);
            ImGui.EndChild();
            ImGui.EndTabItem();
        }
        ImGui.EndTabBar();
    }
    if !ok  ImGui.TextColored(.{1, 0.4, 0.4, 1}, "Can't decode this file.");
    return true;
}

draw_viewer_contents :: (viewer: *Viewer) {
    asset := viewer.asset;
    p := *viewer.preview;

    if asset.kind == {
        case .TEXTURE;
            t := *asset.texture;
            ImGui.Text("% x %, % frame%%%", t.frames[0].width, t.frames[0].height, t.frames.count, ifx t.frames.count == 1 then "" else "s",
                       ifx t.animated then tprint(", % fps%", t.frame_rate, ifx t.frame_rate == 0 then " (a switch)" else "") else "",
                       ifx t.transparent then ", transparent" else "");
            if t.frames.count > 1  draw_frame_controls(viewer, t.frames.count);
            ImGui.Checkbox("As a floor", *p.floor);
            if p.floor  p.lit = true;
            ImGui.SameLine();
            draw_lighting_controls(viewer, distance = !p.floor);
            draw_view(viewer);

        case .FRAME; #through;
        case .WAX;
            draw_sprite_controls(viewer);
            draw_lighting_controls(viewer);
            draw_view(viewer);

        case .MODEL;
            m := *asset.model;
            ImGui.Text("% vertices, % polygons, % texture%%%", m.vertices.count, m.polygons.count, m.textures.count, ifx m.textures.count == 1 then "" else "s",
                       ifx m.vertex_lit then ", vertex lit" else "", ifx m.draw_vertices then ", drawn as points" else "");
            for m.textures  { ImGui.SameLine(); ImGui.TextDisabled("%", ifx it then it else "<none>"); }
            draw_turn_controls(viewer);
            draw_lighting_controls(viewer);
            draw_view(viewer);

        case .DELT; #through;
        case .ANIM;
            a := *asset.anim;
            if a.frames {
                f := *a.frames[0];
                ImGui.Text("% frame%, first at (%, %) size % x %%", a.frames.count, ifx a.frames.count == 1 then "" else "s", f.x, f.y, f.image.width, f.image.height,
                           ifx asset.has_own_palette then ", in its LFD's palette" else ", in the level palette");
            }
            if a.frames.count > 1  draw_frame_controls(viewer, a.frames.count);
            draw_view(viewer);

        case .FNT;
            ImGui.Text("% glyphs from '%', % high", asset.font.glyphs.count, string.{1, *asset.font.first}, asset.font.height);
            draw_view(viewer);

        case .FONT;
            f := *asset.lfd_font;
            ImGui.Text("% glyphs from %, % high", f.widths.count, f.first, f.height);
            a := ImGui.GetCursorScreenPos();
            size := ImGui.GetContentRegionAvail();
            draw_lfd_font_sample(ImGui.GetWindowDrawList(), f, a, .{a.x + size.x, a.y + 80}, "The quick brown fox, 0123456789!");
            draw_lfd_font_sample(ImGui.GetWindowDrawList(), f, .{a.x, a.y + 90}, .{a.x + size.x, a.y + 170}, "THE QUICK BROWN FOX");

        case .SOUND;
            draw_sound(viewer);

        case .PALETTE; #through;
        case .PLTT;
            if asset.kind == .PLTT  ImGui.Text("Sets entries % to %", asset.entry.data[0], asset.entry.data[1]);
            a := ImGui.GetCursorScreenPos();
            side := min(ImGui.GetContentRegionAvail().x, ImGui.GetContentRegionAvail().y - im_scale(30), im_scale(512));
            hovered := draw_palette_grid(ImGui.GetWindowDrawList(), *asset.palette, a, .{a.x + side, a.y + side}, asset.kind == .PLTT, asset.entry.data);
            ImGui.Dummy(.{side, side});
            if hovered >= 0 {
                c := asset.palette.colors[hovered];
                ImGui.Text("Index %: % % %", hovered, c.r, c.g, c.b);
            }

        case .COLORMAP;
            pal := get_preview_palette();
            ImGui.Text("Through %.PAL. Light level 0 (darkest) at the top, 31 at the bottom; the ramp below is the headlight's falloff by distance.", pal.name);
            a := ImGui.GetCursorScreenPos();
            width := ImGui.GetContentRegionAvail().x;
            draw_list := ImGui.GetWindowDrawList();
            draw_colormap(draw_list, *asset.colormap, *pal.palette, a, .{a.x + width, a.y + im_scale(256)}, 256);
            ramp_top := a.y + im_scale(266);
            for i: 0..LIGHT_RAMP_COUNT-1 {
                x0 := a.x + width * i / LIGHT_RAMP_COUNT;
                x1 := a.x + width * (i + 1) / LIGHT_RAMP_COUNT;
                h := im_scale(60) * (31 - min(asset.colormap.light_ramp[i], 31)) / 31.0;
                draw_list.AddRectFilled(draw_list, .{x0, ramp_top + im_scale(60) - h}, .{x1, ramp_top + im_scale(60)}, 0xFF40A0FF);
            }
            ImGui.Dummy(.{width, im_scale(330)});
    }
}

draw_view :: (viewer: *Viewer) {
    size := ImGui.GetContentRegionAvail();
    size.y = max(size.y, 64);
    scale := ImGui.GetIO().DisplayFramebufferScale;
    draw_asset_preview(viewer.asset, *viewer.view, cast(s32) (size.x * scale.x), cast(s32) (size.y * scale.y), viewer.preview, get_preview_palette());
    if viewer.view.color  ImGui.Image(.{_TexID = cast(ImTextureID) viewer.view.color}, size);
}

draw_frame_controls :: (viewer: *Viewer, count: s64) {
    ImGui.Checkbox("Animate", *viewer.animate);
    ImGui.SameLine();
    if viewer.animate {
        viewer.preview.frame = -1;
    } else {
        if viewer.preview.frame < 0  viewer.preview.frame = 0;
        ImGui.SetNextItemWidth(im_scale(200));
        ImGui.SliderInt("Frame", *viewer.preview.frame, 0, xx (count - 1));
    }
}

draw_turn_controls :: (viewer: *Viewer) {
    ImGui.Checkbox("Turn", *viewer.turn);
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(160));
    if viewer.turn {
        ImGui.SliderFloat("Speed", *viewer.turn_speed, -3, 3, "%.2f rad/s");
    } else {
        degrees := viewer.preview.yaw * 180 / PI;
        degrees -= 360 * floor(degrees / 360);
        if ImGui.SliderFloat("Angle", *degrees, 0, 360, "%.0f deg")  viewer.preview.yaw = degrees * PI / 180;
    }
}

draw_sprite_controls :: (viewer: *Viewer) {
    sprite := *viewer.asset.sprite;
    p := *viewer.preview;
    if viewer.asset.kind == .WAX {
        p.action = clamp(p.action, 0, xx (sprite.actions.count - 1));
        action := *sprite.actions[p.action];
        ImGui.SetNextItemWidth(im_scale(220));
        label := tprint("% (% views, % frames, % fps)", p.action, action.views.count, ifx action.views then action.views[0].frames.count else 0, action.frame_rate);
        if ImGui.BeginCombo("Action", temp_c_string(label)) {
            for sprite.actions {
                text := tprint("% (% views, % frames, % fps)", it_index, it.views.count, ifx it.views then it.views[0].frames.count else 0, it.frame_rate);
                if ImGui.Selectable(temp_c_string(text), it_index == p.action)  p.action = xx it_index;
            }
            ImGui.EndCombo();
        }
        ImGui.SameLine();
        ImGui.Text("World size % x %", action.world_width / 65536.0, action.world_height / 65536.0);
        max_frames := 0;
        for action.views  max_frames = max(max_frames, it.frames.count);
        if max_frames > 1  draw_frame_controls(viewer, max_frames);
        else ImGui.NewLine();
        draw_turn_controls(viewer);
    } else {
        frame := sprite.actions[0].views[0].frames[0];
        cell := sprite.cells[frame.cell];
        ImGui.Text("% x %, inserted at (%, %)%", cell.width, cell.height, frame.insert_x, frame.insert_y, ifx frame.flip then ", flipped" else "");
    }
}

draw_lighting_controls :: (viewer: *Viewer, distance := true) {
    p := *viewer.preview;
    ImGui.Checkbox("Lit", *p.lit);
    if !p.lit return;
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(110));
    ImGui.SliderInt("Sector light", *p.lighting.sector_ambient, 0, 31);
    ImGui.SameLine();
    ImGui.Checkbox("Headlight", *p.lighting.headlight);
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(90));
    ImGui.SliderInt("Flash", *viewer.flash, 0, 31);
    if distance {
        ImGui.SameLine();
        ImGui.SetNextItemWidth(im_scale(140));
        format := ifx p.distance <= 0 then "fit" else "%.1f units";
        ImGui.SliderFloat("Distance", *p.distance, 0, 120, temp_c_string(format));
    }
}

draw_sound :: (viewer: *Viewer) {
    asset := viewer.asset;
    sound := *asset.sound;
    seconds := cast(float) sound.samples.count / sound.rate;
    ImGui.Text("% Hz, % samples, % s", sound.rate, sound.samples.count, formatFloat(seconds, trailing_width = 2));
    if sound.loop_start >= 0 {
        ImGui.SameLine();
        count := ifx sound.loop_count == 0xFFFF then "forever" else tprint("count %", sound.loop_count);
        ImGui.Text(", loops % to % (%)", sound.loop_start, sound.loop_end, count);
    }
    if ImGui.Button("Play")  audio_play_sound(sound.*, viewer.loop_sound);
    ImGui.SameLine();
    if ImGui.Button("Stop")  audio_stop_sound();
    if sound.loop_start >= 0 {
        ImGui.SameLine();
        ImGui.Checkbox("Loop", *viewer.loop_sound);
    }

    position, playing := audio_get_sound_position();
    a := ImGui.GetCursorScreenPos();
    size := ImGui.GetContentRegionAvail();
    size.y = clamp(size.y, im_scale(80), im_scale(300));
    draw_list := ImGui.GetWindowDrawList();
    draw_list.AddRectFilled(draw_list, a, .{a.x + size.x, a.y + size.y}, 0xFF181818);
    draw_waveform(draw_list, asset, a, .{a.x + size.x, a.y + size.y}, ifx playing then position else -1);
    ImGui.Dummy(size);
}

draw_hex_view :: (data: [] u8) {
    LIMIT :: 64 * 1024;
    count := min(data.count, LIMIT);
    if data.count > LIMIT  ImGui.TextDisabled("Showing the first % bytes.", LIMIT);
    lines := (count + 15) / 16;
    clipper: ImGuiListClipper;
    clipper.Begin(*clipper, xx lines);
    while clipper.Step(*clipper) {
        for line: clipper.DisplayStart..clipper.DisplayEnd-1 {
            builder: String_Builder;
            builder.allocator = temp;
            start := line * 16;
            print_to_builder(*builder, "%  ", formatInt(start, base = 16, minimum_digits = 8));
            for 0..15 {
                if start + it < count  print_to_builder(*builder, "% ", formatInt(data[start + it], base = 16, minimum_digits = 2));
                else                   append(*builder, "   ");
            }
            append(*builder, " ");
            for 0..15 {
                if start + it >= count break;
                c := data[start + it];
                append(*builder, ifx c >= 32 && c < 127 then c else #char ".");
            }
            ImGui.TextUnformatted(builder_to_string(*builder,, temp));
        }
    }
    clipper.End(*clipper);
}

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/dfLandru";
#import "engine/dfAudio";
#import "engine/dfRender";
