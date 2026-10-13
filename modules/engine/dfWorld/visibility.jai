// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// What the original's renderer marks as seen, for the map: the walls it draws and the sectors
// it walks into. The GPU draws the view its own way (draw.jai), so the marks come from this
// pass, which walks the level the way DARK.EXE's renderer does on its 320x200 screen, in its
// 16.16 math, without drawing: each wall projected to columns and clipped to the view (0x51f30),
// a sector's walls hiding each other column by column (0x5260c), and openings narrowing the
// window the sector behind is walked in (0x506a0). A wall is marked whenever it comes out of
// that with columns left, even when it lies wholly above or below the window; every wall
// drawer marks it on each of its ways out (0x534c8, 0x53d94, 0x54970, 0x55534, 0x56500).
//
// It's the same at every resolution: the original's screen decides, so Enhanced and Original
// reveal the same map.

// Marks what the view from the player's eye shows. world_draw does it every drawn frame; runs
// without a screen can call it themselves.
world_mark_seen :: () {
    if !world.loaded return;
    p := *world.player;
    if p.sector < 0 || p.sector >= world.level.sectors.count return;

    v: Seen_View;
    v.eye_y = p.position.y + p.bob - p.height;
    // The camera (0x50294): turned by minus the yaw, the eye at the origin.
    v.sin, v.cos = sin_cos(-p.object_yaw);
    x, z := -p.position.x, -p.position.z;
    v.move_x = mul16(x, v.cos) + mul16(z, v.sin);
    v.move_z = mul16(z, v.cos) + mul16(x, -v.sin);
    v.center_y = ((SCREEN_HEIGHT / 2) << 16) + mul16(tan_fixed(p.pitch), FOCAL);
    v.processed = NewArray(world.level.sectors.count, Processed_Sector,, temp);
    v.segments.allocator = temp;

    window := Seen_Window.{0, SCREEN_WIDTH - 1, 0, SCREEN_HEIGHT - 1, 0};
    see_sector(*v, p.sector, window, 1);
}

#scope_file

FOCAL     :Fixed: (SCREEN_WIDTH / 2) << 16;
CENTER_X  :Fixed: (SCREEN_WIDTH / 2) << 16;
MAX_DEPTH :: 40;            // How deep the walk goes (0x506a0).
MAX_SEGMENTS :: 384;        // Walls a frame projects (0x51f30), and segments its merges keep,
MAX_SPLITS :: 40;           // and segments a sector's merge can split off (0x5260c).

Seen_View :: struct {
    eye_y: Fixed;
    sin, cos: Fixed;
    move_x, move_z: Fixed;
    center_y: Fixed;
    processed: [] Processed_Sector;     // By sector: its walls projected, once a frame.
    segments: [..] Segment;
    merged: s32;                        // Segments the merges have kept this frame.
    path: [MAX_DEPTH] struct { sector, wall: s32; };    // The openings being looked through.
}

Processed_Sector :: struct {
    done: bool;
    first, count: s32;          // Into the view's segments.
    vertices: [] Fixed2;        // In view space: x right, z ahead.
}

// The part of the screen a sector is walked in (0x51378): its columns, its rows from the
// highest to the lowest the opening reaches, and how near its walls may be.
Seen_Window :: struct {
    min_x, max_x: s32;
    min_y, max_y: s32;
    min_z: Fixed;
}

// A wall's columns on the screen, from the wall's projection (x0_raw to x1_raw) and as the
// merge has cut them (x0 to x1); its depth at its ends.
Segment :: struct {
    wall: s32;
    x0_raw, x1_raw: s32;
    x0, x1: s32;
    z0, z1: Fixed;
}

// An opening's window into the next sector, as the wall drawers hand it on (0x510c4).
Opening :: struct {
    segment: Segment;
    x0, x1: s32;
    top, bottom: s32;           // The highest top and lowest bottom rows along it.
}

see_sector :: (v: *Seen_View, sector_index: s32, window: Seen_Window, depth: s32) {
    sector := *world.level.sectors[sector_index];
    sector.flags[0] |= SECTOR_SEEN;
    processed := process_sector(v, sector_index);

    merged := merge_segments(v, sector_index, processed, window, depth);
    quick_sort(merged, (a: Segment, b: Segment) -> s64 { return a.x0 - b.x0; });

    openings: [..] Opening;
    openings.allocator = temp;
    for merged {
        wall := *sector.walls[it.wall];
        wall.seen = true;
        if wall.adjoin < 0 continue;
        opening, open := get_opening(v, sector, it, window);
        if open  array_add(*openings, opening);
    }
    if depth >= MAX_DEPTH return;

    for openings {
        next := window;
        next.min_x, next.max_x = it.x0, it.x1;
        next.min_y = max(next.min_y, it.top);
        next.max_y = min(next.max_y, it.bottom);
        next.min_z = min(it.segment.z0, it.segment.z1);
        v.path[depth - 1] = .{sector_index, it.segment.wall};
        see_sector(v, sector.walls[it.segment.wall].adjoin, next, depth + 1);
        v.path[depth - 1] = .{-1, -1};
    }
}

// The sector's vertices in view space and its walls projected, the first time the walk
// reaches it this frame.
process_sector :: (v: *Seen_View, sector_index: s32) -> *Processed_Sector {
    processed := *v.processed[sector_index];
    if processed.done return processed;
    processed.done = true;
    sector := *world.level.sectors[sector_index];
    processed.vertices = NewArray(sector.vertices.count, Fixed2,, temp);
    for sector.vertices {
        processed.vertices[it_index] = .{
            mul16(it.x, v.cos) + mul16(it.z, v.sin) + v.move_x,
            mul16(it.z, v.cos) + mul16(it.x, -v.sin) + v.move_z,
        };
    }
    processed.first = xx v.segments.count;
    for * sector.walls  process_wall(v, processed, xx it_index, it);
    processed.count = xx v.segments.count - processed.first;
    return processed;
}

// A wall's columns, clipped to the view's sides and the near plane, or none (0x51f30).
process_wall :: (v: *Seen_View, processed: *Processed_Sector, wall_index: s32, wall: *Wall) {
    a, b := processed.vertices[wall.left], processed.vertices[wall.right];
    x0, z0, x1, z1 := a.x, a.z, b.x, b.z;
    if z0 < 0 && z1 < 0 return;
    if x0 < -z0 && x1 < -z1 return;
    if z0 < x0 && z1 < x1 return;
    dx, dz := x1 - x0, z1 - z0;
    // Facing away.
    if mul16(-z0, -dx) + mul16(-x0, dz) < 0 return;

    // Cut by the view's sides, the lines x = -z and x = z.
    clipped_left, clipped_right: bool;
    if x0 < -z0 {
        z := mul16(x0, z1) - mul16(x1, z0);
        if -dx - dz != 0  z = div16(z, -dx - dz);
        x0, z0 = -z, z;
        dx, dz = x1 - x0, z1 - z0;
        clipped_left = true;
    }
    if z1 < x1 {
        x := mul16(x0, z1) - mul16(x1, z0);
        if dz - dx != 0  x = div16(x, dz - dx);
        x1, z1 = x, x;
        dx, dz = x1 - x0, z1 - z0;
        clipped_right = true;
    }
    // A wall still reaching behind the eye is kept only if the eye and the point 100 behind
    // it are on the same side of it.
    if (z0 < 0 || z1 < 0) && !are_on_same_side(x0, z0, x1, z1, 0, 0, 0, -100 * FIXED_ONE) return;

    // Cut at the near plane, z = 1.
    near_left, near_right: bool;
    if z0 < FIXED_ONE && z1 < FIXED_ONE {
        if clipped_left { x0 = -FIXED_ONE; near_left = true; }
        else              x0 = div16(x0, z0);
        if clipped_right { x1 = FIXED_ONE; near_right = true; }
        else               x1 = div16(x1, z1);
        z0, z1 = FIXED_ONE, FIXED_ONE;
    } else if z0 < FIXED_ONE {
        if clipped_left {
            if dz != 0  x0 += mul16(dx, div16(FIXED_ONE - z0, dz));
            near_left = true;
        } else {
            x0 = div16(x0, z0);
        }
        z0 = FIXED_ONE;
    } else if z1 < FIXED_ONE {
        if clipped_right {
            if dz != 0  x1 += mul16(dx, div16(FIXED_ONE - z1, dz));
            near_right = true;
        } else {
            x1 = div16(x1, z1);
        }
        z1 = FIXED_ONE;
    }

    px0 := (div16(mul16(x0, FOCAL), z0) + CENTER_X + FIXED_HALF) >> 16;
    px1 := ((div16(mul16(x1, FOCAL), z1) + CENTER_X + FIXED_HALF) >> 16) - 1;
    // Cut at the near plane on a side, the wall reaches the screen's edge, against holes.
    if near_left && px0 > 0  px0 = 0;
    if near_right && px1 < SCREEN_WIDTH - 1  px1 = SCREEN_WIDTH - 1;
    if px1 < px0 return;
    if px0 > SCREEN_WIDTH - 1 || px1 < 0 return;
    if v.segments.count >= MAX_SEGMENTS return;
    px0 = max(px0, 0);
    px1 = min(px1, SCREEN_WIDTH - 1);
    array_add(*v.segments, .{wall_index, px0, px1, px0, px1, z0, z1});
}

// The sector's walls in the window, each cut to the columns no nearer wall of the sector
// covers (0x5260c). A wall the walk is looking out through is left out, as are walls
// wholly nearer than the opening the sector is seen through.
merge_segments :: (v: *Seen_View, sector_index: s32, processed: *Processed_Sector, window: Seen_Window, depth: s32) -> [] Segment {
    out: [..] Segment;
    out.allocator = temp;
    splits: [..] Segment;
    splits.allocator = temp;
    vertices := processed.vertices;
    walls := world.level.sectors[sector_index].walls;
    get_ends :: (walls: [] Wall, vertices: [] Fixed2, s: Segment) -> Fixed2, Fixed2 {
        w := *walls[s.wall];
        return vertices[w.left], vertices[w.right];
    }

    source := 0;
    split_next := 0;
    while true {
        s: *Segment;
        if source < processed.count {
            s = *v.segments[processed.first + source];
            source += 1;
        } else if split_next < splits.count {
            s = *splits[split_next];
            split_next += 1;
        } else {
            break;
        }

        on_path := false;
        for 0..depth-2  if v.path[it].sector == sector_index && v.path[it].wall == s.wall  on_path = true;
        if on_path continue;
        if !(s.z0 >= window.min_z || s.z1 >= window.min_z) || s.x0 > window.max_x || s.x1 < window.min_x continue;

        n := s.*;
        n.x0 = max(n.x0, window.min_x);
        n.x1 = min(n.x1, window.max_x);
        hidden := false;
        i := 0;
        while i < out.count && !hidden {
            o := *out[i];
            i += 1;
            if !(n.x0 <= o.x1 && o.x0 <= n.x1) continue;
            o0, o1 := get_ends(walls, vertices, o);
            n0, n1 := get_ends(walls, vertices, n);

            if n.x0 <= o.x0 && o.x1 <= n.x1 {
                // The new one spans the other.
                if is_in_front(n0, n1, o0, o1) {
                    array_ordered_remove_by_index(*out, i - 1);
                    i -= 1;
                } else if n.x0 < o.x0 && o.x1 < n.x1 {
                    // With no room to split it, the original drops it.
                    if splits.count == MAX_SPLITS {
                        hidden = true;
                        break;
                    }
                    split := n;
                    split.x0 = o.x1 + 1;
                    array_add(*splits, split);
                    n.x1 = o.x0 - 1;
                } else if n.x0 < o.x0 {
                    n.x1 = o.x0 - 1;
                } else {
                    n.x0 = o.x1 + 1;
                }
            } else if o.x0 <= n.x0 && n.x1 <= o.x1 {
                // The other spans the new one.
                if !is_in_front(n0, n1, o0, o1) {
                    hidden = true;
                } else if o.x0 < n.x0 && n.x1 < o.x1 {
                    if splits.count == MAX_SPLITS {
                        o.x1 = n.x0 - 1;
                        hidden = true;
                        break;
                    }
                    split := o.*;
                    split.x0 = n.x1 + 1;
                    array_add(*splits, split);
                    o.x1 = n.x0 - 1;
                } else if o.x0 < n.x0 {
                    o.x1 = n.x0 - 1;
                } else {
                    o.x0 = n.x1 + 1;
                }
            } else if o.x0 <= n.x1 && n.x1 < o.x1 {
                // The new one overlaps the other's left end.
                if is_apart_in_depth(n0, n1, o0, o1) {
                    if n1.z < o0.z  o.x0 = n.x1 + 1;
                    else            n.x1 = o.x0 - 1;
                } else if are_on_same_side(o0.x, o0.z, o1.x, o1.z, n1.x, n1.z, 0, 0) && !are_on_same_side(n0.x, n0.z, n1.x, n1.z, o0.x, o0.z, 0, 0) {
                    o.x0 = n.x1 + 1;
                } else {
                    n.x1 = o.x0 - 1;
                }
            } else {
                // The new one overlaps the other's right end.
                if is_apart_in_depth(n0, n1, o0, o1) {
                    if n0.z < o1.z  o.x1 = n.x0 - 1;
                    else            n.x0 = o.x1 + 1;
                } else if are_on_same_side(o0.x, o0.z, o1.x, o1.z, n0.x, n0.z, 0, 0) && !are_on_same_side(n0.x, n0.z, n1.x, n1.z, o1.x, o1.z, 0, 0) {
                    o.x1 = n.x0 - 1;
                } else {
                    n.x0 = o.x1 + 1;
                }
            }
        }
        if !hidden && n.x0 <= n.x1 && v.merged + out.count < MAX_SEGMENTS  array_add(*out, n);
    }
    v.merged += xx out.count;
    return out;
}

// Whether one wall's depths lie wholly nearer or farther than the other's.
is_apart_in_depth :: (n0: Fixed2, n1: Fixed2, o0: Fixed2, o1: Fixed2) -> bool {
    return max(n0.z, n1.z) < min(o0.z, o1.z) || max(o0.z, o1.z) < min(n0.z, n1.z);
}

// Whether the new wall (n0 to n1) is in front of the other where they overlap (0x5260c):
// by depth when they're apart in it, otherwise by which side of each the other's ends and
// the eye are on.
is_in_front :: (n0: Fixed2, n1: Fixed2, o0: Fixed2, o1: Fixed2) -> bool {
    if is_apart_in_depth(n0, n1, o0, o1)  return n0.z < o0.z;
    // The new wall's ends on the eye's side of the other, and the other's.
    new_on_eye_side := are_on_same_side(o0.x, o0.z, o1.x, o1.z, n0.x, n0.z, 0, 0) || are_on_same_side(o0.x, o0.z, o1.x, o1.z, n1.x, n1.z, 0, 0);
    other_on_eye_side := are_on_same_side(n0.x, n0.z, n1.x, n1.z, o0.x, o0.z, 0, 0) && are_on_same_side(n0.x, n0.z, n1.x, n1.z, o1.x, o1.z, 0, 0);
    if o0.z <= n0.z  return new_on_eye_side && !other_on_eye_side;
    other_in_front := (are_on_same_side(n0.x, n0.z, n1.x, n1.z, o0.x, o0.z, 0, 0) || are_on_same_side(n0.x, n0.z, n1.x, n1.z, o1.x, o1.z, 0, 0))
                   && !(are_on_same_side(o0.x, o0.z, o1.x, o1.z, n0.x, n0.z, 0, 0) && are_on_same_side(o0.x, o0.z, o1.x, o1.z, n1.x, n1.z, 0, 0));
    return !other_in_front;
}

// Whether points p and q are on the same side of the line through a and b (0x57b08), in
// the original's 12 fractional bits.
are_on_same_side :: (ax: Fixed, az: Fixed, bx: Fixed, bz: Fixed, px: Fixed, pz: Fixed, qx: Fixed, qz: Fixed) -> bool {
    ax4, az4 := ax >> 4, az >> 4;
    dz := (bz >> 4) - az4;
    dx := (bx >> 4) - ax4;
    side_p := mul16((px >> 4) - ax4, dz) - mul16(dx, (pz >> 4) - az4);
    side_q := mul16((qx >> 4) - ax4, dz) - mul16(dx, (qz >> 4) - az4);
    return mul16(side_p, side_q) > 0;
}

// What a wall with an adjoin lets through, by the wall drawer the original picks for it
// (0x506a0): its window into the next sector, if any. Every way out of the drawers marks
// the wall; only the ones that reach the opening's rows hand it on.
get_opening :: (v: *Seen_View, sector: *Sector, s: Segment, window: Seen_Window) -> Opening, bool {
    wall := *sector.walls[s.wall];
    next := *world.level.sectors[wall.adjoin];
    // What shows above and below the opening.
    has_top    := sector.ceiling.altitude < next.ceiling.altitude;
    has_bottom := sector.floor.altitude > next.floor.altitude;
    sky_top    := (next.flags[0] & SECTOR_EXTERIOR_ADJ) != 0;
    pit_bottom := (next.flags[0] & SECTOR_PIT_ADJ) != 0;
    Drawer :: enum { MASK; TOP; BOTTOM; TOP_AND_BOTTOM; }
    drawer := Drawer.MASK;
    if has_top && has_bottom {
        if sky_top && pit_bottom  drawer = .MASK;
        else if sky_top           drawer = .BOTTOM;
        else if pit_bottom        drawer = .TOP;
        else                      drawer = .TOP_AND_BOTTOM;
    } else if has_top {
        drawer = ifx sky_top then .MASK else .TOP;
    } else if has_bottom {
        drawer = ifx pit_bottom then .MASK else .BOTTOM;
    }
    opening: Opening;
    open: bool;
    if drawer == {
        case .MASK;           opening, open = see_through_mask(v, sector, next, s, window);
        case .TOP;            opening, open = see_through_top(v, sector, next, s, window);
        case .BOTTOM;         opening, open = see_through_bottom(v, sector, next, s, window);
        case .TOP_AND_BOTTOM; opening, open = see_through_top_and_bottom(v, sector, next, s, window);
    }
    return opening, open;
}

// A height's row on the screen at depth z, in 16.16.
project_y :: (v: *Seen_View, altitude: Fixed, z: Fixed) -> Fixed {
    return div16(mul16(altitude - v.eye_y, FOCAL), z) + v.center_y;
}

round_fixed :: inline (f: Fixed) -> s32 { return (f + FIXED_HALF) >> 16; }

// A height along the segment: its row at the first column and its change per column, the
// slope taken over the wall's whole projection.
Span :: struct { start, slope: Fixed; }

get_span :: (s: Segment, y0: Fixed, y1: Fixed) -> Span {
    length := int_to_fixed(s.x1_raw - s.x0_raw);
    slope: Fixed = ifx length != 0 then div16(y1 - y0, length) else 0;
    offset := int_to_fixed(s.x0 - s.x0_raw);
    start := y0;
    if offset != 0  start += mul16(slope, offset);
    return .{start, slope};
}

// The window an opening makes, from its top and bottom edges (0x510c4, 0x51378): the
// highest point of the top and the lowest of the bottom, at its ends.
make_opening :: (s: Segment, top: Span, bottom: Span) -> Opening {
    length := s.x1 - s.x0 + 1;
    get_end :: (span: Span, length: s32) -> Fixed {
        if span.slope == 0 return span.start;
        return span.start + mul16(span.slope, int_to_fixed(length - 1));
    }
    t0, t1 := round_fixed(top.start), round_fixed(get_end(top, length));
    b0, b1 := round_fixed(bottom.start), round_fixed(get_end(bottom, length));
    return .{segment = s, x0 = s.x0, x1 = s.x1, top = min(t0, t1), bottom = max(b0, b1)};
}

// No top or bottom (0x56500): the whole height between the sector's ceiling and floor, sky
// and pit reaching the screen's edge.
see_through_mask :: (v: *Seen_View, sector: *Sector, next: *Sector, s: Segment, window: Seen_Window) -> Opening, bool {
    c0, c1: Fixed;
    if (sector.flags[0] & SECTOR_EXTERIOR) && (next.flags[0] & SECTOR_EXTERIOR_ADJ) {
        c0, c1 = 0, 0;
    } else {
        c0, c1 = project_y(v, sector.ceiling.altitude, s.z0), project_y(v, sector.ceiling.altitude, s.z1);
    }
    if round_fixed(c0) > window.max_y && round_fixed(c1) > window.max_y  return .{}, false;
    f0, f1: Fixed;
    if (sector.flags[0] & SECTOR_PIT) && (next.flags[0] & SECTOR_PIT_ADJ) {
        f0, f1 = (SCREEN_HEIGHT - 1) << 16, (SCREEN_HEIGHT - 1) << 16;
    } else {
        f0, f1 = project_y(v, sector.floor.altitude, s.z0), project_y(v, sector.floor.altitude, s.z1);
    }
    if round_fixed(f0) < window.min_y && round_fixed(f1) < window.min_y  return .{}, false;
    if next.floor.altitude <= next.ceiling.altitude  return .{}, false;
    return make_opening(s, get_span(s, c0, c1), get_span(s, f0, f1)), true;
}

// A wall under the opening (0x54970): the opening from the sector's ceiling down to the
// next one's floor.
see_through_bottom :: (v: *Seen_View, sector: *Sector, next: *Sector, s: Segment, window: Seen_Window) -> Opening, bool {
    c0, c1: Fixed;
    if (sector.flags[0] & SECTOR_EXTERIOR) && (next.flags[0] & SECTOR_EXTERIOR_ADJ) {
        c0, c1 = 0, 0;
    } else {
        c0, c1 = project_y(v, sector.ceiling.altitude, s.z0), project_y(v, sector.ceiling.altitude, s.z1);
    }
    if round_fixed(c0) > window.max_y && round_fixed(c1) >= window.max_y  return .{}, false;
    f0, f1 := project_y(v, sector.floor.altitude, s.z0), project_y(v, sector.floor.altitude, s.z1);
    if round_fixed(f0) < window.min_y && round_fixed(f1) < window.min_y  return .{}, false;
    n0, n1 := project_y(v, next.floor.altitude, s.z0), project_y(v, next.floor.altitude, s.z1);
    bottom := get_span(s, n0, n1);
    if !(round_fixed(bottom.start) > window.min_y || round_fixed(n1) > window.min_y) || sector.ceiling.altitude >= next.floor.altitude  return .{}, false;
    return make_opening(s, get_span(s, c0, c1), bottom), true;
}

// A wall over the opening (0x53d94): the opening from the next sector's ceiling down to this
// one's floor.
see_through_top :: (v: *Seen_View, sector: *Sector, next: *Sector, s: Segment, window: Seen_Window) -> Opening, bool {
    c0, c1 := project_y(v, sector.ceiling.altitude, s.z0), project_y(v, sector.ceiling.altitude, s.z1);
    if round_fixed(c0) > window.max_y && round_fixed(c1) > window.max_y  return .{}, false;
    f0, f1: Fixed;
    if (sector.flags[0] & SECTOR_PIT) && (next.flags[0] & SECTOR_PIT_ADJ) {
        f0, f1 = int_to_fixed(window.max_y), int_to_fixed(window.max_y);
    } else {
        f0, f1 = project_y(v, sector.floor.altitude, s.z0), project_y(v, sector.floor.altitude, s.z1);
    }
    if round_fixed(f0) < window.min_y && round_fixed(f1) < window.min_y  return .{}, false;
    n0, n1 := project_y(v, next.ceiling.altitude, s.z0), project_y(v, next.ceiling.altitude, s.z1);
    top := get_span(s, n0, n1);
    if !(round_fixed(top.start) < window.max_y || round_fixed(n1) < window.max_y) || sector.floor.altitude <= next.ceiling.altitude  return .{}, false;
    return make_opening(s, top, get_span(s, f0, f1)), true;
}

// Walls over and under the opening (0x55534): the next sector's ceiling to its floor, a
// row in from each.
see_through_top_and_bottom :: (v: *Seen_View, sector: *Sector, next: *Sector, s: Segment, window: Seen_Window) -> Opening, bool {
    c0, c1 := project_y(v, sector.ceiling.altitude, s.z0), project_y(v, sector.ceiling.altitude, s.z1);
    if round_fixed(c0) > window.max_y && round_fixed(c1) > window.max_y  return .{}, false;
    f0, f1 := project_y(v, sector.floor.altitude, s.z0), project_y(v, sector.floor.altitude, s.z1);
    if round_fixed(f0) < window.min_y && round_fixed(f1) < window.min_y  return .{}, false;
    nc0, nc1 := project_y(v, next.ceiling.altitude, s.z0), project_y(v, next.ceiling.altitude, s.z1);
    nf0, nf1 := project_y(v, next.floor.altitude, s.z0), project_y(v, next.floor.altitude, s.z1);
    top, bottom := get_span(s, nc0, nc1), get_span(s, nf0, nf1);
    if round_fixed(bottom.start) <= window.min_y && round_fixed(nf1) <= window.min_y  return .{}, false;
    if round_fixed(top.start) >= window.max_y && round_fixed(nc1) >= window.max_y  return .{}, false;
    if next.floor.altitude <= next.ceiling.altitude  return .{}, false;
    top.start += FIXED_ONE;
    bottom.start -= FIXED_ONE;
    return make_opening(s, top, bottom), true;
}

#import "Sort";
#import "engine/dfFixed";
