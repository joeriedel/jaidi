// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The 3D view, drawn the way the original's renderer decides what's seen: from the camera's
// sector out through the adjoins it can see, each sector drawn only inside the opening it was
// seen through (dfRender/world.jai keeps that in the stencil). A sector reached through two
// openings is drawn twice, once in each, as in the original; sectors on different layers that
// overlap in space never show through each other.
//
// In each sector: its walls (solid walls, and the parts of adjoined walls above and below
// the openings), its floor and ceiling, then each opening with the sector behind it, the
// opening's masked mid texture over that, then the sector's objects, farthest first.
//
// Floors and ceilings are drawn as planes around the camera rather than as the sector's
// polygon: inside the sector's opening a plane can only show where the sector's floor is,
// because anything nearer along the way is one of its walls, an opening to another sector or
// out of view. So sectors need no triangulation, whatever their shape or holes.
//
// The view is the original's: x right, y down, z forward, a 90-degree view across the 4:3
// screen and looking up and down by moving the horizon (a shear, the walls staying upright).
// Lighting is the original's: walls and flats by distance in the scene shader, sprites as a
// whole by their distance, 3D objects by polygon or vertex (dfRender/lighting.jai).

world_draw :: (width: s32, height: s32, options: World_Draw_Options) -> *SDL_GPUTexture {
    if !world.loaded return null;
    world_mark_seen();
    w, h := width, height;
    if options.original { w, h = 320, 200; }
    w, h = max(w, 1), max(h, 1);
    render_size_view(*world.view, w, h, world = true);

    eye, sector, yaw, pitch := world_get_camera();
    c: Camera;
    c.eye = eye;
    angle := yaw / 16384.0 * PI * 2;
    c.cos, c.sin = cos(angle), sin(angle);
    c.width, c.height = xx w, xx h;
    if options.original {
        // The original's: 160 pixels at distance 1 both ways, the 320x200 screen then shown
        // at 4:3, its pixels 1.2 times taller than wide.
        c.focal, c.aspect = 160, 1;
    } else {
        // The same picture with square pixels: 90 degrees across the 4:3 part of the view,
        // 1.2 times that up and down, more to the sides on a wider view.
        c.focal, c.aspect = h * 2.0 / 3.0, 1.2;
    }
    c.shear = tan(pitch / 16384.0 * PI * 2) * c.focal * c.aspect;

    projection := Projection.{focal = c.focal, pixel_aspect = c.aspect, near = NEAR, far = 1_000_000};
    projection.center = .{0, c.shear};
    world_count_view_frame();
    palette := world_get_palette();
    if options.palette  palette = options.palette.*;
    render_begin_view(*world.view, *palette, *world.gpu_colormap, projection);

    // The sky's place for the view's yaw and pitch, the same for every sky in the level.
    c.sky.center_x  = c.width * 0.5 + 0.5 + c.width / 320.0;    // The original's table is
                                                                // one column off.
    c.sky.inv_focal = 1 / c.focal;
    c.sky.row_scale = 200.0 / c.height;
    c.sky_yaw   = yaw / 16384.0 * to_float(world.level.parallax[0]);
    c.sky_pitch = -pitch / 16384.0 * to_float(world.level.parallax[1]);

    c.light = get_player_light();
    c.smooth = !options.original;
    if sector < 0 return world.view.color;

    window: Window;
    window.count = 4;
    window.points[0] = .{0, 0};
    window.points[1] = .{c.width, 0};
    window.points[2] = .{c.width, c.height};
    window.points[3] = .{0, c.height};
    clear_drawn_objects();
    draw_sector(*c, sector, 0, window, 0);

    // The HUD over it, in the original's 320x200, or in the 4:3 part of a wider view; the
    // panels and the message at the view's edges either way.
    screen_left, screen_right := 0.0, 320.0;
    if options.original {
        render_begin_overlay(320, 200, 0, 0, c.width, c.height);
    } else {
        width := c.height * 4 / 3;
        render_begin_overlay(320, 200, (c.width - width) / 2, 0, width, c.height);
        screen_left = -(c.width - width) / 2 * 320 / width;
        screen_right = 320 - screen_left;
    }
    weapon_lighting := get_lighting(*c, *world.level.sectors[sector]);
    draw_weapon(weapon_lighting);
    draw_mask(weapon_lighting);
    draw_automap_overlay(options.original);
    draw_hud(screen_left, screen_right);
    return world.view.color;
}


#scope_file

NEAR :: 0.05;
MAX_DEPTH :: 40;            // How deep the walk goes, as the original's.
MAX_VISITS :: 4096;         // Sectors drawn in a frame, against a walk gone wild.
PLANE_SIZE :: 4096.0;       // Half the width of the planes drawn for floors and ceilings.

Camera :: struct {
    eye: Vector3;
    cos, sin: float;
    width, height: float;
    focal, aspect: float;
    shear: float;
    sky: Sky;
    sky_yaw, sky_pitch: float;
    light: s32;                 // The player's: the headlamp, the weapon's and the level's.
    smooth: bool;               // Enhanced: objects on paths drawn between their frames.
    visits: int;
    path: [MAX_DEPTH] struct { sector, wall: s32; };    // The openings being looked through.
}

// A convex part of the screen, in pixels.
Window :: struct {
    points: [32] Vector2;
    count: int;
}

to_view :: (c: *Camera, p: Vector3) -> Vector3 {
    dx, dy, dz := p.x - c.eye.x, p.y - c.eye.y, p.z - c.eye.z;
    return .{dx * c.cos - dz * c.sin, dy, dx * c.sin + dz * c.cos};
}

project :: (c: *Camera, v: Vector3) -> Vector2 {
    return .{c.width * 0.5 + v.x * c.focal / v.z, c.height * 0.5 + c.shear + v.y * c.focal * c.aspect / v.z};
}

// The sector's light, rounded from 16.16 (16 everywhere through the goggles, 0x506a0), and a
// wall's offset as it is (16.16).
get_lighting :: (c: *Camera, sector: *Sector, light_offset: Fixed = 0) -> Lighting {
    l: Lighting;
    l.sector_ambient = clamp((sector.ambient + FIXED_HALF) >> 16, 0, 31);
    if world.player_state.goggles_on  l.sector_ambient = 16;
    l.world_ambient  = 31 - clamp(c.light, 0, 31);
    l.headlight      = c.light > 0;
    l.light_offset   = light_offset;
    return l;
}

// A texture's image now: an animated one's frame by the time, a switch's by its state.
get_texture :: (index: s32, state: s32 = 0) -> *Gpu_Image, *World_Texture {
    if index < 0 || index >= world.textures.count return null, null;
    texture := *world.textures[index];
    if !texture.frames return null, null;
    frame := 0;
    if texture.frame_rate > 0 && texture.frames.count > 1 {
        frame = cast(int) (world.time * texture.frame_rate) % texture.frames.count;
    } else if texture.frames.count > 1 {
        frame = clamp(cast(int) state, 0, texture.frames.count - 1);
    }
    return *texture.frames[frame], texture;
}

vertex :: (c: *Camera, p: Vector3, uv: Vector2, light: float, color: u32) -> Render_Vertex {
    v := to_view(c, p);
    return .{v, uv, light, v.z, color};
}

add_quad :: (corners: [4] Render_Vertex) {
    render_add_triangles(.[corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]);
}

// A vertical piece of wall from a to b (left to right, seen from its sector) between two
// heights, textured from its bottom up. u0 is the texel across at a.
Piece :: struct {
    a, b: Vector2;
    top, bottom: float;         // Altitudes, y down.
    length: float;
}

draw_piece :: (c: *Camera, piece: Piece, texture: Wall_Texture, flip: bool, transparent: bool) {
    image := get_texture(texture.texture);
    if !image return;
    if piece.bottom <= piece.top return;
    u0 := to_float(texture.offset.x);
    u1 := u0 + piece.length * 8;
    if flip { u0, u1 = image.width - u0, image.width - u1; }
    v_top := (piece.bottom - piece.top) * 8 + to_float(texture.offset.z);
    v_bottom := to_float(texture.offset.z);
    color := render_pack_color(.TEXTURE_DEPTH, transparent = transparent);
    render_set_image(image);
    add_quad(.[
        vertex(c, .{piece.a.x, piece.top, piece.a.y},    .{u0, -v_top},    0, color),
        vertex(c, .{piece.b.x, piece.top, piece.b.y},    .{u1, -v_top},    0, color),
        vertex(c, .{piece.b.x, piece.bottom, piece.b.y}, .{u1, -v_bottom}, 0, color),
        vertex(c, .{piece.a.x, piece.bottom, piece.a.y}, .{u0, -v_bottom}, 0, color),
    ]);
}

// The sky texture over a wall piece: placed by direction, not by the wall.
draw_sky_piece :: (c: *Camera, piece: Piece, flat: Flat) {
    image, _ := get_texture(flat.texture);
    if !image return;
    if piece.bottom <= piece.top return;
    set_sky(c, flat);
    render_set_image(image);
    color := render_pack_color(.SKY);
    add_quad(.[
        vertex(c, .{piece.a.x, piece.top, piece.a.y},    .{}, 0, color),
        vertex(c, .{piece.b.x, piece.top, piece.b.y},    .{}, 0, color),
        vertex(c, .{piece.b.x, piece.bottom, piece.b.y}, .{}, 0, color),
        vertex(c, .{piece.a.x, piece.bottom, piece.a.y}, .{}, 0, color),
    ]);
}

set_sky :: (c: *Camera, flat: Flat) {
    sky := c.sky;
    // At the pixel's center a row is y + 0.5; the original's rows are whole.
    sky.u = to_float(flat.offset.x) + c.sky_yaw;
    sky.v = to_float(flat.offset.z) + c.sky_pitch - 0.5 * sky.row_scale;
    render_set_sky(sky);
}

// A sign over a piece of wall, where it falls on it. Its texels count across from the
// wall's own (with the piece's offset) less the sign's offset, and up from the piece's bottom
// plus the sign's offset (without the piece's). Drawn a hair in front of the wall, which it
// would otherwise fight for depth.
draw_sign :: (c: *Camera, piece: Piece, part: Wall_Texture, sign: Wall_Texture, illuminated: bool, state: s32) {
    image, info := get_texture(sign.texture, state);
    if !image return;
    sign_u, sign_v, part_u := to_float(sign.offset.x), to_float(sign.offset.z), to_float(part.offset.x);
    d0 := max((sign_u - part_u) / 8, 0);
    d1 := min((sign_u - part_u + image.width) / 8, piece.length);
    height := (piece.bottom - piece.top) * 8;
    r0 := max(-sign_v, 0);
    r1 := min(image.height - sign_v, height);
    if d1 <= d0 || r1 <= r0 return;

    along := (piece.b - piece.a) / piece.length;
    inward := Vector2.{along.y, -along.x} * 0.01;
    pa := piece.a + along * d0 + inward;
    pb := piece.a + along * d1 + inward;
    u0 := d0 * 8 + part_u - sign_u;
    u1 := d1 * 8 + part_u - sign_u;
    v0 := r0 + sign_v;
    v1 := r1 + sign_v;
    top    := piece.bottom - r1 / 8;
    bottom := piece.bottom - r0 / 8;
    mode := ifx illuminated then Render_Mode.TEXTURE_RAW else .TEXTURE_DEPTH;
    color := render_pack_color(mode, transparent = info.transparent);
    render_set_image(image);
    add_quad(.[
        vertex(c, .{pa.x, top, pa.y},    .{u0, -v1}, 0, color),
        vertex(c, .{pb.x, top, pb.y},    .{u1, -v1}, 0, color),
        vertex(c, .{pb.x, bottom, pb.y}, .{u1, -v0}, 0, color),
        vertex(c, .{pa.x, bottom, pa.y}, .{u0, -v0}, 0, color),
    ]);
}

// A floor or ceiling as a plane around the camera, textured in world x/z the original's way
// (8 texels a unit, u against x), or as sky.
draw_flat :: (c: *Camera, flat: Flat, sky: bool) {
    image, _ := get_texture(flat.texture);
    if !image return;
    render_set_image(image);
    y := to_float(flat.altitude);
    corners: [4] Render_Vertex;
    OFFSETS :: Vector2.[.{-1, -1}, .{1, -1}, .{1, 1}, .{-1, 1}];
    if sky {
        set_sky(c, flat);
        color := render_pack_color(.SKY);
        for OFFSETS {
            p := Vector3.{c.eye.x + it.x * PLANE_SIZE, y, c.eye.z + it.y * PLANE_SIZE};
            corners[it_index] = vertex(c, p, .{}, 0, color);
        }
    } else {
        color := render_pack_color(.TEXTURE_DEPTH) | FLAT_ADDRESSING;
        for OFFSETS {
            p := Vector3.{c.eye.x + it.x * PLANE_SIZE, y, c.eye.z + it.y * PLANE_SIZE};
            uv := Vector2.{(to_float(flat.offset.x) - p.x) * 8, (p.z - to_float(flat.offset.z)) * 8};
            corners[it_index] = vertex(c, p, uv, 0, color);
        }
    }
    add_quad(corners);
}

FLAT_ADDRESSING :: 0x2000;     // scene.frag.hlsl's FLAT_BIT.

// Walls face into their sector, which lies to the right going from left to right vertex.
is_facing :: (c: *Camera, a: Vector2, b: Vector2) -> bool {
    d := b - a;
    return (c.eye.x - a.x) * d.y - (c.eye.z - a.y) * d.x > 0;
}

// min_z: the nearer depth of the opening the sector is seen through. Walls wholly nearer
// than that are on the camera's side of the opening, so can't be seen through it, as the
// original's walk has it; otherwise a sector inside another (a notch open on three sides)
// would be seen through, into, and through again.
draw_sector :: (c: *Camera, sector_index: s32, level: s32, window: Window, min_z: float) {
    c.visits += 1;
    sector := *world.level.sectors[sector_index];
    exterior := (sector.flags[0] & SECTOR_EXTERIOR) != 0;
    pit := (sector.flags[0] & SECTOR_PIT) != 0;
    render_set_world_draw(.GEOMETRY, xx level);

    // The columns the window spans: walls outside them can't be seen through it, as the
    // original clips walls to its window's columns.
    left, right := FLOAT32_MAX, -FLOAT32_MAX;
    for 0..window.count-1 { left = min(left, window.points[it].x); right = max(right, window.points[it].x); }

    for * wall: sector.walls {
        a, b := to_vector(sector.vertices[wall.left]), to_vector(sector.vertices[wall.right]);
        if !is_facing(c, a, b) || !is_in_columns(c, a, b, left, right) || is_nearer(c, a, b, min_z) continue;
        render_set_lighting(get_lighting(c, sector, wall.light));
        piece := Piece.{a = a, b = b, length = length(b - a)};
        if piece.length <= 0 continue;
        flip := (wall.flags[0] & WALL_FLIP) != 0;
        illuminated := (wall.flags[0] & WALL_ILLUMINATED_SIGN) != 0;
        switch_state := ifx wall.sign.texture >= 0 then get_switch_frame(sector_index, xx (wall - sector.walls.data)) else 0;
        if wall.adjoin < 0 {
            piece.top, piece.bottom = to_float(sector.ceiling.altitude), to_float(sector.floor.altitude);
            draw_piece(c, piece, wall.mid, flip, false);
            if wall.sign.texture >= 0  draw_sign(c, piece, wall.mid, wall.sign, illuminated, switch_state);
            continue;
        }
        next := *world.level.sectors[wall.adjoin];
        has_top := sector.ceiling.altitude < next.ceiling.altitude;
        has_bottom := sector.floor.altitude > next.floor.altitude;
        if has_top {
            top := piece;
            top.top, top.bottom = to_float(sector.ceiling.altitude), to_float(next.ceiling.altitude);
            if exterior && (next.flags[0] & SECTOR_EXTERIOR_ADJ) {
                draw_sky_piece(c, top, sector.ceiling);
            } else {
                draw_piece(c, top, wall.top, flip, false);
                if wall.sign.texture >= 0 && !has_bottom  draw_sign(c, top, wall.top, wall.sign, illuminated, switch_state);
            }
        }
        if has_bottom {
            bottom := piece;
            bottom.top, bottom.bottom = to_float(next.floor.altitude), to_float(sector.floor.altitude);
            if pit && (next.flags[0] & SECTOR_PIT_ADJ) {
                draw_sky_piece(c, bottom, sector.floor);
            } else {
                draw_piece(c, bottom, wall.bottom, flip, false);
                if wall.sign.texture >= 0  draw_sign(c, bottom, wall.bottom, wall.sign, illuminated, switch_state);
            }
        }
    }

    // A plane is seen only from its side.
    render_set_lighting(get_lighting(c, sector));
    if c.eye.y > to_float(sector.ceiling.altitude)  draw_flat(c, sector.ceiling, exterior);
    if c.eye.y < to_float(sector.floor.altitude)    draw_flat(c, sector.floor, pit);

    for * wall, wall_index: sector.walls {
        if wall.adjoin < 0 continue;
        // Not back through an opening the walk is already looking through, as the
        // original marks them.
        on_path := false;
        for 0..level-1  if c.path[it].sector == sector_index && c.path[it].wall == wall_index  on_path = true;
        if on_path continue;
        a, b := to_vector(sector.vertices[wall.left]), to_vector(sector.vertices[wall.right]);
        if !is_facing(c, a, b) || c.visits >= MAX_VISITS || level + 1 >= MAX_DEPTH continue;
        next := *world.level.sectors[wall.adjoin];
        top := to_float(max(sector.ceiling.altitude, next.ceiling.altitude));
        bottom := to_float(min(sector.floor.altitude, next.floor.altitude));
        if bottom <= top continue;
        quad := Vector3.[.{a.x, top, a.y}, .{b.x, top, b.y}, .{b.x, bottom, b.y}, .{a.x, bottom, a.y}];
        // With the camera in the opening, both its ends can be nearer than the near plane,
        // and the tests by columns and depth would wrongly drop it.
        if !is_in_opening(c, quad) && (!is_in_columns(c, a, b, left, right) || is_nearer(c, a, b, min_z)) continue;

        inner, visible, close := get_portal_window(c, quad, window);
        if !visible continue;

        // The opening's polygon, or when the camera is in its plane (and would see it
        // clipped away by the near plane) the part of the window beyond the plane, just
        // past the near plane.
        opening: [..] Render_Vertex;
        opening.allocator = temp;
        if close {
            z := NEAR * 1.5;
            corners: [32] Render_Vertex;
            for 0..inner.count-1  corners[it] = .{unproject(c, inner.points[it], z), .{}, 0, z, 0};
            for 1..inner.count-2  array_add(*opening, corners[0], corners[it], corners[it + 1]);
        } else {
            corners: [4] Render_Vertex;
            for quad  corners[it_index] = vertex(c, it, .{}, 0, 0);
            array_add(*opening, corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]);
        }
        next_min_z := min(to_view(c, quad[0]).z, to_view(c, quad[1]).z);
        render_set_world_draw(.PORTAL_MARK, xx level);
        render_add_triangles(opening);
        render_set_world_draw(.PORTAL_CLEAR, xx (level + 1));
        render_add_triangles(opening);
        c.path[level] = .{sector_index, xx wall_index};
        draw_sector(c, wall.adjoin, level + 1, inner, next_min_z);
        render_set_world_draw(.PORTAL_RESTORE, xx (level + 1));
        render_add_triangles(opening);
        render_set_world_draw(.GEOMETRY, xx level);

        if wall.flags[0] & WALL_MASKED {
            render_set_lighting(get_lighting(c, sector, wall.light));
            piece := Piece.{a = a, b = b, top = top, bottom = bottom, length = length(b - a)};
            draw_piece(c, piece, wall.mid, (wall.flags[0] & WALL_FLIP) != 0, true);
        }
    }

    draw_objects(c, sector_index, level);
}

// Both ends nearer than min_z.
is_nearer :: (c: *Camera, a: Vector2, b: Vector2, min_z: float) -> bool {
    return to_view(c, .{a.x, 0, a.y}).z < min_z && to_view(c, .{b.x, 0, b.y}).z < min_z;
}

// A point on the screen at view depth z.
unproject :: (c: *Camera, p: Vector2, z: float) -> Vector3 {
    return .{(p.x - c.width * 0.5) * z / c.focal, (p.y - c.height * 0.5 - c.shear) * z / (c.focal * c.aspect), z};
}

// Whether the wall from a to b, clipped to the near plane, reaches into the columns from left
// to right.
is_in_columns :: (c: *Camera, a: Vector2, b: Vector2, left: float, right: float) -> bool {
    pa := to_view(c, .{a.x, 0, a.y});
    pb := to_view(c, .{b.x, 0, b.y});
    if pa.z < NEAR && pb.z < NEAR return false;
    if pa.z < NEAR  pa = pa + (pb - pa) * ((NEAR - pa.z) / (pb.z - pa.z));
    if pb.z < NEAR  pb = pb + (pa - pb) * ((NEAR - pb.z) / (pa.z - pb.z));
    xa := c.width * 0.5 + pa.x * c.focal / pa.z;
    xb := c.width * 0.5 + pb.x * c.focal / pb.z;
    return max(xa, xb) >= left - 1 && min(xa, xb) <= right + 1;
}

// The camera is within the near plane of the opening and inside it.
is_in_opening :: (c: *Camera, quad: [4] Vector3) -> bool {
    a := Vector2.{quad[0].x, quad[0].z};
    b := Vector2.{quad[1].x, quad[1].z};
    d := b - a;
    len := length(d);
    if len <= 0 return false;
    distance := ((c.eye.x - a.x) * d.y - (c.eye.z - a.y) * d.x) / len;
    along := ((c.eye.x - a.x) * d.x + (c.eye.z - a.y) * d.y) / len;
    return distance < NEAR * 2 && along >= 0 && along <= len && c.eye.y >= quad[0].y && c.eye.y <= quad[2].y;
}

// The part of the window the opening shows, and whether there's any. close: the camera is
// in the opening (is_in_opening), so it shows what's beyond its plane.
get_portal_window :: (c: *Camera, quad: [4] Vector3, window: Window) -> Window, bool, bool {
    result: Window;
    a := Vector2.{quad[0].x, quad[0].z};
    b := Vector2.{quad[1].x, quad[1].z};
    d := b - a;
    len := length(d);
    if len <= 0 return result, false, false;
    if is_in_opening(c, quad) {
        // The camera is in the opening, within the near plane of it: what it sees beyond
        // the opening's plane, it sees through the opening. A pixel's ray reaches past the
        // plane when it heads against the plane's normal (toward the camera's side); in
        // view space that's a vertical line on the screen.
        inward := Vector2.{d.y, -d.x} / len;
        nx := inward.x * c.cos - inward.y * c.sin;
        nz := inward.x * c.sin + inward.y * c.cos;
        // n . ((x - center) / focal, *, 1) < 0
        result = clip_half_plane(window, nx / c.focal, nz - nx * c.width * 0.5 / c.focal);
        return result, result.count >= 3, true;
    }

    // Clip the opening to the near plane in view space, then project it and cut it down to
    // the window.
    view: [12] Vector3;
    count := 0;
    for i: 0..3 {
        p := to_view(c, quad[i]);
        q := to_view(c, quad[(i + 1) % 4]);
        if p.z >= NEAR { view[count] = p; count += 1; }
        if (p.z >= NEAR) != (q.z >= NEAR) {
            t := (NEAR - p.z) / (q.z - p.z);
            view[count] = p + (q - p) * t;
            count += 1;
        }
    }
    if count < 3 return result, false, false;
    result.count = count;
    for 0..count-1  result.points[it] = project(c, view[it]);
    for i: 0..window.count-1 {
        result = clip_window(result, window.points[i], window.points[(i + 1) % window.count], window);
        if result.count < 3 return result, false, false;
    }
    area: float;
    for i: 0..result.count-1 {
        p, q := result.points[i], result.points[(i + 1) % result.count];
        area += p.x * q.y - q.x * p.y;
    }
    return result, abs(area) > 0.01, false;
}

// Keeps the part of poly where k * x + m < 0.
clip_half_plane :: (poly: Window, k: float, m: float) -> Window {
    result: Window;
    for i: 0..poly.count-1 {
        a, b := poly.points[i], poly.points[(i + 1) % poly.count];
        da := -(k * a.x + m);
        db := -(k * b.x + m);
        if da >= 0 && result.count < result.points.count { result.points[result.count] = a; result.count += 1; }
        if (da >= 0) != (db >= 0) && result.count < result.points.count {
            t := da / (da - db);
            result.points[result.count] = a + (b - a) * t;
            result.count += 1;
        }
    }
    return result;
}

// Keeps the part of poly on the window's side of the edge from p to q.
clip_window :: (poly: Window, p: Vector2, q: Vector2, window: Window) -> Window {
    // Which side is inside: the side the window's centroid is on.
    centroid: Vector2;
    for 0..window.count-1  centroid += window.points[it];
    centroid /= cast(float) window.count;
    edge := q - p;
    side :: (e: Vector2, p: Vector2, x: Vector2) -> float { return e.x * (x.y - p.y) - e.y * (x.x - p.x); }
    sign := ifx side(edge, p, centroid) >= 0 then 1.0 else -1.0;

    result: Window;
    for i: 0..poly.count-1 {
        a, b := poly.points[i], poly.points[(i + 1) % poly.count];
        da := side(edge, p, a) * sign;
        db := side(edge, p, b) * sign;
        if da >= 0 && result.count < result.points.count { result.points[result.count] = a; result.count += 1; }
        if (da >= 0) != (db >= 0) && result.count < result.points.count {
            t := da / (da - db);
            result.points[result.count] = a + (b - a) * t;
            result.count += 1;
        }
    }
    return result;
}

// Objects ----------------------------------------------------------------------------------

Object_Draw :: struct {
    object: s32;
    z: float;
}

draw_objects :: (c: *Camera, sector_index: s32, level: s32) {
    count := count_sector_objects(sector_index);
    if !count return;
    sector := *world.level.sectors[sector_index];
    lighting := get_lighting(c, sector);
    render_set_lighting(lighting);
    render_set_world_draw(.GEOMETRY, xx level);

    order := NewArray(count, Object_Draw,, temp);
    for walk_sector(sector_index)  order[it_index] = .{it, to_view(c, to_vector(world.objects[it].position)).z};
    quick_sort(order, (a: Object_Draw, b: Object_Draw) -> float64 { return b.z - a.z; });

    for order {
        object := world.objects[it.object];
        if object.flags & OBJECT_HIDDEN continue;
        // Enhanced only: the logic keeps the original's frames, the drawing goes between them.
        between: Object;
        if c.smooth {
            moving, position, matrix := get_vue_in_between(it.object);
            if moving {
                between = object.*;
                between.position = position;
                between.matrix = matrix;
                object = *between;
            }
        }
        if it.z >= 1  note_drawn_object(it.object);
        if object.class == {
            case .SPRITE;
                if object.data >= 0 && object.data < world.sprites.count  draw_sprite(c, object, *world.sprites[object.data], lighting, true);
            case .FRAME;
                if object.data >= 0 && object.data < world.frames.count   draw_sprite(c, object, *world.frames[object.data], lighting, false);
            case .MODEL;
                if object.data >= 0 && object.data < world.models.count   draw_model(c, object, *world.models[object.data], lighting);
        }
    }
}

// A sprite stands at its position, facing the camera, at the one depth of its position. It
// shows the object's action and frame, a WAX in the view for the camera's direction from it
// against its yaw, in 32 steps. Its size is scaled by its first action's world width and
// height, whichever action shows. A lit one is at full light.
draw_sprite :: (c: *Camera, object: *Object, art: *World_Art, lighting: Lighting, wax: bool) {
    sprite := *art.sprite;
    if !sprite.actions return;
    position := to_vector(object.position);
    v := to_view(c, position);
    if v.z < 1 return;

    action := *sprite.actions[ifx wax && object.anim < sprite.actions.count then object.anim else 0];
    if !action.views return;
    view_index := 0;
    if wax {
        // The original's 14-bit angles.
        angle := cast(s32) (atan2(c.eye.x - position.x, c.eye.z - position.z) / (PI * 2) * 16384);
        yaw := object.yaw;
        d := ((angle - yaw) >> 9) & 31;
        view_index = (31 - d) % action.views.count;
    }
    view := *action.views[view_index];
    if !view.frames return;
    frame_index: int = ifx object.frame < view.frames.count then object.frame else 0;
    frame := *view.frames[frame_index];
    if frame.cell < 0 || frame.cell >= art.images.count return;
    image := *art.images[frame.cell];

    sx := sprite.actions[0].world_width  / (65536.0 * 10);
    sy := sprite.actions[0].world_height / (65536.0 * 10);
    left := v.x + frame.insert_x * sx;
    top  := v.y + frame.insert_y * sy;
    right  := left + image.width * sx;
    bottom := top + image.height * sy;
    u0, u1 := 0.0, cast(float) image.width;
    if frame.flip  u0, u1 = u1, u0;
    // Through the goggles sprites are drawn unlit (0x4c320).
    light := ifx object.lit || world.player_state.goggles_on then LIGHT_FULL else get_light_by_depth(lighting, world.colormap.light_ramp, to_fixed(v.z));
    render_set_image(image);
    render_add_quad(.{left, top, v.z}, .{right, bottom, v.z}, .{u0, 0}, .{u1, xx image.height}, xx light, v.z,
                    render_pack_color(.TEXTURE_FLAT, transparent = true));
}

// A 3D object turned by its yaw, pitch and roll, or by the matrix its path gives it, and lit
// the original's way: the camera's three lights turn with its yaw only.
draw_model :: (c: *Camera, object: *Object, art: *World_Art, lighting: Lighting) {
    model := *art.model;
    if !model.vertices return;
    position := to_vector(object.position);
    center := to_view(c, position);
    if center.z + model.radius < NEAR return;

    // The object's matrix: from its angles, or as a path set it (vue.jai).
    m: Matrix3;
    if object.matrix_set {
        for 0..8  m.floats[it] = fixed_to_float(object.matrix[it]);
    } else {
        to_radians :: (angle: s32) -> float { return angle / 8192.0 * PI; }
        yc, ys := cos(to_radians(object.yaw)), sin(to_radians(object.yaw));
        pc, ps := cos(to_radians(object.pitch)), sin(to_radians(object.pitch));
        rc, rs := cos(to_radians(object.roll)), sin(to_radians(object.roll));
        // Roll about z, pitch about x, then yaw about y (the camera's sense: +z turns to +x).
        turn_by_angles :: (v: Vector3, yc: float, ys: float, pc: float, ps: float, rc: float, rs: float) -> Vector3 {
            r := Vector3.{v.x * rc - v.y * rs, v.x * rs + v.y * rc, v.z};
            r = .{r.x, r.y * pc - r.z * ps, r.y * ps + r.z * pc};
            return .{r.x * yc + r.z * ys, r.y, r.z * yc - r.x * ys};
        }
        for axis: 0..2 {
            e: Vector3;
            e.component[axis] = 1;
            column := turn_by_angles(e, yc, ys, pc, ps, rc, rs);
            for 0..2  m.floats[it * 3 + axis] = column.component[it];
        }
    }
    turn :: (v: Vector3, m: Matrix3) -> Vector3 {
        f := m.floats;
        return .{f[0] * v.x + f[1] * v.y + f[2] * v.z, f[3] * v.x + f[4] * v.y + f[5] * v.z, f[6] * v.x + f[7] * v.y + f[8] * v.z};
    }
    to_view_direction :: (c: *Camera, d: Vector3) -> Vector3 {
        return .{d.x * c.cos - d.z * c.sin, d.y, d.x * c.sin + d.z * c.cos};
    }

    transformed := NewArray(model.vertices.count, Vector3,, temp);
    for model.vertices  transformed[it_index] = to_view(c, position + turn(it, m));

    ramp := world.colormap.light_ramp;
    // The lights in view space: the world's directions turned by the camera's yaw.
    lights := get_camera_lights(c.cos, -c.sin);

    if model.draw_vertices {
        color: u8 = ifx model.polygons then model.polygons[0].color else 0;
        points := NewArray(transformed.count, Render_Vertex,, temp);
        for transformed  points[it_index] = .{it, .{}, 0, it.z, render_pack_color(.COLOR_RAW, color)};
        render_set_image(null);
        render_add_points(points);
        return;
    }

    intensities: [] float;
    if model.vertex_lit {
        intensities = NewArray(model.vertices.count, float,, temp);
        for model.vertex_normals {
            normal := to_view_direction(c, turn(it, m));
            i := get_vertex_intensity(lighting, ramp, *lights, to_fixed_vector(normal), to_fixed(transformed[it_index].z));
            intensities[it_index] = i / 65536.0;
        }
    }

    for * polygon: model.polygons {
        normal := to_view_direction(c, turn(polygon.normal, m));
        if dot(normal, -transformed[polygon.indices[1]]) < 0 continue;

        z_sum: float;
        for 0..polygon.count-1  z_sum += transformed[polygon.indices[it]].z;
        flat_light := cast(float) get_polygon_light(lighting, ramp, *lights, to_fixed_vector(normal), to_fixed(z_sum / polygon.count));

        textured := polygon.shading == .TEXTURE || polygon.shading == .GOURTEX || polygon.shading == .PLANE;
        image: *Gpu_Image;
        if textured && polygon.texture >= 0 && polygon.texture < art.images.count && art.images[polygon.texture].texture {
            image = *art.images[polygon.texture];
        } else {
            textured = false;
        }

        mode: Render_Mode;
        if polygon.shading == {
            case .FLAT;    mode = .FLAT;
            case .GOURAUD; mode = ifx intensities then .SHADED else .FLAT;
            case .TEXTURE; mode = .TEXTURE_DEPTH;
            case .GOURTEX; mode = ifx intensities then .TEXTURE_SHADED else .TEXTURE_DEPTH;
            case .PLANE;   mode = .TEXTURE_DEPTH;
        }
        if !textured && (mode == .TEXTURE_DEPTH || mode == .TEXTURE_FLAT)  mode = .FLAT;
        if !textured && mode == .TEXTURE_SHADED  mode = .SHADED;
        // Lit up (a shot): full light, unshaded.
        if object.lit {
            mode = ifx textured then Render_Mode.TEXTURE_FLAT else .FLAT;
            flat_light = LIGHT_FULL;
        }
        color := render_pack_color(mode, polygon.color);

        corners: [4] Render_Vertex;
        for 0..polygon.count-1 {
            index := polygon.indices[it];
            v := transformed[index];
            uv := polygon.uvs[it];
            if polygon.shading == .PLANE {
                // Projected from above in world space, like a floor (8 texels to a unit).
                w := position + turn(model.vertices[index], m);
                uv = .{w.x * 8, w.z * 8};
            }
            light := ifx (mode == .SHADED || mode == .TEXTURE_SHADED) then intensities[index] else flat_light;
            corners[it] = .{v, uv, light, v.z, color};
        }
        render_set_image(image);
        render_add_triangles(.[corners[0], corners[1], corners[2]]);
        if polygon.count == 4  render_add_triangles(.[corners[0], corners[2], corners[3]]);
    }
}

to_float :: fixed_to_float;

to_vector :: (p: Fixed2) -> Vector2 { return .{fixed_to_float(p.x), fixed_to_float(p.z)}; }
to_vector :: (p: Fixed3) -> Vector3 { return .{fixed_to_float(p.x), fixed_to_float(p.y), fixed_to_float(p.z)}; }

#import "Sort";
#import "engine/dfFixed";
