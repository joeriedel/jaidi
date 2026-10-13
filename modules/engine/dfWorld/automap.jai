// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The map (DARK.EXE 0x1bf35-0x1d5f0): the level from above, one layer at a time, as lines in
// palette indices. It shows what the player has seen (visibility.jai marks it): the walls
// of seen sectors, colored by their map flags and what's on either side, and the player as
// an arrow. The PDA draws it into its own picture; the Tab map draws it over the view, as
// the original's lines on its 320x200 screen, or in Enhanced Mode as the same lines at the
// window's resolution.
//
// Its state is the original's globals: the scale and the centering outlive the level, as
// nothing resets them.

Automap_Message :: enum s32 {
    CENTER          :: 1;   // On the player's eye, at the player's layer.
    PAN_UP          :: 2;
    PAN_DOWN        :: 3;
    PAN_LEFT        :: 4;
    PAN_RIGHT       :: 5;
    ZOOM_IN         :: 6;
    ZOOM_OUT        :: 7;
    LAYER_UP        :: 8;
    LAYER_DOWN      :: 9;
    AUTO_CENTER_ON  :: 10;
    AUTO_CENTER_OFF :: 11;
    ALL_LAYERS      :: 12;  // Every layer at once, or back to one.
    REVEAL          :: 13;  // The cheat's three modes: what's seen, everything, everything in its own color.
    TELEPORT        :: 14;  // The player to where the map looks (LANTFH).
}

// The message handler (0x1c2b3). In the PDA panning and zooming go in steps; in a level they
// go by the frame's time, faster running and slower walking.
world_send_automap_message :: (message: Automap_Message) {
    m := *automap;
    p := *world.player;
    if message == {
        case .CENTER;
            if world.loaded && p.sector >= 0  m.layer = world.level.sectors[p.sector].layer;
            m.center_x, m.target_x = p.position.x, p.position.x;
            m.center_z, m.target_z = p.position.z, p.position.z;
        case .PAN_UP;     m.target_z += get_pan_step();
        case .PAN_DOWN;   m.target_z -= get_pan_step();
        case .PAN_LEFT;   m.target_x -= get_pan_step();
        case .PAN_RIGHT;  m.target_x += get_pan_step();
        case .ZOOM_IN;
            if m.in_pda  m.scale = cast,no_check(Fixed) (((cast(s64) m.scale) << 16) / 0xCCCC);
            else         m.scale += mul16((m.scale << p.run) >> p.slow, world.clock.dt);
            m.scale = min(m.scale, 0x200000);
        case .ZOOM_OUT;
            if m.in_pda  m.scale = mul16(m.scale, 0xCCCC);
            else         m.scale -= mul16((m.scale << p.run) >> p.slow, world.clock.dt);
            m.scale = max(m.scale, 0x666);
        case .LAYER_UP;    m.layer = min(m.layer + 1, m.max_layer);
        case .LAYER_DOWN;  m.layer = max(m.layer - 1, m.min_layer);
        case .AUTO_CENTER_ON;   m.auto_center = true;
        case .AUTO_CENTER_OFF;  m.auto_center = false;
        case .ALL_LAYERS;
            m.all_layers = !m.all_layers;
            if !m.in_pda  send_message(ifx m.all_layers then MSG_MAP_ALL_LAYERS else MSG_MAP_ONE_LAYER);
        case .REVEAL;
            m.reveal = (m.reveal + 1) % 3;
        case .TELEPORT;
            teleport_to_automap();
    }
}

// Tab (0x120b2): the map over the view, on the player, following it; or with Alt, while the
// map is up, every layer at once.
world_toggle_automap :: (alt: bool) {
    m := *automap;
    if alt {
        if m.on  world_send_automap_message(.ALL_LAYERS);
        return;
    }
    m.on = !m.on;
    if !m.on return;
    world_send_automap_message(.AUTO_CENTER_ON);
    world_send_automap_message(.CENTER);
    m.locked = true;
}

// [ and ] while the map is up: a layer down or up, the layer told on the HUD.
world_change_automap_layer :: (up: bool) {
    if !automap.on return;
    world_send_automap_message(ifx up then Automap_Message.LAYER_UP else .LAYER_DOWN);
    send_message(min(MSG_MAP_LAYER + automap.layer, MSG_MAP_LAYER_LAST));
}

world_is_automap_on :: () -> bool { return automap.on; }

// Where the map is: its scale, layer, whether it follows the player, where it looks.
Automap_View :: struct {
    scale: Fixed;
    layer: s32;
    auto_center: bool;
    x, z: Fixed;
}

world_get_automap :: () -> Automap_View {
    m := *automap;
    return .{m.scale, m.layer, m.auto_center, m.target_x, m.target_z};
}

// The map as the PDA shows it (0x1bff7): into a picture of its own, black (79 in the menu's
// palette), with the layer's number in MAP-NUMS.FNT.
world_draw_automap_for_pda :: (pixels: [] u8, width: s32, height: s32) {
    if !world.loaded return;
    m := *automap;
    m.in_pda = true;
    b := Map_Bitmap.{pixels = pixels, width = width, height = height};
    for * b.pixels  it.* = PDA_MAP_BACKGROUND;
    m.screen_x, m.screen_z = width / 2, height / 2;
    draw_map(*b);

    text := tprint("%", m.layer);
    if text[0] == #char "-"  text[0] = #char ":";     // The font's minus.
    font := *automap_assets.numbers;
    pen := 261 - get_font_text_width(font, text) / 2;
    for cast([] u8) text {
        if it < font.first || it - font.first >= font.glyphs.count continue;
        glyph := *font.glyphs[it - font.first];
        draw_glyph(*b, glyph, pen, 115);
        pen += glyph.width + font.spacing;
    }
}

#scope_module

// The sector under where the map looks; with one layer shown and that sector on another, the
// first one on the layer within 200 above or below its floor, looking 10 further each way at
// a time. The player is put on its floor. Not found, the original writes "Sector Not Found"
// into a message slot it never shows.
teleport_to_automap :: () {
    m := *automap;
    level := *world.level;
    x, z := m.target_x, m.target_z;
    sector := level_find_sector_at_xz(level, x, z);
    if !m.all_layers && sector >= 0 && level.sectors[sector].layer != m.layer {
        floor := level.sectors[sector].floor.altitude;
        on_layer :: (level: *Level, s: s32, layer: s32) -> bool { return s >= 0 && level.sectors[s].layer == layer; }
        distance: Fixed = 10 * FIXED_ONE;
        while true {
            if distance > 200 * FIXED_ONE { sector = -1; break; }
            sector = level_find_sector(level, .{x, floor + distance, z});
            if on_layer(level, sector, m.layer) break;
            sector = level_find_sector(level, .{x, floor - distance, z});
            if on_layer(level, sector, m.layer) break;
            distance += 10 * FIXED_ONE;
        }
    }
    if sector < 0 return;
    p := *world.player;
    change_player_sector(p, sector);
    p.position.x, p.position.z = x, z;
    p.position.y = level.sectors[sector].floor.altitude;
    p.y = p.position.y;
}

automap: struct {
    on: bool;                       // The Tab map is up (0xe4977).
    locked := true;                 // Not scrolled by the arrows (0xe497b).
    scale: Fixed = 0xC000;          // Pixels a unit (0xe5640).
    reveal: s32;                    // 0xe5648
    all_layers: bool;               // 0xe564c
    auto_center := true;            // 0xe5650
    in_pda: bool;                   // 0xe5654: what the map is drawn for, until the next Tab draw.
    layer: s32;                     // 0xfb4b4
    min_layer, max_layer: s32;      // The level's (0xfb22c, 0xfb230).
    target_x, target_z: Fixed;      // Where the map looks (0xfb4d0, 0xfb49c),
    center_x, center_z: Fixed;      // and where it's drawn around this time (0xfb4c0, 0xfb4c4).
    last_x, last_z: Fixed;          // The player's position the last time, for autocentering.
    screen_x, screen_z: s32;        // The center's pixel (0xfb4a0, 0xfb494).
    // What's on the picture, in world units around the center (0x1d093).
    left, right, near, far: Fixed;
};

automap_assets: struct {
    numbers: Font;
    image: Gpu_Image;               // The Tab map at 320x200.
    pixels: [SCREEN_WIDTH * SCREEN_HEIGHT] u8;
    lines: [..] Map_Line;           // The Tab map in Enhanced Mode.
};

// The level's layers, the map on the player's, and the layer numbers' font (0x1bf35).
load_automap :: () {
    m := *automap;
    m.on = false;
    m.min_layer, m.max_layer = 0, 0;
    for world.level.sectors {
        if it_index == 0 || it.layer < m.min_layer  m.min_layer = it.layer;
        if it_index == 0 || it.layer > m.max_layer  m.max_layer = it.layer;
    }
    p := *world.player;
    if p.sector >= 0  set_automap_layer(world.level.sectors[p.sector].layer);
    if !automap_assets.numbers.glyphs {
        data, found := gob_find("MAP-NUMS.FNT");
        if found {
            font, ok := fnt_parse(data);
            if ok  automap_assets.numbers = font;
        }
    }
}

unload_automap :: () {
    render_release_image(*automap_assets.image);
    array_free(automap_assets.lines);
    none: [..] Map_Line;
    automap_assets.lines = none;
}

// The map's held keys, each frame it's up (0x120b2): ` scrolls it, unlocking the arrows
// from the player for it and taking it off the player; = and - zoom.
update_automap :: (input: World_Input) {
    m := *automap;
    if !m.on return;
    if input.map_scroll {
        m.locked = false;
        world_send_automap_message(.AUTO_CENTER_OFF);
    } else {
        m.locked = true;
    }
    if input.map_zoom_in   world_send_automap_message(.ZOOM_IN);
    if input.map_zoom_out  world_send_automap_message(.ZOOM_OUT);
    if m.locked return;
    if input.map_up     world_send_automap_message(.PAN_UP);
    if input.map_down   world_send_automap_message(.PAN_DOWN);
    if input.map_left   world_send_automap_message(.PAN_LEFT);
    if input.map_right  world_send_automap_message(.PAN_RIGHT);
}

// The Tab map over the view (0x1bfbf), after the weapon and before the status panels, around
// the 320x200 screen's middle (159, 99). Original: drawn on that screen as the original
// does. Enhanced: each line a quad a pixel of that screen wide, at full precision, reaching
// over the whole width of a wider view.
draw_automap_overlay :: (original: bool) {
    m := *automap;
    if !m.on return;
    m.in_pda = false;
    m.screen_x, m.screen_z = 159, 99;
    a := *automap_assets;
    if original {
        for * a.pixels  it.* = 0;
        b := Map_Bitmap.{pixels = a.pixels, width = SCREEN_WIDTH, height = SCREEN_HEIGHT};
        draw_map(*b);
        mask := NewArray(a.pixels.count, bool,, temp);
        for a.pixels  mask[it_index] = it != 0;
        render_update_image(*a.image, .{SCREEN_WIDTH, SCREEN_HEIGHT, a.pixels}, mask);
        render_set_image(*a.image);
        render_add_quad(.{0, 0, 0}, .{SCREEN_WIDTH, SCREEN_HEIGHT, 0}, .{0, 0}, .{SCREEN_WIDTH, SCREEN_HEIGHT}, 31, 0,
                        render_pack_color(.TEXTURE_RAW, transparent = true));
        return;
    }
    array_reset_keeping_memory(*a.lines);
    b := Map_Bitmap.{width = SCREEN_WIDTH, height = SCREEN_HEIGHT, lines = *a.lines};
    draw_map(*b);
    render_set_image(null);
    for a.lines {
        d := Vector2.{it.x1 - it.x0, it.y1 - it.y0};
        along := Vector2.{0.5, 0};
        len := length(d);
        if len > 0.0001  along = d * (0.5 / len);
        across := Vector2.{-along.y, along.x};
        p0 := Vector2.{it.x0, it.y0} - along;
        p1 := Vector2.{it.x1, it.y1} + along;
        color := render_pack_color(.COLOR_RAW, it.color);
        corner :: (p: Vector2, color: u32) -> Render_Vertex { return .{.{p.x, p.y, 0}, .{}, 31, 0, color}; }
        render_add_triangles(.[
            corner(p0 + across, color), corner(p1 + across, color), corner(p1 - across, color),
            corner(p0 + across, color), corner(p1 - across, color), corner(p0 - across, color),
        ]);
    }
}

// The player in a sector on another layer takes the map there (0x1c26a).
set_automap_layer :: (layer: s32) {
    automap.layer = min(layer, automap.max_layer);
}

MSG_MAP_ALL_LAYERS :s32: 17;
MSG_MAP_ONE_LAYER  :s32: 18;
MSG_MAP_LAYER      :s32: 609;   // "Layer n": 609 + n, the last 618.
MSG_MAP_LAYER_LAST :s32: 618;

SCREEN_WIDTH  :: 320;
SCREEN_HEIGHT :: 200;

#scope_file

PDA_MAP_BACKGROUND :: 79;

// What the map is drawn into: palette indices, or for Enhanced Mode a list of lines in the
// screen's pixels, at full precision.
Map_Bitmap :: struct {
    pixels: [] u8;
    width, height: s32;
    lines: *[..] Map_Line;
}

Map_Line :: struct {
    x0, y0, x1, y1: float;      // Pixel centers; a point is a line of no length.
    color: u8;
}

// A pan step: 20 pixels in the PDA, 60 units a second in a level (four times that running,
// half walking).
get_pan_step :: () -> Fixed {
    m := *automap;
    if m.in_pda  return cast,no_check(Fixed) ((20 << 32) / cast(s64) m.scale);
    if m.auto_center return 0;
    p := *world.player;
    speed: Fixed = 0x3C0000;
    return mul16((speed << (p.run * 2)) >> p.slow, world.clock.dt);
}

// The map around its center (0x1c0cf): each seen sector on the layer, a mark where the map
// looks when it isn't on the player, the player.
draw_map :: (b: *Map_Bitmap) {
    m := *automap;
    p := *world.player;
    if !m.auto_center || m.in_pda {
        m.center_z = m.target_z;
    } else {
        m.target_x = p.position.x;
        m.center_z = p.position.z;
    }
    m.target_z = m.center_z;
    m.center_x = m.target_x;
    set_map_bounds(b);

    for * world.level.sectors {
        if m.all_layers || it.layer == m.layer  draw_map_sector(b, xx it_index, it);
    }
    player_layer := ifx p.sector >= 0 then world.level.sectors[p.sector].layer else m.layer;
    if !m.auto_center || m.layer != player_layer  draw_map_point(b, m.target_x, m.target_z, 6);
    draw_map_player(b, m.layer);
    // Scrolled away, the map comes back to the player once the player moves.
    if !m.auto_center {
        if p.position.x != m.last_x || p.position.z != m.last_z  m.auto_center = true;
        m.last_x, m.last_z = p.position.x, p.position.z;
    }
}

// What the picture shows, in world units from the center (0x1d093). The PDA's counts from
// 145 and 77 whatever the picture's size, where its center is a column and a row further.
set_map_bounds :: (b: *Map_Bitmap) {
    m := *automap;
    get_units :: (pixels: s32, scale: Fixed) -> Fixed { return cast,no_check(Fixed) (((cast(s64) pixels) << 32) / scale); }
    if m.in_pda {
        m.left  = get_units(-145, m.scale);
        m.right = get_units(b.width - 145, m.scale);
        m.far   = get_units(-77, -m.scale);
        m.near  = get_units(b.height - 77, -m.scale);
    } else {
        m.left  = get_units(-m.screen_x, m.scale);
        m.right = get_units(b.width - 1 - m.screen_x, m.scale);
        m.far   = get_units(-m.screen_z, -m.scale);
        m.near  = get_units(b.height - 1 - m.screen_z, -m.scale);
    }
}

// A sector's walls, if it has been seen, and with the cheat its objects (0x1c866).
draw_map_sector :: (b: *Map_Bitmap, index: s32, sector: *Sector) {
    m := *automap;
    if m.reveal == 0 && !(sector.flags[0] & SECTOR_SEEN) return;
    for * wall: sector.walls {
        if m.reveal == 0 && !wall.seen continue;
        color := get_wall_color(index, wall);
        if !color continue;
        a, b2 := sector.vertices[wall.left], sector.vertices[wall.right];
        draw_map_line(b, a.x, a.z, b2.x, b2.z, color);
    }
    if m.reveal == 0 || index >= world.sector_objects.count return;
    for walk_sector(xx index) {
        object := world.objects[it];
        if object && !(object.flags & OBJECT_HIDDEN)  draw_map_object(b, object);
    }
}

// A wall's color on the map, 0 for none (0x1c943): its map flags first, then what's on
// either side of it, a step of a quarter unit or more counting as a ledge.
get_wall_color :: (sector_index: s32, wall: *Wall) -> u8 {
    flags := wall.flags[0];
    if flags & WALL_HIDE_ON_MAP   return 0;
    if flags & WALL_LEDGE_ON_MAP  return MAP_LEDGE;
    if flags & WALL_DOOR_ON_MAP   return MAP_DOOR;
    if flags & WALL_NORMAL_ON_MAP return MAP_WALL;
    if wall.adjoin < 0 return MAP_WALL;
    if is_door_sector(sector_index) || is_door_sector(wall.adjoin)  return MAP_DOOR;
    if automap.reveal == 2 return MAP_REVEALED;
    sector, next := *world.level.sectors[sector_index], *world.level.sectors[wall.adjoin];
    if abs(sector.floor.altitude - next.floor.altitude) > 0x3FFF  return MAP_LEDGE;
    return 0;
}

MAP_WALL     :: 10;
MAP_LEDGE    :: 12;
MAP_REVEALED :: 13;
MAP_DOOR     :: 19;

// A door, or a sector an elevator moves its floor, ceiling or walls of (0x1ca4d); a rotating
// wall counts, scrolling and light don't.
is_door_sector :: (index: s32) -> bool {
    if world.level.sectors[index].flags[0] & SECTOR_DOOR return true;
    if index >= world.inf.sector_links.count return false;
    for world.inf.sector_links[index] {
        link := *world.inf.links[it];
        if !link.alive || link.type != .ELEVATOR continue;
        type := world.inf.elevators[link.target].type;
        if type == .MOVE_CEILING || type == .MOVE_FLOOR || type == .MOVE_WALL || type == .ROTATE_WALL || type == .MOVE_FC  return true;
    }
    return false;
}

// An object, with the cheat (0x1cb79): sprites as a triangle the way they face, 3D objects and
// frames as a dot or a circle their size, colored by what they are.
draw_map_object :: (b: *Map_Bitmap, object: *Object) {
    color: u8 = 19;
    if object.entity & ENTITY_PROJECTILE        color = 6;
    else if object.entity & ENTITY_CORPSE       color = 48;
    else if object.entity & ENTITY_LANDMINE     color = 1;
    else if object.flags & OBJECT_PICKUP        color = 152;
    else if object.entity & ENTITY_SCENERY      color = 21;
    x, z := object.position.x, object.position.z;
    if object.class == {
        case .SPRITE;
            draw_map_triangle(b, x, z, object.yaw, 0x20000, color);
        case .MODEL; #through;
        case .FRAME;
            if object.width == 0  draw_map_point(b, x, z, color);
            else                  draw_map_circle(b, x, z, object.width, color);
    }
}

// The player, on its own layer (0x1cf79): a line four units the way it faces, a circle its
// width when that's a pixel and a half or more, a dot.
draw_map_player :: (b: *Map_Bitmap, layer: s32) {
    p := *world.player;
    if p.sector < 0 || world.level.sectors[p.sector].layer != layer return;
    x, z := p.position.x, p.position.z;
    sine, cosine := sin_cos(p.object_yaw);
    draw_map_segment(b, x, z, x + mul16(sine, 0x40000), z + mul16(cosine, 0x40000), 8);
    if mul16(p.width, automap.scale) > 0x17FFF  draw_map_circle(b, x, z, p.width, 7);
    draw_map_point(b, x, z, 6);
}

// A triangle pointing the way the object faces (0x1cd00).
draw_map_triangle :: (b: *Map_Bitmap, x: Fixed, z: Fixed, yaw: s32, size: Fixed, color: u8) {
    s, c := sin_cos(yaw);
    x0 := x - (mul16(s, size) >> 2);
    z0 := z - (mul16(c, size) >> 2);
    tip_x, tip_z := x0 + mul16(s, size), z0 + mul16(c, size);
    s, c = sin_cos(yaw + 0xFFF);
    right_x, right_z := x0 + mul16(s, size), z0 + mul16(c, size);
    left_x, left_z := x0 - mul16(s, size), z0 - mul16(c, size);
    draw_map_segment(b, tip_x, tip_z, right_x, right_z, color);
    draw_map_segment(b, tip_x, tip_z, left_x, left_z, color);
    draw_map_segment(b, right_x, right_z, left_x, left_z, color);
}

// A point in world units on the picture (0x1d555): x to the right, z up.
project_map_point :: (x: Fixed, z: Fixed) -> s32, s32 {
    m := *automap;
    px := mul16(x - m.center_x, m.scale);
    pz := mul16(z - m.center_z, -m.scale);
    return (px >> 16) + m.screen_x, (pz >> 16) + m.screen_z;
}

// The same at full precision, at the center of the pixel it falls in.
project_map_point_exactly :: (x: Fixed, z: Fixed) -> float, float {
    m := *automap;
    scale := fixed_to_float(m.scale);
    return fixed_to_float(x - m.center_x) * scale + m.screen_x + 0.5, -fixed_to_float(z - m.center_z) * scale + m.screen_z + 0.5;
}

draw_map_point :: (b: *Map_Bitmap, x: Fixed, z: Fixed, color: u8) {
    if b.lines {
        px, pz := project_map_point_exactly(x, z);
        array_add(b.lines, .{px, pz, px, pz, color});
        return;
    }
    px, pz := project_map_point(x, z);
    plot(b, px, pz, color);
}

draw_map_circle :: (b: *Map_Bitmap, x: Fixed, z: Fixed, radius: Fixed, color: u8) {
    if b.lines {
        cx, cz := project_map_point_exactly(x, z);
        r := fixed_to_float(mul16(radius, automap.scale));
        get_point :: (cx: float, cz: float, r: float, angle: s32) -> float, float {
            s, c := sin_cos(angle);
            return cx + r * fixed_to_float(c), cz + r * fixed_to_float(s);
        }
        px, pz := get_point(cx, cz, r, 0);
        angle: s32 = 0x1C7;
        while angle < 0x4000 {
            nx, nz := get_point(cx, cz, r, angle);
            array_add(b.lines, .{px, pz, nx, nz, color});
            px, pz = nx, nz;
            angle += 0x1C7;
        }
        return;
    }
    px, pz := project_map_point(x, z);
    draw_circle(b, px, pz, mul16(radius, automap.scale), 0x1C7, color);
}

// A line between two points in world units, projected (0x1cead).
draw_map_segment :: (b: *Map_Bitmap, x0: Fixed, z0: Fixed, x1: Fixed, z1: Fixed, color: u8) {
    if b.lines {
        ax, az := project_map_point_exactly(x0, z0);
        bx, bz := project_map_point_exactly(x1, z1);
        array_add(b.lines, .{ax, az, bx, bz, color});
        return;
    }
    ax, az := project_map_point(x0, z0);
    bx, bz := project_map_point(x1, z1);
    draw_line(b, ax, az, bx, bz, color);
}

// A wall: cut to what the picture shows in world units first (0x1caee, 0x1d1bc). Lines at
// full precision are left whole, for the view to cut.
draw_map_line :: (b: *Map_Bitmap, x0: Fixed, z0: Fixed, x1: Fixed, z1: Fixed, color: u8) {
    if b.lines { draw_map_segment(b, x0, z0, x1, z1, color); return; }
    m := *automap;
    min_x, max_x := m.center_x + m.left, m.center_x + m.right;
    min_z, max_z := m.center_z + m.near, m.center_z + m.far;
    clipped, ok := clip_line(.[x0, z0, x1, z1], min_x, max_x, min_z, max_z, false);
    if ok  draw_map_segment(b, clipped[0], clipped[1], clipped[2], clipped[3], color);
}

// Cohen-Sutherland, the original's way (0x1d1bc, 0x4e124): each step moves the first end
// still outside onto the edge it's past, by the slope from the first end as it is then.
// The edges are inclusive; the picture's version tests its new ends in whole pixels.
clip_line :: (ends: [4] s32, min_x: s32, max_x: s32, min_z: s32, max_z: s32, whole_pixels: bool) -> [4] s32, bool {
    get_outcode :: (x: s32, z: s32, min_x: s32, max_x: s32, min_z: s32, max_z: s32) -> u32 {
        code: u32;
        if x < min_x       code = 0x1;
        else if x > max_x  code = 0x10;
        if z < min_z       code |= 0x1000;
        else if z > max_z  code |= 0x100;
        return code;
    }
    x0, z0, x1, z1 := ends[0], ends[1], ends[2], ends[3];
    code0 := get_outcode(x0, z0, min_x, max_x, min_z, max_z);
    code1 := get_outcode(x1, z1, min_x, max_x, min_z, max_z);
    if !code0 && !code1 return ends, true;
    if code0 & code1 return ends, false;
    vertical := x0 == x1;
    horizontal := z0 == z1;
    // The original divides by zero here when a cut leaves the ends level; here the end
    // just doesn't move.
    get_slope :: (a: s32, b: s32) -> s32 { return ifx b then div16(a, b) else 0; }
    while true {
        code := ifx code0 then code0 else code1;
        x, z: s32;
        if code & 0x1000 {
            x = ifx vertical then x0 else x0 + mul16(get_slope(x1 - x0, z1 - z0), min_z - z0);
            z = min_z;
        } else if code & 0x100 {
            x = ifx vertical then x0 else x0 + mul16(get_slope(x1 - x0, z1 - z0), max_z - z0);
            z = max_z;
        } else if code & 0x10 {
            z = ifx horizontal then z0 else z0 + mul16(get_slope(z1 - z0, x1 - x0), max_x - x0);
            x = max_x;
        } else {
            z = ifx horizontal then z0 else z0 + mul16(get_slope(z1 - z0, x1 - x0), min_x - x0);
            x = min_x;
        }
        // The picture's clip keeps the new end in 16.16 but tests it in whole pixels.
        tx, tz := x, z;
        if whole_pixels  tx, tz = (x >> 16) << 16, (z >> 16) << 16;
        if code == code0 { x0, z0 = x, z; code0 = get_outcode(tx, tz, min_x, max_x, min_z, max_z); }
        else             { x1, z1 = x, z; code1 = get_outcode(tx, tz, min_x, max_x, min_z, max_z); }
        if !code0 && !code1 return .[x0, z0, x1, z1], true;
        if code0 & code1 return ends, false;
    }
    return ends, false;
}

plot :: (b: *Map_Bitmap, x: s32, y: s32, color: u8) {
    if x < 0 || x >= b.width || y < 0 || y >= b.height return;
    b.pixels[y * b.width + x] = color;
}

// A line on the picture (0x4e000): cut to it, then stepped one pixel at a time across or
// down by whichever keeps the error smaller.
draw_line :: (b: *Map_Bitmap, x0: s32, y0: s32, x1: s32, y1: s32, color: u8) {
    // The cut works in 16.16, the picture's edges a pixel in from its size.
    clipped, ok := clip_line(.[x0 << 16, y0 << 16, x1 << 16, y1 << 16], 0, (b.width - 1) << 16, 0, (b.height - 1) << 16, true);
    if !ok return;
    ax, ay, bx, by := clipped[0] >> 16, clipped[1] >> 16, clipped[2] >> 16, clipped[3] >> 16;
    dx, dy := bx - ax, by - ay;
    step_x, step_y: s32 = 1, 1;
    if dx < 1  step_x = -1;
    if dy < 1  step_y = -1;
    if step_x < 0  dy = -dy;
    if step_y > 0  dx = -dx;
    x, y := ax, ay;
    plot(b, x, y, color);
    error: s32;
    while x != bx || y != by {
        across := dy + error;
        down := dx + error;
        if abs(across) < abs(down) { x += step_x; error = across; }
        else                       { y += step_y; error = down; }
        plot(b, x, y, color);
    }
}

// A circle of radius r (16.16) as straight pieces a step of angle apart, from angle 0 round
// to the last step short of a full turn (0x4e444), if any of it can be on the picture.
draw_circle :: (b: *Map_Bitmap, cx: s32, cy: s32, r: Fixed, step: s32, color: u8) {
    whole := (r + FIXED_HALF) >> 16;
    if cx + whole < 0 || cx - whole >= b.width || cy + whole < 0 || cy - whole >= b.height return;
    get_circle_point :: (cx: s32, cy: s32, r: Fixed, angle: s32) -> s32, s32 {
        s, c := sin_cos(angle);
        return cx + ((mul16(r, c) + FIXED_HALF) >> 16), cy + ((mul16(r, s) + FIXED_HALF) >> 16);
    }
    px, py := get_circle_point(cx, cy, r, 0);
    angle := step;
    while angle < 0x4000 {
        nx, ny := get_circle_point(cx, cy, r, angle);
        draw_line(b, px, py, nx, ny, color);
        px, py = nx, ny;
        angle += step;
    }
}

// A glyph at its top-left, index 0 see-through (0x4e584).
draw_glyph :: (b: *Map_Bitmap, glyph: *Image, x: s32, y: s32) {
    for row: 0..glyph.height-1  for col: 0..glyph.width-1 {
        v := glyph.pixels[row * glyph.width + col];
        if v  plot(b, x + col, y + row, v);
    }
}

// Each glyph's width and the spacing, a space's own width (0x4de6e).
get_font_text_width :: (font: *Font, text: string) -> s32 {
    width: s32;
    for cast([] u8) text {
        if it == #char " " { width += font.space_width; continue; }
        if it < font.first || it - font.first >= font.glyphs.count continue;
        width += font.glyphs[it - font.first].width + font.spacing;
    }
    return width;
}

#import "Math";
#import "engine/dfFixed";
