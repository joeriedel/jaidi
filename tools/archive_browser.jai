// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tool: every file in the mounted GOBs and the LFDs, as a grid of thumbnails drawn the way
// the game draws them: textures and fonts as images, sprites walking, 3D objects turning, LFD
// art in its palette, sounds as waveforms, palettes and colormaps as swatches. Double-click
// one to open it in a viewer of its own (asset_viewer.jai).
//
// A file that a later GOB also contains is marked as shadowed, since loads never reach it.

show_archive_browser :: (open: *bool) {
    browser.frame += 1;
    if browser.reload_every_frame {
        // Nothing recorded for this frame yet, so even visible thumbnails can go.
        for * browser.assets  if !it.pinned  unload_asset(it);
    }
    ImGui.SetNextWindowSize(im_scale(.{1100, 720}), .FirstUseEver);
    visible := ImGui.Begin("Archive Browser", open);
    defer ImGui.End();
    if !open.* {
        close_archive_browser();
        return;
    }
    defer show_asset_viewers();
    defer evict_assets();
    if !visible return;

    if !mounted_gobs {
        ImGui.TextUnformatted("No GOBs mounted: the game data wasn't found in dark/.");
        return;
    }
    if !render_is_ready() {
        ImGui.TextUnformatted("The renderer didn't start, so nothing can be shown.");
        return;
    }
    if browser.mount_count != mounted_gobs.count  build_assets();
    if browser.open_on_start {
        for * browser.assets {
            if !it.shadowed && equal_nocase(it.entry.name, browser.open_on_start) {
                open_asset_viewer(it);
                break;
            }
        }
        browser.open_on_start = "";
    }

    draw_browser_controls();

    shown: [..] s32;
    shown.allocator = temp;
    filter := to_string(browser.filter.data);
    for browser.assets {
        if it.shadowed && !browser.show_shadowed continue;
        if browser.kind_filter >= 0 && it.kind != cast(Asset_Kind) browser.kind_filter continue;
        if filter && !contains_nocase(it.entry.name, filter) && !contains_nocase(path_filename(it.archive.path), filter) continue;
        array_add(*shown, xx it_index);
    }
    ImGui.SameLine();
    ImGui.Text("% of % files", shown.count, browser.assets.count);

    if ImGui.BeginChild("grid", child_flags = .Borders) draw_grid(shown);
    ImGui.EndChild();
}

// Opens the named file's viewer once the browser has listed the files.
open_in_archive_browser :: (name: string) {
    browser.open_on_start = name;
}

set_archive_browser_filter :: (text: string) {
    count := min(text.count, browser.filter.count - 1);
    memcpy(browser.filter.data, text.data, count);
    browser.filter[count] = 0;
}

shutdown_archive_browser :: () {
    close_archive_browser();
}

// The palette and colormap GOB previews are drawn with.
get_preview_palette :: () -> *Preview_Palette {
    return *browser.palette;
}

// Dev: unloads every thumbnail at the start of each frame, so loading runs constantly.
set_archive_browser_reload :: (on: bool) {
    browser.reload_every_frame = on;
}

get_browser_frame :: () -> s64 {
    return browser.frame;
}

#scope_file

browser: struct {
    assets:      [..] Asset;
    lfds:        [..] *Archive;
    mount_count: int = -1;
    frame:       s64;
    selected:    int = -1;
    filter:      [64] u8;
    kind_filter: s32 = -1;
    show_shadowed: bool;
    cell_size:   s32 = 96;
    palette:     Preview_Palette;
    palette_names: [..] string;
    open_on_start: string;
    reload_every_frame: bool;
};

build_assets :: () {
    close_archive_browser();
    for < archive: mounted_gobs {
        for * archive.entries {
            entry := gob_find_entry(it.name);
            asset := array_add(*browser.assets);
            asset.entry = it;
            asset.archive = archive;
            asset.kind = get_asset_kind(it.name);
            asset.shadowed = entry != it;
            if asset.kind == .PALETTE && !asset.shadowed  array_add(*browser.palette_names, path_strip_extension(it.name));
        }
    }
    dark_dir := find_dark_data_dir();
    files := file_list(tprint("%/LFD", dark_dir));
    quick_sort(files, compare);
    for files {
        archive, ok := archive_open(it);
        if !ok continue;
        array_add(*browser.lfds, archive);
        for * archive.entries {
            asset := array_add(*browser.assets);
            asset.entry = it;
            asset.archive = archive;
            asset.kind = get_asset_kind(it.name);
        }
    }
    quick_sort(browser.palette_names, compare);
    browser.mount_count = mounted_gobs.count;
    browser.selected = -1;
    choose_palette("SECBASE");
}

close_archive_browser :: () {
    close_asset_viewers();
    for * browser.assets unload_asset(it);
    array_reset(*browser.assets);
    for browser.lfds archive_close(it);
    array_reset(*browser.lfds);
    array_reset(*browser.palette_names);
    render_release_colormap(*browser.palette.gpu_colormap);
    browser.palette = .{};
    browser.mount_count = -1;
}

// A level's PAL and the CMP of the same name; levels without one get DEFAULT.CMP.
choose_palette :: (name: string) {
    data, found := gob_find(tprint("%.PAL", name));
    if !found return;
    palette, ok := pal_parse(data);
    if !ok return;
    cmp, has_cmp := gob_find(tprint("%.CMP", name));
    if !has_cmp  cmp, has_cmp = gob_find("DEFAULT.CMP");
    colormap: Colormap;
    if has_cmp  colormap = cmp_parse(cmp);

    render_release_colormap(*browser.palette.gpu_colormap);
    browser.palette.name = name;
    browser.palette.palette = palette;
    browser.palette.colormap = colormap;
    browser.palette.gpu_colormap = render_upload_colormap(*colormap);
}

draw_browser_controls :: () {
    ImGui.SetNextItemWidth(im_scale(200));
    ImGui.InputTextWithHint("##filter", "Filter by name or archive", browser.filter.data, browser.filter.count);
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(150));
    preview := ifx browser.kind_filter < 0 then "All kinds" else ASSET_KIND_LABELS[browser.kind_filter];
    if ImGui.BeginCombo("##kind", temp_c_string(preview)) {
        if ImGui.Selectable("All kinds", browser.kind_filter < 0)  browser.kind_filter = -1;
        for ASSET_KIND_LABELS {
            if ImGui.Selectable(temp_c_string(it), browser.kind_filter == it_index)  browser.kind_filter = xx it_index;
        }
        ImGui.EndCombo();
    }
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(130));
    if ImGui.BeginCombo("Palette", temp_c_string(browser.palette.name)) {
        for browser.palette_names {
            if ImGui.Selectable(temp_c_string(it), it == browser.palette.name)  choose_palette(it);
        }
        ImGui.EndCombo();
    }
    ImGui.SameLine();
    ImGui.Checkbox("Shadowed", *browser.show_shadowed);
    ImGui.SameLine();
    ImGui.SetNextItemWidth(im_scale(100));
    ImGui.SliderInt("Size", *browser.cell_size, 48, 192);
}

draw_grid :: (shown: [] s32) {
    style := ImGui.GetStyle();
    cell := im_scale(cast(float) browser.cell_size);
    label_height := ImGui.GetTextLineHeight();
    item := ImVec2.{cell, cell + label_height + 2};
    spacing := style.ItemSpacing.x;
    per_row := max(cast(s32) ((ImGui.GetContentRegionAvail().x + spacing) / (item.x + spacing)), 1);
    rows := (shown.count + per_row - 1) / per_row;
    scale := ImGui.GetIO().DisplayFramebufferScale;

    clipper: ImGuiListClipper;
    clipper.Begin(*clipper, xx rows, item.y + style.ItemSpacing.y);
    while clipper.Step(*clipper) {
        for row: clipper.DisplayStart..clipper.DisplayEnd-1 {
            for column: 0..per_row-1 {
                i := row * per_row + column;
                if i >= shown.count break;
                if column ImGui.SameLine();
                draw_cell(shown[i], item, cell, scale);
            }
        }
    }
    clipper.End(*clipper);
}

draw_cell :: (index: s32, item: ImVec2, cell: float, scale: ImVec2) {
    asset := *browser.assets[index];
    ImGui.PushID(index);
    defer ImGui.PopID();

    pos := ImGui.GetCursorScreenPos();
    clicked := ImGui.InvisibleButton("cell", item);
    hovered := ImGui.IsItemHovered();
    if clicked  browser.selected = index;
    if hovered && ImGui.IsMouseDoubleClicked(.Left)  open_asset_viewer(asset);
    if hovered  ImGui.SetTooltip("%\n% bytes in %\n%%", asset.entry.name, asset.entry.data.count, path_filename(asset.archive.path),
                                 ASSET_KIND_LABELS[asset.kind], ifx asset.shadowed then " (shadowed by a later GOB)" else "");

    draw_list := ImGui.GetWindowDrawList();
    top_left := pos;
    bottom_right := ImVec2.{pos.x + cell, pos.y + cell};
    selected := browser.selected == index;
    fill: u32 = cast(u32) (ifx selected then 0xFF704020 else 0xFF201C18);
    draw_list.AddRectFilled(draw_list, top_left, bottom_right, fill);

    draw_thumbnail(asset, draw_list, top_left, bottom_right, scale);

    outline: u32 = cast(u32) (ifx selected then 0xFFFFB060 else 0xFF808080);
    if selected || hovered  draw_list.AddRect(draw_list, top_left, bottom_right, outline);
    label := asset.entry.name;
    color: u32 = cast(u32) (ifx asset.shadowed then 0xFF707070 else 0xFFE0E0E0);
    clip := ImVec4.{pos.x, pos.y, pos.x + cell, pos.y + item.y};
    draw_list.AddText(draw_list, ImGui.GetFont(), ImGui.GetFontSize(), .{pos.x + 2, pos.y + cell + 1}, color, label, cell, *clip);
}

draw_thumbnail :: (asset: *Asset, draw_list: *ImDrawList, top_left: ImVec2, bottom_right: ImVec2, scale: ImVec2) {
    INSET :: 3.0;
    a := ImVec2.{top_left.x + INSET, top_left.y + INSET};
    b := ImVec2.{bottom_right.x - INSET, bottom_right.y - INSET};

    if asset.kind == .MUSIC || asset.kind == .TEXT || asset.kind == .OTHER || asset.kind == .FILM {
        draw_kind_label(asset, draw_list, a, b);
        return;
    }
    if !load_asset(asset, browser.frame) {
        draw_list.AddText(draw_list, .{a.x, a.y}, 0xFF6060FF, "can't read");
        return;
    }

    if is_drawn_in_view(asset.kind) {
        p: Preview;
        p.time = ImGui.GetTime();
        p.yaw  = cast(float) (p.time * 0.6);
        width  := cast(s32) ((b.x - a.x) * scale.x);
        height := cast(s32) ((b.y - a.y) * scale.y);
        draw_asset_preview(asset, *asset.thumbnail, width, height, p, *browser.palette);
        if asset.thumbnail.color  draw_list.AddImage(draw_list, .{_TexID = cast(ImTextureID) asset.thumbnail.color}, a, b);
        return;
    }

    if asset.kind == {
        case .SOUND;    draw_waveform(draw_list, asset, a, b, -1);
        case .PALETTE;  #through;
        case .PLTT;     draw_palette_grid(draw_list, *asset.palette, a, b, asset.kind == .PLTT, asset.entry.data);
        case .COLORMAP; draw_colormap(draw_list, *asset.colormap, *browser.palette.palette, a, b, 64);
        case .FONT;     draw_lfd_font_sample(draw_list, *asset.lfd_font, a, b);
    }
}

draw_kind_label :: (asset: *Asset, draw_list: *ImDrawList, a: ImVec2, b: ImVec2) {
    ext := path_extension(asset.entry.name);
    size := ImGui.CalcTextSize(temp_c_string(ext));
    center := ImVec2.{(a.x + b.x - size.x) * 0.5, (a.y + b.y - size.y) * 0.5};
    color: u32 = 0xFFA0A0A0;
    if asset.kind == .MUSIC  color = 0xFF80D0FF;
    if asset.kind == .FILM   color = 0xFF80FFA0;
    draw_list.AddText(draw_list, center, color, ext);
}

// Evicts what hasn't been on screen for a while, a few at a time.
evict_assets :: () {
    AGE :: 600;
    evicted := 0;
    for * browser.assets {
        if !it.loaded || it.pinned || browser.frame - it.last_used < AGE continue;
        unload_asset(it);
        evicted += 1;
        if evicted >= 16 break;
    }
}

#import "Basic";
#import "File_Utilities";
#import "Sort";
#import "String";
#import "engine/dfImGui";
#import "engine/vendor/ImGui";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/dfRender";
