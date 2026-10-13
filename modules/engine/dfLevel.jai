// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Levels: the geometry (LEV), the objects placed in it (O) and the list of the game's levels
// (JEDI.LVL), parsed the way DARK.EXE reads them.
//
// The text formats are read line by line, skipping blank lines and comments, each line matched
// against the pattern the original expects next (LEV) or the one its keyword picks (O).
// Numbers are kept in 16.16 fixed point, as the original stores them: read as a float and
// multiplied by 65536, truncated.
//
// Coordinates are the game's: x and z across the map, y down, so a ceiling's altitude is
// smaller than its floor's. A sector is a set of vertices in x/z and the walls between them,
// with a floor and a ceiling; sectors join each other through adjoined walls.

Fixed2 :: struct { x, z: Fixed; }
Fixed3 :: struct { x, y, z: Fixed; }

Level :: struct {
    name:     string;
    palette:  string;           // PAL name.
    music:    string;
    parallax: [2] Fixed;        // Sky texels per full turn: across, up and down.
    textures: [..] string;      // BM names; empty for none.
    sectors:  [..] Sector;
}

Flat :: struct {
    texture: s32 = -1;          // Into Level.textures.
    offset:  Fixed2;            // World units.
    altitude: Fixed;
}

// A sector's flags (the first of its three FLAGS words).
SECTOR_EXTERIOR       :: 0x1;       // Sky for a ceiling.
SECTOR_DOOR           :: 0x2;
SECTOR_MAG_SEAL       :: 0x4;       // Shots bounce off its walls, floor and ceiling.
SECTOR_EXPLODING_WALL :: 0x40;
SECTOR_EXTERIOR_ADJ   :: 0x8;       // Its sky shows over walls to other exterior sectors.
SECTOR_ICE            :: 0x10;
SECTOR_SNOW           :: 0x20;
SECTOR_PIT            :: 0x80;      // Sky for a floor.
SECTOR_PIT_ADJ        :: 0x100;     // Its pit shows under walls to other pits.
SECTOR_CRUSHING       :: 0x200;     // Elevators crush rather than turn back.
SECTOR_NO_WALLS       :: 0x400;     // The sky is drawn in place of its walls' top and bottom.
SECTOR_LOW_DAMAGE     :: 0x800;     // Both: gas.
SECTOR_HIGH_DAMAGE    :: 0x1000;
SECTOR_NO_SMART       :: 0x2000;
SECTOR_SMART          :: 0x4000;
SECTOR_SAFE           :: 0x10000;   // Set by the game where a SAFE object stands.
SECTOR_SEEN           :: 0x20000;   // Set by the game once drawn: the map shows it.
SECTOR_SECRET         :: 0x80000;

Sector :: struct {
    id:       s32;
    name:     string;
    ambient:  Fixed;            // Light level 0..31, 16.16.
    floor, ceiling: Flat;
    second_altitude: Fixed;     // From the floor: down for water, up for a raised platform.
    flags:    [3] u32;
    layer:    s32;
    vertices: [..] Fixed2;
    walls:    [..] Wall;

    // Derived, as the original keeps them: the bounds of the walls' left vertices, and the
    // heights collision works with (see level_update_collision_heights).
    bounds_min, bounds_max: Fixed2;
    col_floor, col_ceiling: Fixed;
    col_second, col_second_ceiling: Fixed;

    collision_frame: s32;       // The last collision walk that reached it.
}

Wall_Texture :: struct {
    texture: s32 = -1;          // Into Level.textures.
    offset:  Fixed2;            // Texels.
}

// A wall's flags (its first FLAGS word).
WALL_MASKED         :: 0x1;     // The mid texture is drawn over the adjoin, index 0 see-through.
WALL_ILLUMINATED_SIGN :: 0x2;
WALL_FLIP           :: 0x4;
WALL_CHANGES_LIGHT  :: 0x8;
WALL_ANCHORED       :: 0x10;
WALL_MORPHS         :: 0x20;
WALL_SCROLLS_TOP    :: 0x40;
WALL_SCROLLS_MID    :: 0x80;
WALL_SCROLLS_BOTTOM :: 0x100;
WALL_SCROLLS_SIGN   :: 0x200;
WALL_HIDE_ON_MAP    :: 0x400;
WALL_NORMAL_ON_MAP  :: 0x800;
WALL_SIGN_ANCHORED  :: 0x1000;
WALL_DAMAGE         :: 0x2000;   // Hurts to touch.
WALL_LEDGE_ON_MAP   :: 0x4000;
WALL_DOOR_ON_MAP    :: 0x8000;
// Its third FLAGS word.
WALL_ALWAYS_WALK    :: 0x1;
WALL_SOLID          :: 0x2;
WALL_PLAYER_ONLY    :: 0x4;     // Enemies don't cross it.
WALL_NO_SHOOT       :: 0x8;     // Shots don't pass it.

Wall :: struct {
    left, right: s32;           // Into the sector's vertices.
    mid, top, bottom, sign: Wall_Texture;
    adjoin: s32 = -1;           // The sector on the other side, as an index; -1 for none.
    mirror: s32 = -1;           // The same wall in that sector.
    walk:   s32 = -1;
    flags:  [3] u32;
    light:  Fixed;              // Added to the light level; signed, 16.16.

    // Derived from the vertices, as the original keeps them (level_update_wall_shape).
    direction: Fixed2;          // Unit vector from left to right.
    length:    Fixed;
    angle:     s32;             // 16384 to a turn, 0 along +z.

    // Which of its parts show, as the original keeps it: worked out at load and when an
    // adjoin changes, not as heights move (level_update_wall_parts).
    parts: u32;

    path_frame: s32;            // The last path walk that crossed it.
    seen: bool;                 // Drawn at some time: the map shows it.
}

level_free :: (level: *Level) {
    free(level.name);
    free(level.palette);
    free(level.music);
    for level.textures  free(it);
    array_free(level.textures);
    for * level.sectors {
        free(it.name);
        array_free(it.vertices);
        array_free(it.walls);
    }
    array_free(level.sectors);
    level.* = .{};
}

lev_parse :: (text: string) -> Level, bool {
    level: Level;
    ok := parse_lev(*level, text);
    if !ok  level_free(*level);
    return level, ok;
}

// The sector holding a point (DARK.EXE 0x5a044): of those whose altitudes and bounds contain
// it and that have it inside, the one with the smallest bounds, counted in whole units
// across times down, the first of a tie. That's how the original resolves layers and sectors
// inside sectors. -1 when none does.
level_find_sector :: (level: *Level, p: Fixed3) -> s32 {
    best: s32 = -1;
    best_area: s32;
    for * level.sectors {
        if p.y < it.ceiling.altitude || p.y > it.floor.altitude continue;
        lo, hi := it.bounds_min, it.bounds_max;
        area := (((hi.z - lo.z) >> 16) + 1) * (((hi.x - lo.x) >> 16) + 1);
        if p.x < lo.x || p.x > hi.x || p.z < lo.z || p.z > hi.z continue;
        if !is_point_in_sector(it, p.x, p.z) continue;
        if best >= 0 && best_area <= area continue;
        best = xx it_index;
        best_area = area;
    }
    return best;
}

// Whether (x, z) is inside the sector, its edges and corners counting as inside: crossings
// of a ray toward +x, with the original's rules for corners and walls along x (0x5a044).
is_point_in_sector :: (sector: *Sector, x: Fixed, z: Fixed) -> bool {
    if !sector.walls return false;
    last := *sector.walls[sector.walls.count - 1];
    previous_dz := sector.vertices[last.right].z - sector.vertices[last.left].z;
    crossings := 0;
    for sector.walls {
        a := sector.vertices[it.left];
        b := sector.vertices[it.right];
        dz := b.z - a.z;
        if dz == 0 {
            if get_edge_crossing(x, z, a, b) == 0 return true;
            dz = previous_dz;   // A wall along x leaves the last direction in z as it was.
        } else if z == a.z {
            if x == a.x return true;
            // A ray through a corner counts once, where the walls go on the same way in z.
            if x < a.x && ((dz ^ previous_dz) >= 0 || previous_dz == 0)  crossings += 1;
        } else if z != b.z {
            crossing := get_edge_crossing(x, z, a, b);
            if crossing == 0 return true;
            if crossing == 1  crossings += 1;
        }
        previous_dz = dz;
    }
    return (crossings & 1) != 0;
}

WALL_PART_TOP    :: 1;
WALL_PART_BOTTOM :: 2;

// The parts of a sector's walls with an adjoin that show, and their mirrors' (0x5a788): the
// top where the sector's ceiling is above the next one's, the bottom where its floor is
// below. A wall that loses its adjoin keeps what it had.
level_update_wall_parts :: (level: *Level, sector: *Sector) {
    for * w: sector.walls {
        if w.adjoin < 0 || w.mirror < 0 continue;
        next := *level.sectors[w.adjoin];
        m := *next.walls[w.mirror];
        w.parts, m.parts = 0, 0;
        if sector.ceiling.altitude < next.ceiling.altitude  w.parts |= WALL_PART_TOP;
        if next.floor.altitude < sector.floor.altitude      w.parts |= WALL_PART_BOTTOM;
        if next.ceiling.altitude < sector.ceiling.altitude  m.parts |= WALL_PART_TOP;
        if sector.floor.altitude < next.floor.altitude      m.parts |= WALL_PART_BOTTOM;
    }
}

// The heights collision uses (0x5aa18): the floor and ceiling, a pit's floor and a sky
// 100 units off; the second floor, which a raised one can't take below the floor.
level_update_collision_heights :: (sector: *Sector) {
    floor := sector.floor.altitude;
    ceiling := sector.ceiling.altitude;
    if sector.flags[0] & SECTOR_PIT       floor += SKY_DEPTH;
    if sector.flags[0] & SECTOR_EXTERIOR  ceiling -= SKY_DEPTH;
    second := sector.floor.altitude + sector.second_altitude;
    if sector.second_altitude >= 0 && second < floor  second = floor;
    sector.col_floor = floor;
    sector.col_ceiling = ceiling;
    sector.col_second = second;
    sector.col_second_ceiling = ceiling;
}

// A wall's direction, length and angle from its vertices. The loader takes the length for
// the direction in floating point (0x15ffd); the length kept is the fixed-point one (0x579bc).
level_update_wall_shape :: (sector: *Sector, wall: *Wall) {
    a := sector.vertices[wall.left];
    b := sector.vertices[wall.right];
    dx := b.x - a.x;
    dz := b.z - a.z;
    wall.angle = vec2_to_angle(dx, dz);
    wall.length = vec2_length(dx, dz);
    fx := cast(float64) dx / 65536.0;
    fz := cast(float64) dz / 65536.0;
    length := cast(Fixed) (sqrt(fx * fx + fz * fz) * 65536.0);
    if length {
        wall.direction = .{div16(dx, length), div16(dz, length)};
    } else {
        wall.direction = .{};
    }
}

level_update_bounds :: (sector: *Sector) {
    if !sector.walls return;
    lo := sector.vertices[sector.walls[0].left];
    hi := lo;
    for sector.walls {
        v := sector.vertices[it.left];
        lo.x = min(lo.x, v.x);
        lo.z = min(lo.z, v.z);
        hi.x = max(hi.x, v.x);
        hi.z = max(hi.z, v.z);
    }
    sector.bounds_min, sector.bounds_max = lo, hi;
}

SKY_DEPTH :Fixed: 0x640000;      // 100 units.

// O -------------------------------------------------------------------------------------------

Object_Class :: enum u8 {
    SPIRIT;         // Invisible: the player's start, scripted things.
    SPRITE;         // A WAX.
    FRAME;          // An FME.
    MODEL;          // A 3DO ("3D").
    SOUND;          // An ambient sound.
    SAFE;           // A place to start again after dying.
}

Level_Object :: struct {
    class:    Object_Class;
    data:     s32;              // Into the pods, sprites, frames or sounds for its class.
    position: Fixed3;
    pitch, yaw, roll: s32;      // 16384 to a turn; yaw 0 faces +z, turning clockwise seen from above.
    difficulty: s32;
    logics:   [..] string;      // LOGIC: and TYPE: values, upper case, the words after the
                                // first in the same string ("ITEM SHIELD").
    eye:      bool;
    radius, height: Fixed = -1; // From RADIUS: and HEIGHT:; -1 for the art's own size.

    // A KEY logic's path: VUE: then any VUE_APPEND:, in order.
    vues:     [..] Vue_Reference;
    frame_rate: float64;        // FRAME_RATE:, or 0.
    pause:    bool;             // PAUSE: given, whatever its value.

    // The logic block's other lines, in order, for the logics that read their own (a
    // generator's DELAY:, MAX_ALIVE:, ...).
    params:   [..] Level_Param;
}

Level_Param :: struct {
    key:   string;              // Upper case, with its colon: "MAX_ALIVE:".
    value: string;              // The word after it, or empty.
    logic: s32;                 // The logic it came after, into logics; -1 before any. The
                                // original hands a line to the last logic set up (0x1582e).
}

Vue_Reference :: struct {
    file, name: string;         // The VUE and the 3DS object in it, "*" for every one.
    append: bool;
}

Level_Objects :: struct {
    pods, sprites, frames, sounds: [..] string;
    objects: [..] Level_Object;
}

level_objects_free :: (objects: *Level_Objects) {
    for objects.pods     free(it);
    for objects.sprites  free(it);
    for objects.frames   free(it);
    for objects.sounds   free(it);
    array_free(objects.pods);
    array_free(objects.sprites);
    array_free(objects.frames);
    array_free(objects.sounds);
    for * objects.objects {
        for it.logics  free(it);
        array_free(it.logics);
        for it.vues { free(it.file); free(it.name); }
        array_free(it.vues);
        for it.params { free(it.key); free(it.value); }
        array_free(it.params);
    }
    array_free(objects.objects);
    objects.* = .{};
}

o_parse :: (text: string) -> Level_Objects, bool {
    objects: Level_Objects;
    ok := parse_o(*objects, text);
    if !ok  level_objects_free(*objects);
    return objects, ok;
}

// Whether an object is placed at a difficulty (1 easy, 2 medium, 3 hard, the agent's plus
// one, 0x14aaf): DIFF 0 and 1 are every level, 2 and 3 from that one up, negative ones up to
// that one.
is_object_in_difficulty :: (object: *Level_Object, difficulty: s32) -> bool {
    d := object.difficulty;
    if d >= 0 return difficulty >= d;
    return difficulty <= -d;
}

// Whether the object has the logic, by its first word.
has_logic :: (object: *Level_Object, logic: string) -> bool {
    for object.logics {
        found, first := split_from_left(it, #char " ");
        if !found  first = it;
        if first == logic return true;
    }
    return false;
}

// JEDI.LVL ------------------------------------------------------------------------------------

Level_Entry :: struct {
    title: string;              // "Secret Base".
    name:  string;              // "SECBASE": the LEV, O, INF and GOL files' name.
}

level_list_free :: (list: *[..] Level_Entry) {
    for list.*  { free(it.title); free(it.name); }
    array_free(list.*);
}

// "LEVELS n", then a line per level: its title, a comma, its file name, then source paths the
// game doesn't use.
lvl_parse :: (text: string) -> [..] Level_Entry, bool {
    list: [..] Level_Entry;
    r := Reader.{text = text};
    if !next_line(*r) return list, false;
    count, ok := match_count(r.line, "LEVELS");
    if !ok return list, false;
    for 1..count {
        if !next_line(*r) break;
        found, title, rest := split_from_left(r.line, #char ",");
        if !found break;
        rest = trim(rest);
        name := rest;
        for 0..rest.count-1 {
            c := rest[it];
            if c == #char "," || c == #char " " || c == #char "\t" { name.count = it; break; }
        }
        array_add(*list, .{copy_string(trim(title)), to_upper_copy(name)});
    }
    return list, list.count > 0;
}

// GOL ---------------------------------------------------------------------------------------

// What each goal waits for, as DARK.EXE keeps it (0xfa064, 0xfa03c): by item number and by
// INF "complete" number, the goal that it finishes; -1 for none.
GOAL_SLOTS :: 10;

Level_Goals :: struct {
    by_item:    [GOAL_SLOTS] s32 = .[-1, -1, -1, -1, -1, -1, -1, -1, -1, -1];
    by_trigger: [GOAL_SLOTS] s32 = .[-1, -1, -1, -1, -1, -1, -1, -1, -1, -1];
}

// "GOL 1.0", then "GOAL: goal ITEM: n" or "GOAL: goal TRIG: n" lines (0x14917). Lines that
// don't scan, or whose n isn't 0 to 9, are skipped; the goal's own number isn't checked.
gol_parse :: (text: string) -> Level_Goals, bool {
    goals: Level_Goals;
    r := Reader.{text = text};
    if !next_line(*r) return goals, false;
    t := split_tokens(r.line);
    if t.count < 2 || !equal_nocase(t.items[0], "GOL") || t.items[1] != "1.0" return goals, false;
    while next_line(*r) {
        t = split_tokens(r.line);
        if t.count < 4 || !equal_nocase(t.items[0], "GOAL:") continue;
        if !is_integer(t.items[1]) || !is_integer(t.items[3]) continue;
        goal, n := to_int(t.items[1]), to_int(t.items[3]);
        if n < 0 || n >= GOAL_SLOTS continue;
        if      equal_nocase(t.items[2], "ITEM:") goals.by_item[n] = goal;
        else if equal_nocase(t.items[2], "TRIG:") goals.by_trigger[n] = goal;
    }
    return goals, true;
}

#scope_file

Reader :: struct {
    text: string;
    line: string;
    block_comments: bool;       // O files also take "//" and "/* */".
    in_block: bool;
}

// The next line with something on it, comments taken off.
next_line :: (r: *Reader) -> bool {
    while r.text {
        _, line, rest := split_from_left(r.text, #char "\n");
        r.text = rest;
        line = strip_comments(r, line);
        line = trim(line);
        if line {
            r.line = line;
            return true;
        }
    }
    r.line = "";
    return false;
}

strip_comments :: (r: *Reader, line: string) -> string {
    if !r.block_comments {
        found, before := split_from_left(line, #char "#");
        return ifx found then before else line;
    }
    // Block comments may span lines; what's outside them stays. Only the part before the
    // first comment of any kind is kept on a line, which is all the files need.
    s := line;
    if r.in_block {
        found, _, after := split_from_left(s, "*/");
        if !found return "";
        r.in_block = false;
        s = after;
    }
    for i: 0..s.count-1 {
        c := s[i];
        if c == #char "#" { s.count = i; break; }
        if c == #char "/" && i + 1 < s.count {
            if s[i + 1] == #char "/" { s.count = i; break; }
            if s[i + 1] == #char "*" {
                rest := advance(s, i + 2);
                found, _, after := split_from_left(rest, "*/");
                if !found r.in_block = true;
                s.count = i;
                break;
            }
        }
    }
    return s;
}

// Tokens split at white space, a colon ending a token: "X: 252.00" and "X:252.00" both give
// "X:" then "252.00".
Tokens :: struct {
    items: [64] string;
    count: int;
}

split_tokens :: (line: string) -> Tokens {
    t: Tokens;
    s := line;
    while s && t.count < t.items.count {
        while s && (s[0] == #char " " || s[0] == #char "\t" || s[0] == #char "\r")  advance(*s);
        if !s break;
        start := s;
        while s && s[0] != #char " " && s[0] != #char "\t" && s[0] != #char "\r" {
            colon := s[0] == #char ":";
            advance(*s);
            if colon break;
        }
        token := start;
        token.count = start.count - s.count;
        t.items[t.count] = token;
        t.count += 1;
    }
    return t;
}

// The n tokens after the keyword, or nothing when it's missing or there are fewer.
get_after :: (t: *Tokens, keyword: string, n: int) -> [] string {
    for i: 0..t.count-1 {
        if !equal_nocase(t.items[i], keyword) continue;
        if i + n >= t.count return .[];
        result: [] string;
        result.data  = t.items.data + i + 1;
        result.count = n;
        return result;
    }
    return .[];
}

match_count :: (line: string, keyword: string) -> int, bool {
    t := split_tokens(line);
    if t.count < 2 || !equal_nocase(t.items[0], keyword) return 0, false;
    value, ok := string_to_int(t.items[1]);
    return value, ok;
}

// The value after the line's leading keyword(s): "AMBIENT 20", "FLOOR ALTITUDE 0.00".
match_keyword :: (line: string, keyword: string) -> string, bool {
    if !begins_with_nocase(line, keyword) return "", false;
    rest := advance(line, keyword.count);
    if rest && rest[0] != #char " " && rest[0] != #char "\t" return "", false;
    return trim(rest), true;
}

to_fixed :: fixed_from_text;

// Degrees to angle units, as the original reads them (0x15016): the float times 45.5111 (not
// quite 16384 / 360, so 90 degrees is 4095), truncated, kept in 16 bits.
angle_from_text :: (s: string) -> s32 {
    f, ok := string_to_float64(s);
    if !ok return 0;
    return cast,no_check(s16) cast,no_check(s32) (cast(float64) cast(float32) f * 45.5111);
}

to_int :: (s: string) -> s32 {
    value, ok := string_to_int(s);
    return ifx ok then cast,trunc(s32) value else 0;
}

is_integer :: (s: string) -> bool {
    _, ok := string_to_int(s);
    return ok;
}

parse_flat :: (flat: *Flat, values: string) {
    t := split_tokens(values);
    if t.count >= 1  flat.texture = to_int(t.items[0]);
    if t.count >= 3  flat.offset = .{to_fixed(t.items[1]), to_fixed(t.items[2])};
}

// "idx offset_x offset_y" in world units, kept in texels, 8 to a unit.
parse_wall_texture :: (t: *Tokens, keyword: string) -> Wall_Texture {
    result: Wall_Texture;
    values := get_after(t, keyword, 3);
    if !values return result;
    result.texture = to_int(values[0]);
    result.offset  = .{to_fixed(values[1]) << 3, to_fixed(values[2]) << 3};
    return result;
}

parse_lev :: (level: *Level, text: string) -> bool {
    r := Reader.{text = text};
    if !next_line(*r) || !begins_with_nocase(r.line, "LEV") return false;

    // Header lines, in order; MUSIC is optional.
    for 1..8 {
        if !next_line(*r) return false;
        value, ok := match_keyword(r.line, "LEVELNAME");
        if ok { level.name = copy_string(value); continue; }
        value, ok = match_keyword(r.line, "PALETTE");
        if ok { level.palette = to_upper_copy(value); continue; }
        value, ok = match_keyword(r.line, "MUSIC");
        if ok { level.music = to_upper_copy(value); continue; }
        value, ok = match_keyword(r.line, "PARALLAX");
        if ok {
            t := split_tokens(value);
            if t.count >= 2  level.parallax = .[to_fixed(t.items[0]), to_fixed(t.items[1])];
            continue;
        }
        break;
    }

    count, ok := match_count(r.line, "TEXTURES");
    if !ok return false;
    for 1..count {
        if !next_line(*r) return false;
        value, found := match_keyword(r.line, "TEXTURE:");
        if !found return false;
        name := split_tokens(value).items[0];
        if equal_nocase(name, "<NoTexture>")  array_add(*level.textures, "");
        else array_add(*level.textures, to_upper_copy(name));
    }

    if !next_line(*r) return false;
    count, ok = match_count(r.line, "NUMSECTORS");
    if !ok return false;
    array_reserve(*level.sectors, count);
    for 1..count {
        if !next_line(*r) return false;
        id, is_sector := match_count(r.line, "SECTOR");
        if !is_sector return false;
        sector := array_add(*level.sectors);
        sector.id = xx id;
        if !parse_sector(*r, sector) return false;
    }

    link_adjoins(level);
    for * sector: level.sectors {
        for * sector.walls  level_update_wall_shape(sector, it);
        level_update_wall_parts(level, sector);
        level_update_collision_heights(sector);
        level_update_bounds(sector);
    }
    return true;
}

parse_sector :: (r: *Reader, sector: *Sector) -> bool {
    vertex_count, wall_count := -1, -1;
    while vertex_count < 0 {
        if !next_line(r) return false;
        line := r.line;
        if equal_nocase(line, "NAME") continue;
        value, ok := match_keyword(line, "NAME");
        if ok { sector.name = copy_string(value); continue; }
        value, ok = match_keyword(line, "AMBIENT");
        if ok { sector.ambient = to_int(value) << 16; continue; }
        value, ok = match_keyword(line, "FLOOR TEXTURE");
        if ok { parse_flat(*sector.floor, value); continue; }
        value, ok = match_keyword(line, "FLOOR ALTITUDE");
        if ok { sector.floor.altitude = to_fixed(value); continue; }
        value, ok = match_keyword(line, "CEILING TEXTURE");
        if ok { parse_flat(*sector.ceiling, value); continue; }
        value, ok = match_keyword(line, "CEILING ALTITUDE");
        if ok { sector.ceiling.altitude = to_fixed(value); continue; }
        value, ok = match_keyword(line, "SECOND ALTITUDE");
        if ok { sector.second_altitude = to_fixed(value); continue; }
        value, ok = match_keyword(line, "FLAGS");
        if ok {
            t := split_tokens(value);
            for 0..min(t.count, 3)-1  sector.flags[it] = xx to_int(t.items[it]);
            continue;
        }
        value, ok = match_keyword(line, "LAYER");
        if ok { sector.layer = to_int(value); continue; }
        count, is_count := match_count(line, "VERTICES");
        if is_count { vertex_count = count; break; }
        return false;
    }
    for 1..vertex_count {
        if !next_line(r) return false;
        t := split_tokens(r.line);
        x := get_after(*t, "X:", 1);
        z := get_after(*t, "Z:", 1);
        if !x || !z return false;
        array_add(*sector.vertices, .{to_fixed(x[0]), to_fixed(z[0])});
    }

    if !next_line(r) return false;
    count, ok := match_count(r.line, "WALLS");
    if !ok return false;
    for 1..count {
        if !next_line(r) return false;
        t := split_tokens(r.line);
        if !t.count || !equal_nocase(t.items[0], "WALL") return false;
        wall := array_add(*sector.walls);
        left  := get_after(*t, "LEFT:", 1);
        right := get_after(*t, "RIGHT:", 1);
        if !left || !right return false;
        wall.left  = to_int(left[0]);
        wall.right = to_int(right[0]);
        if wall.left < 0 || wall.left >= sector.vertices.count || wall.right < 0 || wall.right >= sector.vertices.count return false;
        wall.mid    = parse_wall_texture(*t, "MID:");
        wall.top    = parse_wall_texture(*t, "TOP:");
        wall.bottom = parse_wall_texture(*t, "BOT:");
        wall.sign   = parse_wall_texture(*t, "SIGN:");
        adjoin := get_after(*t, "ADJOIN:", 1);
        mirror := get_after(*t, "MIRROR:", 1);
        walk   := get_after(*t, "WALK:", 1);
        if adjoin  wall.adjoin = to_int(adjoin[0]);
        if mirror  wall.mirror = to_int(mirror[0]);
        if walk    wall.walk   = to_int(walk[0]);
        flags := get_after(*t, "FLAGS:", 3);
        for flags  wall.flags[it_index] = xx to_int(it);
        light := get_after(*t, "LIGHT:", 1);
        // Read whole and kept as 16 bits: 65534 is -2.
        if light {
            l: s32 = cast,no_check(s16) (to_int(light[0]) & 0xFFFF);
            wall.light = l << 16;
        }
    }
    return true;
}

// An adjoin whose mirror isn't a wall back to this one is dropped. The two sides of a wall
// share their third flags word's low bits (solid, walkable).
link_adjoins :: (level: *Level) {
    for * sector, sector_index: level.sectors {
        for * wall: sector.walls {
            if wall.adjoin < 0 continue;
            if wall.adjoin >= level.sectors.count || wall.mirror < 0 || wall.mirror >= level.sectors[wall.adjoin].walls.count {
                wall.adjoin, wall.mirror = -1, -1;
                continue;
            }
            mirror := *level.sectors[wall.adjoin].walls[wall.mirror];
            shared := (wall.flags[2] | mirror.flags[2]) & 0xF;
            wall.flags[2]   |= shared;
            mirror.flags[2] |= shared;
        }
    }
}

parse_o :: (objects: *Level_Objects, text: string) -> bool {
    r := Reader.{text = text, block_comments = true};
    if !next_line(*r) || !begins_with_nocase(r.line, "O") return false;

    have_line := false;
    last_difficulty: s32;
    while true {
        if !have_line && !next_line(*r) break;
        have_line = false;
        line := r.line;

        list: *[..] string;
        keyword: string;
        count, ok := match_count(line, "PODS");
        if ok { list = *objects.pods; keyword = "POD:"; }
        if !list { count, ok = match_count(line, "SPRS");   if ok { list = *objects.sprites; keyword = "SPR:"; } }
        if !list { count, ok = match_count(line, "FMES");   if ok { list = *objects.frames;  keyword = "FME:"; } }
        if !list { count, ok = match_count(line, "SOUNDS"); if ok { list = *objects.sounds;  keyword = "SOUND:"; } }
        if list {
            for 1..count {
                if !next_line(*r) return false;
                value, found := match_keyword(r.line, keyword);
                if !found { have_line = true; break; }
                array_add(list, to_upper_copy(split_tokens(value).items[0]));
            }
            continue;
        }

        t := split_tokens(line);
        if !t.count || !equal_nocase(t.items[0], "CLASS:") continue;
        object := array_add(*objects.objects);
        class := get_after(*t, "CLASS:", 1);
        if class {
            c := class[0];
            if      equal_nocase(c, "SPRITE") object.class = .SPRITE;
            else if equal_nocase(c, "FRAME")  object.class = .FRAME;
            else if equal_nocase(c, "3D")     object.class = .MODEL;
            else if equal_nocase(c, "SOUND")  object.class = .SOUND;
            else if equal_nocase(c, "SAFE")   object.class = .SAFE;
            else object.class = .SPIRIT;
        }
        get_number :: (t: *Tokens, keyword: string) -> Fixed {
            value := get_after(t, keyword, 1);
            return ifx value then to_fixed(value[0]) else 0;
        }
        data := get_after(*t, "DATA:", 1);
        if data  object.data = to_int(data[0]);
        object.position = .{get_number(*t, "X:"), get_number(*t, "Y:"), get_number(*t, "Z:")};
        get_angle :: (t: *Tokens, keyword: string) -> s32 {
            value := get_after(t, keyword, 1);
            return ifx value then angle_from_text(value[0]) else 0;
        }
        object.pitch = get_angle(*t, "PCH:");
        object.yaw   = get_angle(*t, "YAW:");
        object.roll  = get_angle(*t, "ROL:");
        // A line without DIFF: keeps the last one's: the original's variable is never reset
        // (0x14aaf).
        diff := get_after(*t, "DIFF:", 1);
        if diff  last_difficulty = to_int(diff[0]);
        object.difficulty = last_difficulty;

        // The logic block, if the next line starts one; otherwise that line is the next object.
        if !next_line(*r) break;
        if !equal_nocase(split_tokens(r.line).items[0], "SEQ") { have_line = true; continue; }
        while next_line(*r) {
            s := split_tokens(r.line);
            if !s.count continue;
            key := s.items[0];
            if equal_nocase(key, "SEQEND") break;
            if (equal_nocase(key, "LOGIC:") || equal_nocase(key, "TYPE:")) && s.count > 1 {
                words := s.items[1];
                if s.count > 2  words = join(s.items[1], " ", s.items[2],, temp);
                array_add(*object.logics, to_upper_copy(words));
            } else if equal_nocase(key, "EYE:") && s.count > 1 {
                object.eye = equal_nocase(s.items[1], "TRUE");
            } else if equal_nocase(key, "RADIUS:") && s.count > 1 {
                object.radius = to_fixed(s.items[1]);
            } else if equal_nocase(key, "HEIGHT:") && s.count > 1 {
                object.height = to_fixed(s.items[1]);
            } else if (equal_nocase(key, "VUE:") || equal_nocase(key, "VUE_APPEND:")) && s.count > 1 {
                // Without a name, every object in the file (0x2fe07).
                name := ifx s.count > 2 then s.items[2] else "*";
                array_add(*object.vues, .{to_upper_copy(s.items[1]), to_upper_copy(name), equal_nocase(key, "VUE_APPEND:")});
            } else if equal_nocase(key, "FRAME_RATE:") && s.count > 1 {
                object.frame_rate = string_to_float64(s.items[1]);
            } else if equal_nocase(key, "PAUSE:") {
                object.pause = true;
            } else {
                value := ifx s.count > 1 then copy_string(s.items[1]) else "";
                array_add(*object.params, .{to_upper_copy(key), value, cast(s32) object.logics.count - 1});
            }
        }
    }
    return true;
}

to_upper_copy :: (s: string) -> string {
    result := copy_string(s);
    to_upper_in_place(result);
    return result;
}

// Which side of the wall from a to b the point is on, for a ray toward +x (0x57dc8): 1 when
// the wall crosses the ray, 0 when the point is on the wall, -1 otherwise.
get_edge_crossing :: (px: Fixed, pz: Fixed, a: Fixed2, b: Fixed2) -> s32 {
    x0, z0, x1, z1 := a.x, a.z, b.x, b.z;
    dx := x0 - x1;
    dz := z0 - z1;
    if dx == 0 {
        if dz < 1 { if pz < z0 || z1 < pz || x0 < px return -1; }
        else      { if pz < z1 || z0 < pz || x0 < px return -1; }
        if px == x0 return 0;
    } else if dz == 0 {
        if pz != z0 return -1;
        if dx < 1 { if x1 < px return -1; if x0 <= px return 0; }
        else      { if x0 < px return -1; if x1 <= px return 0; }
    } else {
        if dx < 1 {
            if x1 < px return -1;
            px -= x0;
            dx = -dx;
            if dz < 1 { if pz < z0 || z1 < pz return -1; dz = -dz; pz -= z0; }
            else      { if pz < z1 || z0 < pz return -1; pz = z0 - pz; }
        } else {
            if x0 < px return -1;
            px -= x1;
            if dz < 1 { if pz < z0 || z1 < pz return -1; pz = z1 - pz; dz = -dz; }
            else      { if pz < z1 || z0 < pz return -1; pz -= z1; }
        }
        a := mul16(pz, dx);
        b := mul16(px, dz);
        if a == b return 0;
        if a < b return -1;
    }
    return 1;
}

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfFixed";
