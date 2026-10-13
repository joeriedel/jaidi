// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The game's files as the asset browser and its viewers see them: what kind each is, decoding
// it and putting it on the GPU when it first shows, and drawing its preview. Previews go
// through the game renderer, so they show the original's palettes and colormap lighting.

Asset_Kind :: enum u8 {
    OTHER;
    TEXTURE;    // BM
    FRAME;      // FME
    WAX;
    MODEL;      // 3DO
    SOUND;      // VOC, VOIC
    PALETTE;    // PAL
    PLTT;
    COLORMAP;   // CMP
    DELT;
    ANIM;
    FNT;
    FONT;
    MUSIC;      // GMD, GMID
    FILM;
    TEXT;       // LEV, O, INF, GOL, MSG, LST, TXT, LVL, VUE
}

ASSET_KIND_LABELS :: string.["Other", "Texture", "Frame", "Sprite", "3D object", "Sound", "Palette", "Palette (LFD)", "Colormap", "Image (LFD)", "Animation (LFD)", "Font", "Font (LFD)", "Music", "Film (LFD)", "Text"];

get_asset_kind :: (name: string) -> Asset_Kind {
    ext := path_extension(name);
    if ext == {
        case "BM";   return .TEXTURE;
        case "FME";  return .FRAME;
        case "WAX";  return .WAX;
        case "3DO";  return .MODEL;
        case "VOC";  return .SOUND;
        case "VOIC"; return .SOUND;
        case "PAL";  return .PALETTE;
        case "PLTT"; return .PLTT;
        case "CMP";  return .COLORMAP;
        case "DELT"; return .DELT;
        case "ANIM"; return .ANIM;
        case "FNT";  return .FNT;
        case "FONT"; return .FONT;
        case "GMD";  return .MUSIC;
        case "GMID"; return .MUSIC;
        case "FILM"; return .FILM;
        case "LEV"; #through;
        case "O";   #through;
        case "INF"; #through;
        case "GOL"; #through;
        case "MSG"; #through;
        case "LST"; #through;
        case "TXT"; #through;
        case "LVL"; #through;
        case "VUE";  return .TEXT;
    }
    return .OTHER;
}

Asset :: struct {
    entry:    *Archive_Entry;
    archive:  *Archive;
    kind:     Asset_Kind;
    shadowed: bool;             // A GOB mounted later has a file of the same name.

    // Decoded on first use, freed when unused for a while.
    loaded:    bool;
    failed:    bool;
    last_used: s64;             // Frame number.
    pinned:    s32;             // Open viewers.

    texture:  Texture;
    sprite:   Sprite;
    model:    Model;
    sound:    Sound;
    palette:  Palette;          // PAL and PLTT contents; for LFD art, the palette it is shown with.
    has_own_palette: bool;      // LFD art: palette from its LFD.
    colormap: Colormap;
    anim:     Anim;             // DELT (one frame) and ANIM.
    font:     Font;
    lfd_font: Lfd_Font;
    waveform: [..] [2] u8;      // Per column of WAVEFORM_COLUMNS: lowest and highest sample.

    images:        [..] Gpu_Image;  // BM frames, sprite cells, DELT/ANIM frames, FNT glyphs.
    model_images:  [..] Gpu_Image;  // A 3DO's textures, by its texture index.
    model_sizes:   [..] [2] s32;

    thumbnail: View;
}

WAVEFORM_COLUMNS :: 256;

// What previews draw with: a level's palette and colormap.
Preview_Palette :: struct {
    name:     string;
    palette:  Palette;
    colormap: Colormap;
    gpu_colormap: Gpu_Colormap;
}

// How to show an asset.
Preview :: struct {
    time:     float64;          // Seconds, for animation.
    lit:      bool;             // Through the colormap, with lighting; otherwise as authored.
    lighting: Lighting;
    distance: float = 0;        // From the camera, in world units; 0 picks one that fits.
    yaw:      float;            // Turn of a 3D object or sprite, radians.
    pitch:    float = 0.45;     // Tip of a 3D object toward the camera, radians.
    action:   s32;              // WAX action.
    frame:    s32 = -1;         // Frame to show; -1 animates.
    floor:    bool;             // Textures: tiled on a floor running into the distance.
    fit:      float = 1;        // Set by draw_asset_preview: how much farther to stand back so
                                // what fits across fits down a wide view too.
    camera_height: float = 0;   // Floors: the eye above the floor, in world units.
}

// Loads what the asset needs to be shown. Returns false if it can't be decoded.
load_asset :: (asset: *Asset, frame: s64) -> bool {
    asset.last_used = frame;
    if asset.loaded return !asset.failed;
    asset.loaded = true;
    data := asset.entry.data;
    ok := true;

    if asset.kind == {
        case .TEXTURE;
            asset.texture, ok = bm_parse(data);
            if ok for asset.texture.frames  array_add(*asset.images, render_upload_image(it));
        case .FRAME;
            asset.sprite, ok = fme_parse(data);
            if ok for asset.sprite.cells  array_add(*asset.images, render_upload_image(it));
        case .WAX;
            asset.sprite, ok = wax_parse(data);
            if ok for asset.sprite.cells  array_add(*asset.images, render_upload_image(it));
        case .MODEL;
            asset.model, ok = model_parse(cast(string) data, get_bm_size);
            if ok load_model_textures(asset);
        case .SOUND;
            asset.sound, ok = voc_parse(data);
            if ok build_waveform(asset);
        case .PALETTE;
            asset.palette, ok = pal_parse(data);
        case .PLTT;
            ok = pltt_apply(*asset.palette, data);
        case .COLORMAP;
            asset.colormap, ok = cmp_parse(data);
        case .DELT;
            delt: Delt;
            delt, ok = delt_parse(data);
            if ok {
                array_add(*asset.anim.frames, delt);
                array_add(*asset.images, render_upload_image(delt.image, delt.opaque));
                find_lfd_palette(asset);
            }
        case .ANIM;
            asset.anim, ok = anim_parse(data);
            if ok {
                for asset.anim.frames  array_add(*asset.images, render_upload_image(it.image, it.opaque));
                find_lfd_palette(asset);
            }
        case .FNT;
            asset.font, ok = fnt_parse(data);
            if ok for asset.font.glyphs  array_add(*asset.images, render_upload_image(it));
        case .FONT;
            asset.lfd_font, ok = lfd_font_parse(data);
    }
    asset.failed = !ok;
    return ok;
}

unload_asset :: (asset: *Asset) {
    if !asset.loaded return;
    for * asset.images render_release_image(it);
    for * asset.model_images render_release_image(it);
    array_reset(*asset.images);
    array_reset(*asset.model_images);
    array_reset(*asset.model_sizes);
    array_reset(*asset.waveform);
    render_release_view(*asset.thumbnail);
    texture_free(*asset.texture);
    sprite_free(*asset.sprite);
    model_free(*asset.model);
    sound_free(*asset.sound);
    anim_free(*asset.anim);
    font_free(*asset.font);
    lfd_font_free(*asset.lfd_font);
    asset.palette = .{};
    asset.colormap = .{};
    asset.has_own_palette = false;
    asset.loaded = false;
    asset.failed = false;
}

// Assets drawn through a view: everything with pixels.
is_drawn_in_view :: (kind: Asset_Kind) -> bool {
    return kind == .TEXTURE || kind == .FRAME || kind == .WAX || kind == .MODEL || kind == .DELT || kind == .ANIM || kind == .FNT;
}

// Records the asset's preview into the view, sized in pixels.
draw_asset_preview :: (asset: *Asset, view: *View, width: s32, height: s32, preview: Preview, pal: *Preview_Palette) {
    render_size_view(view, width, height);
    palette := ifx asset.has_own_palette then *asset.palette else *pal.palette;
    p := preview;
    p.fit = view.width / cast(float) max(min(view.width, view.height), 1);
    background := Color.{24, 24, 28};

    if asset.kind == {
        case .TEXTURE;
            if !asset.images return;
            index := get_animation_frame(asset.texture.frames.count, asset.texture.frame_rate, p);
            image := *asset.images[index];
            if p.floor {
                render_begin_view(view, palette, *pal.gpu_colormap, .{}, background);
                draw_floor(image, asset.texture.transparent, p, *pal.colormap);
            } else {
                render_begin_view(view, palette, *pal.gpu_colormap, fit_projection(view, image.width, image.height), background);
                draw_image(image, 0, 0, asset.texture.transparent, p, *pal.colormap);
            }

        case .FRAME; #through;
        case .WAX;
            render_begin_view(view, palette, *pal.gpu_colormap, .{}, background);
            draw_sprite(asset, p, *pal.colormap);

        case .MODEL;
            render_begin_view(view, palette, *pal.gpu_colormap, .{}, background);
            draw_model(asset, p, *pal.colormap);

        case .DELT; #through;
        case .ANIM;
            // Frames sit at their own screen positions; fit them all, so the animation holds
            // still in the view.
            if !asset.images return;
            index := get_animation_frame(asset.anim.frames.count, 10, p);
            lo, hi := get_anim_bounds(*asset.anim);
            render_begin_view(view, palette, null, fit_projection(view, hi.x - lo.x, hi.y - lo.y), background);
            frame := *asset.anim.frames[index];
            draw_image(*asset.images[index], xx (frame.x - lo.x), xx (frame.y - lo.y), false, .{}, null);

        case .FNT;
            draw_font_sample(asset, view, palette, pal);
    }
}

// The frame an animation is on: the chosen one, or the one the clock reaches.
get_animation_frame :: (count: s64, rate: s64, p: Preview) -> s64 {
    if count <= 0 return 0;
    if p.frame >= 0 return min(cast(s64) p.frame, count - 1);
    if rate <= 0 return 0;
    return cast(s64) (p.time * rate) % count;
}

// An image's light at the preview's distance, as the original lights a sprite or a wall
// column there.
get_preview_light :: (p: Preview, colormap: *Colormap, distance: float) -> float {
    if !p.lit || !colormap return LIGHT_FULL;
    return xx get_light_by_depth(p.lighting, colormap.light_ramp, to_fixed(distance));
}

// The rectangle all of an animation's frames cover, in screen pixels.
get_anim_bounds :: (anim: *Anim) -> lo: Vector2i, hi: Vector2i {
    lo := Vector2i.{S32_MAX, S32_MAX};
    hi := Vector2i.{S32_MIN, S32_MIN};
    for anim.frames {
        if !it.image.width || !it.image.height continue;
        lo.x = min(lo.x, it.x);
        lo.y = min(lo.y, it.y);
        hi.x = max(hi.x, it.x + it.image.width);
        hi.y = max(hi.y, it.y + it.image.height);
    }
    if lo.x > hi.x return .{}, .{1, 1};
    return lo, hi;
}

Vector2i :: struct { x, y: s32; }

#scope_file

// Fits an image of this size into the view, at whole-pixel scales when it is smaller.
fit_projection :: (view: *View, width: s32, height: s32) -> Projection {
    scale := min(view.width / cast(float) max(width, 1), view.height / cast(float) max(height, 1));
    if scale >= 1  scale = floor(scale);
    p: Projection;
    p.perspective = false;
    p.scale = scale;
    p.center = .{-width * 0.5 * scale, -height * 0.5 * scale};
    return p;
}

// An image with its top-left corner at (x, y), in image pixels.
draw_image :: (image: *Gpu_Image, x: float, y: float, transparent: bool, p: Preview, colormap: *Colormap) {
    render_set_image(image);
    light := get_preview_light(p, colormap, ifx p.distance > 0 then p.distance else 10);
    mode := ifx p.lit then Render_Mode.TEXTURE_FLAT else .TEXTURE_RAW;
    render_set_lighting(ifx p.lit then p.lighting else .{});
    render_add_quad(.{x, y, 1}, .{x + image.width, y + image.height, 1}, .{0, 0}, .{xx image.width, xx image.height},
                    light, 0, render_pack_color(mode, transparent = transparent));
}

// A floor of the texture from the camera into the distance, lit per pixel by distance, the way
// the original draws floors: a texel is 1/8 of a unit, so a 64x64 flat covers 8x8 units.
draw_floor :: (image: *Gpu_Image, transparent: bool, p: Preview, colormap: *Colormap) {
    render_set_image(image);
    lighting := ifx p.lit then p.lighting else .{};
    render_set_lighting(lighting);
    mode := ifx p.lit then Render_Mode.TEXTURE_DEPTH else .TEXTURE_RAW;
    color := render_pack_color(mode, transparent = transparent);
    height := ifx p.camera_height > 0 then p.camera_height else 5.8;
    // Strips, so depth interpolates well enough across the long quad.
    STRIPS :: 32;
    FAR :: 160.0;
    for s: 0..STRIPS-1 {
        z0 := 0.5 + FAR * (cast(float) s / STRIPS) * (cast(float) s / STRIPS);
        z1 := 0.5 + FAR * (cast(float) (s + 1) / STRIPS) * (cast(float) (s + 1) / STRIPS);
        w0, w1 := z0 * 1.2, z1 * 1.2;
        v := Render_Vertex.[
            .{.{-w0, height, z0}, .{-w0 * 8, z0 * 8}, 0, z0, color},
            .{.{ w0, height, z0}, .{ w0 * 8, z0 * 8}, 0, z0, color},
            .{.{ w1, height, z1}, .{ w1 * 8, z1 * 8}, 0, z1, color},
            .{.{-w0, height, z0}, .{-w0 * 8, z0 * 8}, 0, z0, color},
            .{.{ w1, height, z1}, .{ w1 * 8, z1 * 8}, 0, z1, color},
            .{.{-w1, height, z1}, .{-w1 * 8, z1 * 8}, 0, z1, color},
        ];
        render_add_triangles(v);
    }
}

// A sprite stands with its feet at the object's position; a cell's insertion point places its
// top-left corner, in pixels a tenth of a unit wide, scaled by the action's world size.
draw_sprite :: (asset: *Asset, p: Preview, colormap: *Colormap) {
    sprite := *asset.sprite;
    if !sprite.actions return;
    action := *sprite.actions[clamp(cast(s64) p.action, 0, sprite.actions.count - 1)];
    if !action.views return;

    // The view of a turning object: 32 around, the first facing the camera.
    turn := p.yaw / (2 * PI);
    turn -= floor(turn);
    view_index := (cast(s64) floor(turn * 32 + 0.5) % 32) % action.views.count;
    view := *action.views[view_index];
    if !view.frames return;
    frame := *view.frames[get_animation_frame(view.frames.count, action.frame_rate, p)];
    if frame.cell < 0 || frame.cell >= asset.images.count return;
    image := *asset.images[frame.cell];

    sx := action.world_width  / (65536.0 * 10);
    sy := action.world_height / (65536.0 * 10);
    left   := frame.insert_x * sx;
    top    := frame.insert_y * sy;
    right  := left + image.width * sx;
    bottom := top + image.height * sy;

    // Fit the whole action, all views and frames, at a distance that shows it.
    lo, hi := get_action_extent(sprite, action);
    middle := (lo + hi) * 0.5;
    size := max(hi.x - lo.x, hi.y - lo.y, 0.5);
    distance := ifx p.distance > 0 then p.distance else size * 0.6 * p.fit;

    u0, u1 := 0.0, cast(float) image.width;
    if frame.flip  u0, u1 = u1, u0;
    light := get_preview_light(p, colormap, distance);
    render_set_image(image);
    render_set_lighting(ifx p.lit then p.lighting else .{});
    mode := ifx p.lit then Render_Mode.TEXTURE_FLAT else .TEXTURE_RAW;
    render_add_quad(.{left - middle.x, top - middle.y, distance}, .{right - middle.x, bottom - middle.y, distance},
                    .{u0, 0}, .{u1, xx image.height}, light, distance, render_pack_color(mode, transparent = true));
}

// Yaw about the vertical axis, then tip about the horizontal one, by their cosines and sines.
turn_model :: (v: Vector3, yaw_c: float, yaw_s: float, tip_c: float, tip_s: float) -> Vector3 {
    r := Vector3.{v.x * yaw_c + v.z * yaw_s, v.y, v.z * yaw_c - v.x * yaw_s};
    return .{r.x, r.y * tip_c - r.z * tip_s, r.z * tip_c + r.y * tip_s};
}

get_action_extent :: (sprite: *Sprite, action: *Wax_Action) -> Vector2, Vector2 {
    sx := action.world_width  / (65536.0 * 10);
    sy := action.world_height / (65536.0 * 10);
    lo := Vector2.{FLOAT32_MAX, FLOAT32_MAX};
    hi := Vector2.{-FLOAT32_MAX, -FLOAT32_MAX};
    for view: action.views {
        for frame: view.frames {
            if frame.cell < 0 || frame.cell >= sprite.cells.count continue;
            cell := *sprite.cells[frame.cell];
            lo.x = min(lo.x, frame.insert_x * sx);
            lo.y = min(lo.y, frame.insert_y * sy);
            hi.x = max(hi.x, (frame.insert_x + cell.width) * sx);
            hi.y = max(hi.y, (frame.insert_y + cell.height) * sy);
        }
    }
    if lo.x > hi.x return .{}, .{};
    return lo, hi;
}

// Polygons in view space, culled, lit and drawn the ways the original does each shading.
draw_model :: (asset: *Asset, p: Preview, colormap: *Colormap) {
    model := *asset.model;
    if !model.vertices return;

    // Turn about the vertical axis, centered on the bounding box, the camera a little above.
    lo := Vector3.{FLOAT32_MAX, FLOAT32_MAX, FLOAT32_MAX};
    hi := -lo;
    for model.vertices { lo = min(lo, it); hi = max(hi, it); }
    center := (lo + hi) * 0.5;
    radius := max(length(hi - lo) * 0.5, 0.25);
    distance := ifx p.distance > 0 then p.distance else radius * 1.6 * p.fit;
    c, s := cos(p.yaw), sin(p.yaw);

    // Tipped toward the camera so flat objects (elevator platforms) aren't seen edge-on. The
    // original's lights follow the camera's yaw only, so tipping the object rather than the
    // camera keeps its lighting what the game would give an object at this angle.
    tip_c, tip_s := cos(p.pitch), sin(p.pitch);

    transformed := NewArray(model.vertices.count, Vector3,, temp);
    for model.vertices {
        v := it - center;
        transformed[it_index] = turn_model(v, c, s, tip_c, tip_s) + Vector3.{0, 0, distance};
    }

    lighting := ifx p.lit then p.lighting else Lighting.{};
    ramp: [] u8;
    if colormap  ramp = colormap.light_ramp;
    lights := get_camera_lights();
    render_set_lighting(lighting);

    if model.draw_vertices {
        // The original draws every vertex as one pixel in the first polygon's color.
        color: u8 = ifx model.polygons then model.polygons[0].color else 0;
        points := NewArray(transformed.count, Render_Vertex,, temp);
        for transformed  points[it_index] = .{it, .{}, 0, it.z, render_pack_color(.COLOR_RAW, color)};
        render_set_image(null);
        render_add_points(points);
        return;
    }

    intensities: [] float;
    if model.vertex_lit && p.lit {
        intensities = NewArray(model.vertices.count, float,, temp);
        for model.vertex_normals {
            n := it;
            normal := turn_model(n, c, s, tip_c, tip_s);
            i := get_vertex_intensity(lighting, ramp, *lights, to_fixed_vector(normal), to_fixed(transformed[it_index].z));
            intensities[it_index] = i / 65536.0;
        }
    }

    for * polygon: model.polygons {
        n := polygon.normal;
        normal := turn_model(n, c, s, tip_c, tip_s);
        if dot(normal, -transformed[polygon.indices[1]]) < 0 continue;

        z_sum: float;
        for 0..polygon.count-1  z_sum += transformed[polygon.indices[it]].z;
        flat_light := cast(float) LIGHT_FULL;
        if p.lit  flat_light = xx get_polygon_light(lighting, ramp, *lights, to_fixed_vector(normal), to_fixed(z_sum / polygon.count));

        textured := polygon.shading == .TEXTURE || polygon.shading == .GOURTEX || polygon.shading == .PLANE;
        image: *Gpu_Image;
        if textured && polygon.texture >= 0 && polygon.texture < asset.model_images.count && asset.model_images[polygon.texture].texture {
            image = *asset.model_images[polygon.texture];
        } else {
            textured = false;
        }

        mode: Render_Mode;
        if !p.lit {
            mode = ifx textured then .TEXTURE_RAW else .COLOR_RAW;
        } else if polygon.shading == {
            case .FLAT;    mode = .FLAT;
            case .GOURAUD; mode = ifx intensities then .SHADED else .FLAT;
            // One light for the polygon, as FLAT (0x5f7cc); only PLANE is lit by depth.
            case .TEXTURE; mode = .TEXTURE_FLAT;
            case .GOURTEX; mode = ifx intensities then .TEXTURE_SHADED else .TEXTURE_DEPTH;
            case .PLANE;   mode = .TEXTURE_DEPTH;
        }
        if !textured && (mode == .TEXTURE_DEPTH || mode == .TEXTURE_FLAT)  mode = .FLAT;
        if !textured && mode == .TEXTURE_SHADED  mode = .SHADED;
        color := render_pack_color(mode, polygon.color);

        corners: [4] Render_Vertex;
        for 0..polygon.count-1 {
            index := polygon.indices[it];
            v := transformed[index];
            uv := polygon.uvs[it];
            if polygon.shading == .PLANE {
                // Projected from above in model space, like a floor of a sector with no offset
                // (8 texels to a unit, u against x; see draw_model).
                m := model.vertices[index];
                uv = .{-m.x * 8, m.z * 8};
            }
            light := ifx (mode == .SHADED || mode == .TEXTURE_SHADED) then intensities[index] else flat_light;
            corners[it] = .{v, uv, light, v.z, color};
        }
        render_set_image(image);
        render_add_triangles(.[corners[0], corners[1], corners[2]]);
        if polygon.count == 4  render_add_triangles(.[corners[0], corners[2], corners[3]]);
    }
}

// Every glyph, in lines about as wide as the view is shaped.
draw_font_sample :: (asset: *Asset, view: *View, palette: *Palette, pal: *Preview_Palette) {
    font := *asset.font;
    total: s32;
    for font.glyphs  total += it.width + 1;
    line_height := font.height + 1;
    // Lines of width w, total / w of them: w / (lines * line_height) ~ view aspect.
    aspect := view.width / cast(float) max(view.height, 1);
    line_width := max(cast(s32) sqrt(cast(float) total * line_height * aspect), 8);
    for font.glyphs  line_width = max(line_width, it.width);

    width, height: s32 = 0, line_height;
    x: s32;
    for font.glyphs {
        if x + it.width > line_width { x = 0; height += line_height; }
        x += it.width + 1;
        width = max(width, x);
    }
    p: Projection;
    p.perspective = false;
    scale := min(view.width / cast(float) max(width, 1), view.height / cast(float) max(height, 1));
    if scale >= 1  scale = floor(scale);
    p.scale = scale;
    p.center = .{-width * 0.5 * scale, -height * 0.5 * scale};
    render_begin_view(view, palette, null, p, .{24, 24, 28});
    x = 0;
    y: s32;
    for * asset.images {
        if x + it.width > line_width { x = 0; y += line_height; }
        draw_image(it, xx x, xx y, true, .{}, null);
        x += it.width + 1;
    }
}

load_model_textures :: (asset: *Asset) {
    for name: asset.model.textures {
        image: Gpu_Image;
        size: [2] s32;
        data, found := gob_find(ifx name then name else "DEFAULT.BM");
        if !found  data, found = gob_find("DEFAULT.BM");
        if found {
            texture, ok := bm_parse(data);
            if ok && texture.frames {
                image = render_upload_image(texture.frames[0]);
                size = .[texture.frames[0].width, texture.frames[0].height];
            }
            texture_free(*texture);
        }
        array_add(*asset.model_images, image);
        array_add(*asset.model_sizes, size);
    }
}

get_bm_size :: (name: string) -> s32, s32, bool {
    data, found := gob_find(name);
    if !found return 0, 0, false;
    texture, ok := bm_parse(data);
    defer texture_free(*texture);
    if !ok || !texture.frames return 0, 0, false;
    return texture.frames[0].width, texture.frames[0].height, true;
}

build_waveform :: (asset: *Asset) {
    samples := asset.sound.samples;
    array_resize(*asset.waveform, WAVEFORM_COLUMNS);
    for * column: asset.waveform {
        start := it_index * samples.count / WAVEFORM_COLUMNS;
        end   := max((it_index + 1) * samples.count / WAVEFORM_COLUMNS, start + 1);
        lo, hi: u8 = 255, 0;
        for i: start..min(end, samples.count)-1 {
            lo = min(lo, samples[i]);
            hi = max(hi, samples[i]);
        }
        if lo > hi  lo, hi = 128, 128;
        column.* = .[lo, hi];
    }
}

// LFD art is shown in its LFD's palette: the PLTT of the same name, or else the first one.
find_lfd_palette :: (asset: *Asset) {
    if asset.archive.kind != .LFD return;
    base := path_strip_extension(asset.entry.name);
    chosen: *Archive_Entry;
    for * asset.archive.entries {
        if path_extension(it.name) != "PLTT" continue;
        if !chosen  chosen = it;
        if path_strip_extension(it.name) == base { chosen = it; break; }
    }
    if chosen && pltt_apply(*asset.palette, chosen.data)  asset.has_own_palette = true;
}

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/df3do";
#import "engine/dfVoc";
#import "engine/dfLandru";
#import "engine/dfRender";
