// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Collision as DARK.EXE does it: a cylinder moved from one place to another, tested against
// the walls and the floors and ceilings of the sectors it reaches into (0x5b3a4, 0x5b47c),
// the wall it hits giving the direction to slide along (0x33ecc); then the path followed
// through the openings it crosses (0x5ba5c, 0x5baa4). The player moves with its own setup
// (0x337a4), other objects with move_object (0x8a590). All in 16.16.
//
// The original keeps this state in globals around 0x12c620; here it's one struct.

Collision :: struct {
    src: Fixed3;                // Where the cylinder is; its feet.
    dst: Fixed2;                // Where it goes, x and z,
    dst_y: Fixed;               // and y: the second floors and objects are met there.
    width: Fixed;
    height: Fixed;              // From the feet to the top.
    bottom: Fixed;              // The highest floor it can step onto.
    top: Fixed;                 // The lowest ceiling it fits under.
    room: Fixed;                // The least gap between floor and ceiling it fits in.
    y1: Fixed = FIXED_INFINITY;

    // What the search found: the highest floor and lowest ceiling over the sectors reached,
    // as the floor and ceiling the cylinder meets (second floors counted), as the sectors'
    // real heights, and as their collision heights (pits and skies).
    lowest_floor, highest_ceiling: Fixed;
    real_floor, real_ceiling: Fixed;
    ext_floor, ext_ceiling: Fixed;
    bot, top_found: Fixed;
    floor_sector, ceiling_sector: s32 = -1;     // Where those were found.

    // The wall or object hit: what to slide along.
    wall: *Wall;
    wall_sector: s32;
    hit_object: s32 = -1;       // OBJECT_IS_PLAYER for the player.
    mover: s32 = -1;            // The object moving, -1 for the player: the player is in the
                                // way of others.
    responds: bool;
    response_dir: Fixed2;
    response_pos: Fixed2;
    response_angle: s32;

    double_width: Fixed;
}

// Sets the collision state up for a move of the player by (move_x, move_z) and searches
// it (0x337a4). True when it's clear; false when something is hit, with the move turned to
// slide along it when there's a direction to slide in.
collide_player_move :: (c: *Collision, p: *Player, move: *Fixed2) -> clear: bool {
    c.src = p.position;
    c.width = p.width;
    c.height = p.height;
    c.bottom = p.position.y - p.step;
    c.top = p.position.y - p.height - FIXED_ONE;
    c.room = p.height + FIXED_ONE;
    c.y1 = FIXED_INFINITY;
    c.wall = null;
    c.dst = .{p.position.x + move.x, p.position.z + move.z};
    c.dst_y = p.position.y;
    c.mover = -1;
    if search_collision(c, p.sector) return true;
    if c.responds  slide_along(c, p, move);
    return false;
}

// Searches from a sector (0x5b3a4): true when the cylinder at c.dst fits, false when it
// hits a wall, an object or a floor or ceiling it can't pass.
search_collision :: (c: *Collision, sector: s32) -> bool {
    c.bot = FIXED_INFINITY;
    c.top_found = -FIXED_INFINITY;
    c.real_floor = FIXED_INFINITY;
    c.real_ceiling = -FIXED_INFINITY;
    c.ext_floor = FIXED_INFINITY;
    c.ext_ceiling = -FIXED_INFINITY;
    c.lowest_floor = FIXED_INFINITY;
    c.highest_ceiling = -FIXED_INFINITY;
    collision_frame += 1;
    c.double_width = c.width * 2;
    c.wall = null;
    c.hit_object = -1;
    c.responds = false;
    if find_collision(c, sector, false) return true;
    if c.wall {
        c.responds = true;
        c.response_dir = c.wall.direction;
        c.response_angle = c.wall.angle;
        s := *world.level.sectors[c.wall_sector];
        c.response_pos = s.vertices[c.wall.left];
    }
    return false;
}

// The floor and ceiling something with its feet at y meets in a sector (0x5b9dc): under a
// raised second floor whose top is above it, that top is its ceiling; otherwise the second
// floor (water's bottom, or a platform it's on) and the ceiling. A pit's floor and a sky
// are 100 units off.
get_floor_and_ceiling :: (sector: *Sector, y: Fixed) -> floor: Fixed, ceiling: Fixed {
    floor, ceiling: Fixed;
    second := sector.second_altitude;
    if second < 0 && sector.floor.altitude + second < y - 2 * FIXED_ONE {
        floor = sector.floor.altitude;
        ceiling = sector.floor.altitude + second;
    } else {
        floor = sector.floor.altitude + second;
        ceiling = sector.ceiling.altitude;
    }
    if sector.flags[0] & SECTOR_PIT       floor += SKY_DEPTH;
    if sector.flags[0] & SECTOR_EXTERIOR  ceiling -= SKY_DEPTH;
    return floor, ceiling;
}

// The first wall the path from (x0, z0) to (x1, z1) crosses out of a sector, nearest by the
// quick distance (0x5ba5c); null for none. Walls crossed are marked, with their mirrors,
// so a walk through openings doesn't come back.
find_path_wall :: (sector: s32, x0: Fixed, z0: Fixed, x1: Fixed, z1: Fixed) -> *Wall, s32 {
    if x1 == x0 && z1 == z0 return null, -1;
    path_frame += 1;
    path = .{x0, x1, z0, z1};
    wall, in_sector := find_next_path_wall(sector);
    return wall, in_sector;
}

// The path's next wall out of a sector it has entered (0x5baa4).
find_next_path_wall :: (sector_index: s32) -> *Wall, s32 {
    sector := *world.level.sectors[sector_index];
    found: *Wall;
    nearest := FIXED_INFINITY;
    for * wall: sector.walls {
        if wall.path_frame == path_frame continue;
        hit, x, z := intersect_path(sector, wall);
        if !hit continue;
        // A path starting on the wall, going out its front, doesn't cross it.
        if x == path.x0 && z == path.z0 {
            side := mul16(path.x1 - path.x0, wall.direction.z) - mul16(path.z1 - path.z0, wall.direction.x);
            if side >= 0 continue;
        }
        d := dist_approx(path.x0, path.z0, x, z);
        if d < nearest {
            nearest = d;
            found = wall;
            path_hit = .{x, z};
            path_hit_distance = d;
        }
    }
    if found {
        found.path_frame = path_frame;
        if found.adjoin >= 0  world.level.sectors[found.adjoin].walls[found.mirror].path_frame = path_frame;
    }
    return found, sector_index;
}

// Moves the player along its move, through the openings its path crosses (0x2a96c): only if
// every wall crossed opens and the player fits the lowest ceiling and highest floor on the
// way. Crossings send the walls' events. False when the player doesn't move.
move_player_along_path :: (p: *Player, move: Fixed2) -> bool {
    floor, ceiling := get_floor_and_ceiling(*world.level.sectors[p.sector], p.position.y);
    next := p.sector;
    wall, in_sector := find_path_wall(p.sector, p.position.x, p.position.z, p.position.x + move.x, p.position.z + move.z);
    while wall {
        next = -1;
        if wall.adjoin < 0 || (wall.flags[2] & (WALL_ALWAYS_WALK | WALL_SOLID)) == WALL_SOLID break;
        if !world.player_state.dying  on_wall_crossed(wall, in_sector);
        next = wall.adjoin;
        f, c := get_floor_and_ceiling(*world.level.sectors[next], p.position.y);
        ceiling = max(ceiling, c);
        floor = min(floor, f);
        wall, in_sector = find_next_path_wall(next);
    }
    if next < 0 || floor < p.position.y - p.step || p.position.y - p.height - FIXED_ONE < ceiling  return false;
    p.position.x += move.x;
    p.position.z += move.z;
    if next != p.sector  change_player_sector(p, next);
    return true;
}

// Calls proc for each sector the cylinder at c.dst reaches into through openings it may
// pass, from the given one, until proc returns false (0x5b85c).
for_each_sector_reached :: (c: *Collision, sector: s32, proc: (c: *Collision, sector: s32) -> bool) {
    c.double_width = c.width * 2;
    collision_frame += 1;
    visit_sectors_reached(c, sector, proc);
}

collision_frame: s32;

// Where the path last met the wall found, its quick distance from the path's start, and the
// walk's mark.
get_path_hit :: () -> Fixed, Fixed { return path_hit.x, path_hit.z; }
get_path_hit_distance :: () -> Fixed { return path_hit_distance; }
path_frame_now :: () -> s32 { return path_frame; }

OBJECT_IS_PLAYER :: -2;

// A move of an object other than the player (0x8a590), set up by the caller; the results
// are filled in.
Object_Move :: struct {
    offset: Fixed3;
    step_up, step_down: Fixed;  // How far up and down it may step.
    height: Fixed;              // Its height for fitting under ceilings.
    width: Fixed;               // 0: walls only, along the path.
    infinite_drop: bool;        // For this move only: it may go off any edge.

    wall: *Wall;                // What stopped it,
    wall_sector: s32;           // the wall's sector,
    hit_object: s32 = -1;
    responds: bool;             // There's a direction to slide along.
    response_dir, response_pos: Fixed2;
    response_angle: s32;
}

// Moves an object by m.offset (0x8a590): through the openings its path crosses where it can
// step and fits, then, with a width, the collision search from where the path ends. Hit,
// it stays where it was in x and z, with what it hit and the direction to slide along. Its
// y goes by the offset, kept between its sector's floor and ceiling. Unstopped, it crosses
// the walls' lines, sending their events. True when nothing was hit.
move_object :: (index: s32, m: *Object_Move) -> bool {
    o := world.objects[index];
    start := o.sector;
    sector := start;
    src := o.position;
    dst := Fixed3.{src.x + m.offset.x, src.y + m.offset.y, src.z + m.offset.z};
    top := src.y - m.height;
    bottom := src.y - m.step_up;
    y1 := src.y + (ifx m.infinite_drop then FIXED_INFINITY else m.step_down);
    m.infinite_drop = false;
    m.responds = false;
    hit_wall: *Wall;
    hit_wall_sector: s32 = -1;
    hit_object: s32 = -1;

    // The walls crossed, for their events: the original keeps 32 on its stack.
    crossed: [32] Crossed_Wall;
    crossed_count := 0;
    wall, in_sector := find_path_wall(sector, src.x, src.z, dst.x, dst.z);
    while wall {
        if wall.adjoin < 0 || (wall.flags[2] & WALL_SOLID) break;
        if (o.entity & ENTITY_AI_ACTOR) && (wall.flags[2] & WALL_PLAYER_ONLY) break;
        floor, ceiling := get_floor_and_ceiling(*world.level.sectors[wall.adjoin], src.y);
        if floor < bottom || y1 < floor || top < ceiling break;
        if crossed_count < crossed.count {
            crossed[crossed_count] = .{in_sector, wall};
            crossed_count += 1;
        }
        sector = wall.adjoin;
        wall, in_sector = find_next_path_wall(sector);
    }
    if wall {
        m.responds = true;
        m.response_dir = wall.direction;
        m.response_pos = world.level.sectors[in_sector].vertices[wall.left];
        m.response_angle = wall.angle;
        dst.x, dst.z = src.x, src.z;
        sector = start;
        hit_wall = wall;
        hit_wall_sector = in_sector;
    } else if m.width {
        c := *world.collision;
        c.src = src;
        c.dst = .{dst.x, dst.z};
        c.dst_y = dst.y;
        c.width = m.width;
        c.height = o.height;
        c.bottom = bottom;
        c.top = top;
        c.room = m.height;
        c.y1 = y1;
        c.mover = index;
        found := search_collision(c, sector);
        c.mover = -1;
        if !found {
            hit_wall = c.wall;
            hit_wall_sector = c.wall_sector;
            hit_object = c.hit_object;
            dst.x, dst.z = src.x, src.z;
            m.responds = c.responds;
            m.response_dir = c.response_dir;
            m.response_pos = c.response_pos;
            m.response_angle = c.response_angle;
            sector = start;
        }
    }
    if sector != start  change_object_sector(index, sector);
    o.position.x = dst.x;
    o.position.z = dst.z;
    floor, ceiling := get_floor_and_ceiling(*world.level.sectors[o.sector], src.y);
    if ceiling < dst.y - m.height {
        if floor <= dst.y  dst.y = floor;
    } else {
        dst.y = ceiling + m.height;
    }
    o.position.y = dst.y;
    m.wall = hit_wall;
    m.wall_sector = hit_wall_sector;
    m.hit_object = hit_object;
    if hit_wall || hit_object != -1 return false;

    // The lines crossed, last first. Each sends its front event and its mirror's back one,
    // then the mirror is sent the back event again, which sends the wall itself the enter
    // event: the original does it so.
    for < i: 0..crossed_count-1 {
        c := crossed[i];
        send_wall_crossed_by(o.entity, c.sector, c.wall, EVENT_CROSS_FRONT);
        if c.wall.adjoin >= 0 && c.wall.mirror >= 0 {
            mirror := *world.level.sectors[c.wall.adjoin].walls[c.wall.mirror];
            send_wall_crossed_by(o.entity, c.wall.adjoin, mirror, EVENT_CROSS_BACK);
        }
    }
    return true;
}

// What's left of a move along the direction slid along (0x25c00).
slide_offset :: (dir: Fixed2, offset: *Fixed3) {
    along := mul16(offset.x, dir.x) + mul16(offset.z, dir.z);
    offset.x = mul16(along, dir.x);
    offset.z = mul16(along, dir.z);
}

// Whether a straight line from one point to another stays inside the level (0x5abdc): it
// goes through openings only, under their ceilings and over their floors where it crosses
// them, to the target's sector. Walls with any of wall_flags in their third word stop it.
// sight_hit_wall tells whether a wall with nothing behind it stopped it.
can_line_reach :: (from_sector: s32, to_sector: s32, from: Fixed3, to: Fixed3, wall_flags: u32 = 0) -> bool {
    sight_hit_wall = false;
    distance := dist_approx(from.x, from.z, to.x, to.z);
    dy := to.y - from.y;
    sector := from_sector;
    wall: *Wall;
    if to.x != from.x || to.z != from.z {
        path_frame += 1;
        path = .{from.x, to.x, from.z, to.z};
        wall, sector = find_next_path_wall(sector);
    }
    while wall {
        if wall.adjoin < 0 {
            sight_hit_wall = true;
            return false;
        }
        if wall.flags[2] & wall_flags return false;
        y := from.y + mul16(path_hit_distance, div16(dy, distance));
        here := *world.level.sectors[sector];
        next := *world.level.sectors[wall.adjoin];
        if y < here.ceiling.altitude || y < next.ceiling.altitude return false;
        if here.floor.altitude < y || next.floor.altitude < y return false;
        wall, sector = find_next_path_wall(wall.adjoin);
    }
    return sector == to_sector;
}

sight_hit_wall: bool;

#scope_file

path_hit: Fixed2;
path_hit_distance: Fixed;

Crossed_Wall :: struct {
    sector: s32;
    wall: *Wall;
}

// The path being followed: x0, x1, z0, z1, in the original's order.
Path :: struct { x0, x1, z0, z1: Fixed; }
path: Path;
path_frame: s32;

// The original's feature search (0x5b47c): takes in the sector's heights, then unless told
// to ignore them checks the cylinder fits, then objects, then each wall it touches, going
// on into the sectors behind walls it may pass.
find_collision :: (c: *Collision, sector_index: s32, ignore: bool) -> bool {
    sector := *world.level.sectors[sector_index];
    real_floor := sector.floor.altitude;
    real_ceiling := sector.ceiling.altitude;
    ext_floor := sector.col_floor;
    ext_ceiling := sector.col_ceiling;
    floor, ceiling: Fixed;
    if sector.second_altitude < 0 && sector.col_second < c.dst_y {
        floor = ext_floor;
        ceiling = real_floor + sector.second_altitude;
    } else {
        floor = sector.col_second;
        ceiling = sector.col_second_ceiling;
    }
    c.real_floor = min(c.real_floor, real_floor);
    c.real_ceiling = max(c.real_ceiling, real_ceiling);
    c.ext_floor = min(c.ext_floor, ext_floor);
    c.ext_ceiling = max(c.ext_ceiling, ext_ceiling);
    c.lowest_floor = min(c.lowest_floor, floor);
    c.highest_ceiling = max(c.highest_ceiling, ceiling);
    if c.top_found < c.highest_ceiling {
        c.top_found = c.highest_ceiling;
        c.ceiling_sector = sector_index;
    }
    if c.lowest_floor < c.bot {
        c.bot = c.lowest_floor;
        c.floor_sector = sector_index;
    }
    if !ignore {
        if c.bot < c.bottom return false;
        if c.top < c.top_found return false;
        gap := c.bot - c.top_found;
        if gap < 0  gap = -gap;
        if gap < c.room return false;
        if c.y1 < floor return false;
    }
    if find_object_collision(c, sector_index) return false;

    sector.collision_frame = collision_frame;
    for * wall: sector.walls {
        v0 := sector.vertices[wall.left];
        dir := wall.direction;
        can_pass := wall.adjoin >= 0 && (wall.flags[2] & (WALL_ALWAYS_WALK | WALL_SOLID)) != WALL_SOLID;
        distance := mul16(c.dst.x - v0.x, dir.z) - mul16(c.dst.z - v0.z, dir.x);
        if distance < 0  distance = -distance;
        if distance > c.width continue;
        // Along the wall: on it, or within the width past either end, compared unsigned.
        u := cast,no_check(u32) (mul16(c.dst.z - v0.z, dir.z) + mul16(c.dst.x - v0.x, dir.x));
        length := cast,no_check(u32) wall.length;
        if !(u <= length || u + cast,no_check(u32) c.width <= length + cast,no_check(u32) c.double_width) continue;

        side_test := true;
        next: *Sector;
        if can_pass {
            next = *world.level.sectors[wall.adjoin];
            // Coming down onto a second floor from above it: no need to face the wall.
            second := next.col_second;
            if !(second < c.src.y || c.y1 < second || c.top <= next.col_second_ceiling)  side_test = false;
        }
        if side_test {
            side := mul16(c.src.x - v0.x, dir.z) - mul16(c.src.z - v0.z, dir.x);
            if side < 0 continue;       // Starting behind the wall.
            along := mul16(c.dst.x - c.src.x, dir.z);
            across := mul16(c.dst.z - c.src.z, dir.x);
            if along != across && along - across >= 0 continue;     // Moving away from it.
        }
        if !can_pass {
            c.wall = wall;
            c.wall_sector = sector_index;
            return false;
        }
        next_floor := ifx next.second_altitude < 0 then next.floor.altitude else next.col_second;
        always_walk := (wall.flags[2] & (WALL_ALWAYS_WALK | WALL_SOLID)) == WALL_ALWAYS_WALK;
        if !always_walk {
            if next_floor < c.bottom || c.top < next.col_second_ceiling {
                c.wall = wall;
                c.wall_sector = sector_index;
                return false;
            }
        }
        if next.collision_frame != collision_frame {
            if !find_collision(c, wall.adjoin, always_walk) {
                if !c.wall {
                    c.wall = wall;
                    c.wall_sector = sector_index;
                }
                return false;
            }
        }
    }
    return true;
}

// Things in the way (0x5b028): objects with a width, other than pickups, whose box the
// cylinder's box overlaps at the destination but not at the start, and whose height it
// meets there. The side of the box the path comes in through gives the direction to slide.
// The original keeps the player among its sector's objects, so others meet it too; here
// it's looked at after them.
find_object_collision :: (c: *Collision, sector: s32) -> bool {
    if !world.objects_collide return false;
    for index: walk_sector(sector) {
        o := world.objects[index];
        if o.flags & OBJECT_PICKUP || !o.width continue;
        if hits_box(c, o.position, o.width, o.height) {
            c.hit_object = index;
            return true;
        }
    }
    p := *world.player;
    if c.mover != -1 && p.sector == sector && hits_box(c, p.position, p.width, p.height) {
        c.hit_object = OBJECT_IS_PLAYER;
        return true;
    }
    return false;
}

hits_box :: (c: *Collision, position: Fixed3, width: Fixed, height: Fixed) -> bool {
    // The cylinder itself, where it starts.
    if c.src.x == position.x && c.src.z == position.z return false;
    reach := width + c.width;
    if abs(position.x - c.dst.x) >= reach || abs(position.z - c.dst.z) >= reach return false;
    if position.y - height >= c.dst_y || c.dst_y - c.height >= position.y return false;
    if abs(c.src.x - position.x) < reach && abs(c.src.z - position.z) < reach return false;

    dir_x, dir_z := get_direction_and_length(c.dst.x - c.src.x, c.dst.z - c.src.z);
    x_sign: s32 = ifx c.dst.x - c.src.x < 0 then cast(s32) -1 else 1;
    z_sign: s32 = ifx c.dst.z - c.src.z < 0 then cast(s32) -1 else 1;
    edge_x := ifx x_sign < 0 then position.x + width else position.x - width;
    edge_z := ifx z_sign < 0 then position.z + width else position.z - width;
    cross := mul16(edge_x - c.dst.x, dir_z) - mul16(edge_z - c.dst.z, dir_x);
    c_sign: s32 = ifx cross < 0 then cast(s32) -1 else 1;
    c.responds = true;
    if (c_sign ^ x_sign ^ z_sign) < 0 {
        if z_sign < 0 {
            c.response_dir = .{-FIXED_ONE, 0};
            c.response_pos = .{position.x + width, position.z + width};
            c.response_angle = 0x2FFF;
        } else {
            c.response_dir = .{FIXED_ONE, 0};
            c.response_pos = .{position.x - width, position.z - width};
            c.response_angle = 0xFFF;
        }
    } else {
        if x_sign >= 0 {
            c.response_dir = .{0, -FIXED_ONE};
            c.response_pos = .{position.x - width, position.z + width};
            c.response_angle = 0x1FFF;
        } else {
            c.response_dir = .{0, FIXED_ONE};
            c.response_pos = .{position.x + width, position.z - width};
            c.response_angle = 0;
        }
    }
    return true;
}

// Turns the move to slide along what was hit (0x33ecc): what's left of it along the
// direction, and toward or away from the line through the response point by the gap to
// the cylinder's edge, pushing out at most 4 units a second.
slide_along :: (c: *Collision, p: *Player, move: *Fixed2) {
    dir, pos := c.response_dir, c.response_pos;
    along := mul16(move.x, dir.x) + mul16(move.z, dir.z);
    distance := mul16(p.position.x - pos.x, dir.z) - mul16(p.position.z - pos.z, dir.x);
    overlap := p.width + 0x41 - distance;
    if overlap >= 0 {
        push := mul16(world.clock.dt, 4 * FIXED_ONE);
        if overlap > push  overlap = push;
        c.bot = world.level.sectors[p.sector].floor.altitude;
    }
    move.x = mul16(overlap, dir.z) + mul16(along, dir.x);
    move.z = mul16(along, dir.z) - mul16(overlap, dir.x);
}

// Whether the path from x0, z0 to x1, z1 crosses a wall, and where (0x56e80, 0x57130).
intersect_path :: (sector: *Sector, wall: *Wall) -> bool, Fixed, Fixed {
    w0 := sector.vertices[wall.left];
    w1 := sector.vertices[wall.right];
    x0, x1, z0, z1 := path.x0, path.x1, path.z0, path.z1;
    pdx := x1 - x0;
    wdx := w0.x - w1.x;
    min_x, max_x := x0, x1;
    if pdx < 0  min_x, max_x = x1, x0;
    if wdx < 1 { if max_x < w0.x || w1.x < min_x return false, 0, 0; }
    else       { if max_x < w1.x || w0.x < min_x return false, 0, 0; }
    pdz := z1 - z0;
    wdz := w0.z - w1.z;
    min_z, max_z := z0, z1;
    if pdz < 0  min_z, max_z = z1, z0;
    if wdz < 1 { if max_z < w0.z || w1.z < min_z return false, 0, 0; }
    else       { if max_z < w1.z || w0.z < min_z return false, 0, 0; }
    ax := x0 - w0.x;
    az := z0 - w0.z;
    num := mul16(wdz, ax) - mul16(wdx, az);
    den := mul16(pdz, wdx) - mul16(pdx, wdz);
    // Both fractions between 0 and 1: with den positive the original compares unsigned,
    // which also turns away a negative num.
    if den < 1 { if num > 0 || num < den return false, 0, 0; }
    else if cast,no_check(u32) den < cast,no_check(u32) num return false, 0, 0;
    num2 := mul16(pdx, az) - mul16(pdz, ax);
    if den < 1 { if num2 > 0 || num2 < den return false, 0, 0; }
    else if cast,no_check(u32) den < cast,no_check(u32) num2 return false, 0, 0;
    if den == 0 return false, 0, 0;
    t := div16(num, den);
    return true, mul16(t, pdx) + x0, mul16(t, pdz) + z0;
}

// The walk for for_each_sector_reached (0x5b88c): the sectors whose walls the cylinder
// touches, through openings that aren't solid.
visit_sectors_reached :: (c: *Collision, sector_index: s32, proc: (c: *Collision, sector: s32) -> bool) -> bool {
    if !proc(c, sector_index) return true;
    sector := *world.level.sectors[sector_index];
    sector.collision_frame = collision_frame;
    for * wall: sector.walls {
        v0 := sector.vertices[wall.left];
        dir := wall.direction;
        dz := c.dst.z - v0.z;
        dx := c.dst.x - v0.x;
        distance := mul16(dx, dir.z) - mul16(dz, dir.x);
        if distance < 0  distance = -distance;
        if distance > c.width continue;
        along := cast,no_check(u32) (mul16(dz, dir.z) + mul16(dx, dir.x));
        length := cast,no_check(u32) wall.length;
        if !(along <= length || along + cast,no_check(u32) c.width <= length + cast,no_check(u32) c.double_width) continue;
        if wall.adjoin < 0 || (wall.flags[2] & (WALL_ALWAYS_WALK | WALL_SOLID)) == WALL_SOLID continue;
        if world.level.sectors[wall.adjoin].collision_frame == collision_frame continue;
        if !visit_sectors_reached(c, wall.adjoin, proc) return false;
    }
    return true;
}
