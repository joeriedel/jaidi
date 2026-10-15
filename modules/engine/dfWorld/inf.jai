// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// INF: the level's machinery, as DARK.EXE runs it. A level's .INF file gives sectors
// elevators (anything that moves a sector's floor, ceiling, second height, walls, light or
// textures through a list of stops), triggers (walls and sectors that send messages when the
// player crosses, enters or nudges them), and teleporters. Doors are elevators too, made for
// sectors flagged DOOR (and exploding walls for the flag that says so).
//
// Things happen by messages carried over links: a sector or wall has a list of links to
// elevators, triggers and teleporters, each with the events and entities it answers to.
// An event (the player crossing a line, entering a sector, pressing use at a wall, landing)
// goes to the links that want it; a trigger passes its message on to its clients; an
// elevator's stop sends its messages when the elevator gets there.
//
// The parser follows 0x1638d, the elevators 0x3586c, 0x34e40 and the elevator task 0x35e70,
// messages 0x36bf8, triggers 0x37538 and 0x3776c, teleporters 0x37b80. Numbers are read with
// strtod and truncated into 16.16, as the original reads them.

world_get_inf_counts :: () -> elevators: int, triggers: int, teleports: int {
    inf := *world.inf;
    elevators, triggers := 0, 0;
    for inf.elevators  if it.alive  elevators += 1;
    for inf.triggers   if it.alive  triggers += 1;
    return elevators, triggers, inf.teleports.count;
}

// What an INF message does to a sector itself, for tests and tools.
world_send_sector_message :: (sector: s32, type: Inf_Message_Type) {
    send_sector_message(sector, type);
}

// An INF message to a sector and to the elevators and triggers it links, as a stop's message
// without an event sends one, for tests and tools.
world_send_inf_message :: (sector: s32, type: Inf_Message_Type) {
    send_to_sector(sector, 0, 0, type);
}

// For tests: where a wall's sign answers, without the half unit about it: the distance along
// the wall from its left end, and the heights of its top and bottom. False for no sign.
world_get_sign_box :: (sector_index: s32, wall: s32) -> bool, along_min: Fixed, along_max: Fixed, top: Fixed, bottom: Fixed {
    w := *world.level.sectors[sector_index].walls[wall];
    if w.sign.texture < 0 || w.sign.texture >= world.textures.count || !world.textures[w.sign.texture].frames return false, 0, 0, 0, 0;
    image := *world.textures[w.sign.texture].frames[0];
    u, base := get_sign_origin(sector_index, w);
    along := (w.sign.offset.x - u) >> 3;
    bottom := base + (w.sign.offset.z >> 3);
    return true, along, along + (image.width << 13), bottom - (image.height << 13), bottom;
}

// For tests: the frame a switch's sign shows.
world_get_switch_frame :: (sector: s32, wall: s32) -> s32 { return get_switch_frame(sector, wall); }

#scope_module

Elevator_Type :: enum s32 {
    MOVE_CEILING; MOVE_FLOOR; MOVE_OFFSET; MOVE_WALL; ROTATE_WALL; SCROLL_WALL; SCROLL_FLOOR;
    SCROLL_CEILING; CHANGE_LIGHT; MOVE_FC; CHANGE_WALL_LIGHT;
}

// What a trigger does to an elevator that isn't moving (0x36bf8). The kinds that set none,
// the lights, keep the original's -1, which its handler takes as TRIGGER_NEXT.
TRIGGER_CONT :: 0;      // Go on to its next stop.
TRIGGER_LAST :: 1;      // Go to its last stop.
TRIGGER_NEXT :: 2;      // The next stop, unless waiting at one.
TRIGGER_PREV :: 3;

ELEVATOR_MOVING    :: 1;
ELEVATOR_MASTER_ON :: 2;
ELEVATOR_CRUSH     :: 4;

// Elevator flags (FLAGS:): what the elevator carries with it.
ELEVATOR_MOVES_FLOOR  :: 1;
ELEVATOR_MOVES_SECOND :: 2;
ELEVATOR_MOVES_CEILING :: 4;
ELEVATOR_DOOR         :: 8;     // Made for a DOOR sector.

DELAY_HOLD      :: -1;
DELAY_TERMINATE :: -2;
DELAY_COMPLETE  :: -3;
SLEEP :: 0x7FFF_FFFF;           // An elevator holding waits for a message.

Inf_Message_Type :: enum s32 {
    TRIGGER; NEXT_STOP; PREV_STOP; GOTO_STOP; MASTER_ON; MASTER_OFF; SET_BITS; CLEAR_BITS;
    COMPLETE; LIGHTS; DONE; WAKEUP; CRUSH;
}

EVENT_CROSS_FRONT :: 0x1;
EVENT_CROSS_BACK  :: 0x2;
EVENT_ENTER       :: 0x4;
EVENT_LEAVE       :: 0x8;
EVENT_NUDGE_FRONT :: 0x10;
EVENT_NUDGE_BACK  :: 0x20;
EVENT_EXPLOSION   :: 0x40;
EVENT_SHOOT       :: 0x100;
EVENT_LAND        :: 0x200;
EVENT_INTERNAL    :: 0x8000_0000;
EVENT_ANY         :: 0xFFFF_FFFF;


KEY_RED    :: 23;
KEY_YELLOW :: 24;
KEY_BLUE   :: 25;

Link_Type :: enum s32 { ELEVATOR; TRIGGER; TELEPORT; }

Inf_Link :: struct {
    type: Link_Type;
    target: s32;                // Into the elevators, triggers or teleports.
    event_mask: u32;
    entity_mask: u32 = ENTITY_PLAYER;
    alive := true;
}

// A message's address: a sector, a wall of one, or neither ("system").
Inf_Target :: struct {
    sector: s32 = -1;
    wall: s32 = -1;             // With sector: that sector's wall.
}

Inf_Message :: struct {
    target: Inf_Target;
    type: Inf_Message_Type;
    event: u32;
    arg1, arg2: u32;
}

Adjoin_Command :: struct {
    sector0, wall0, sector1, wall1: s32;
}

Stop :: struct {
    value: Fixed;
    delay: s32 = 0x246;         // Ticks: 4 seconds.
    messages: [..] Inf_Message;
    adjoins: [..] Adjoin_Command;
    page: Sound_Handle;
    floor_texture, ceiling_texture: s32 = -2;     // -2 for no change.
}

Slave :: struct {
    sector: s32;
    value: s32;                 // An angle offset, for rotations.
}

Elevator :: struct {
    type: Elevator_Type;
    trigger_move: s32 = TRIGGER_NEXT;
    sector: s32;
    key: s32;
    fixed_step: Fixed;
    next_tick: s32;
    stops: [..] Stop;
    iter: s32 = -1;             // The stop list's place, as the original's list keeps one.
    slaves: [..] Slave;
    next_stop: s32 = -1;
    speed: Fixed;
    own_value: Fixed;           // For the kinds that move no sector value of their own.
    previous_angle: s32;
    direction: Fixed2;          // Its direction, or the center it turns about.
    flags: u32;
    sounds: [3] Sound_Handle;   // Starting, moving, stopping.
    looping: Sound_Instance;
    update_flags: u32 = ELEVATOR_MASTER_ON;
    alive := true;
}

Trigger_Type :: enum s32 { WALL; SECTOR; SWITCH1; TOGGLE; SINGLE; }

Trigger_Target :: struct {
    target: Inf_Target;
    event_mask: u32 = EVENT_ANY;
}

Trigger :: struct {
    type: Trigger_Type;
    link_sector: s32 = -1;      // Where its link is: a sector, or a wall of it.
    link_wall: s32 = -1;
    link: s32;
    targets: [..] Trigger_Target;
    command: Inf_Message_Type;
    event: u32;
    args: [2] u32;
    master := true;
    sound: Sound_Handle;
    switch_frames: s32;         // An animated sign's frame count (a switch), or 0.
    state: s32;
    text: s32;                  // A TEXT.MSG message to show.
    alive := true;
}

Teleport :: struct {
    sector, target: s32;
    chute: bool;
    destination: Fixed3;
    yaw: s32;
}

Sector_Turn :: struct {
    angle: s32;
    center: Fixed2;
    turned: bool;
}

Inf_State :: struct {
    elevators: [..] Elevator;
    triggers: [..] Trigger;
    teleports: [..] Teleport;
    links: [..] Inf_Link;
    sector_links: [..] [..] s32;    // By sector, into links.
    wall_links: [..] [..] s32;      // By wall_first[sector] + wall.
    wall_first: [..] s32;
    original_vertices: [..] [..] Fixed2;    // Where rotating walls turn from.
    turns: [..] Sector_Turn;        // By sector: how far a sector whose every wall turns has
                                    // turned, for Enhanced Mode's flats (draw_flat).
    player_walls_moved: bool;   // A wall of the player's sector moved (0xfe374).

    // The message being handled, as the original's globals carry it.
    msg_event: u32;
    msg_arg1, msg_arg2: u32;
    msg_entity: u32;            // The entity's flags; 0 for none.

    complete_sector: s32 = -1;  // The sector named "complete", told of objectives.
    boss_sector: s32 = -1;      // "boss", told when a boss dies,
    mohc_sector: s32 = -1;      // and "mohc", when General Mohc does.
    level_sounds: [..] Level_Sound_Line;    // The level item's amb_sound lines.
    sounds: struct {
        ceiling: [3] Sound_Handle;
        floor: [3] Sound_Handle;
        door, locked, switch_: Sound_Handle;
    };
}

Level_Sound_Line :: struct {
    name: string;
    seconds: float64;
    priority: s32;
}

load_inf :: () {
    inf := *world.inf;
    sector_count := world.level.sectors.count;
    array_resize(*inf.sector_links, sector_count);
    array_resize(*inf.wall_first, sector_count);
    walls := 0;
    for * world.level.sectors {
        inf.wall_first[it_index] = xx walls;
        walls += it.walls.count;
    }
    array_resize(*inf.wall_links, walls);
    array_resize(*inf.original_vertices, sector_count);
    for * world.level.sectors  array_copy(*inf.original_vertices[it_index], it.vertices);
    array_resize(*inf.turns, sector_count);

    // The default sounds (0x34c30, 0x374e0).
    s := *inf.sounds;
    s.ceiling = .[register_sound("DOOR2-1.VOC", 0xC), register_sound("DOOR2-2.VOC", 0xC), register_sound("DOOR2-3.VOC", 0xC)];
    s.floor   = .[register_sound("ELEV2-1.VOC", 0xC), register_sound("ELEV2-2.VOC", 0xC), register_sound("ELEV2-3.VOC", 0xC)];
    s.door    = register_sound("DOOR.VOC", 0xC);
    s.locked  = register_sound("LOCKED-1.VOC", 0xC);
    s.switch_ = register_sound("SWITCH3.VOC", 0x6F);

    // Doors and exploding walls from the sectors' flags (the sector loader, 0x140c9).
    for * world.level.sectors {
        index: s32 = xx it_index;
        if it.flags[0] & SECTOR_DOOR {
            e := create_special_elevator(index, .DOOR);
            if e  e.flags |= ELEVATOR_DOOR;
        }
        if it.flags[0] & SECTOR_EXPLODING_WALL  create_special_elevator(index, .EXPLOSIVE_WALL);
    }

    data, found := gob_find(tprint("%.INF", world.name));
    if found  parse_inf(cast(string) data);

    for * world.level.sectors {
        if equal_nocase(it.name, "COMPLETE")   inf.complete_sector = xx it_index;
        else if equal_nocase(it.name, "BOSS")  inf.boss_sector = xx it_index;
        else if equal_nocase(it.name, "MOHC")  inf.mohc_sector = xx it_index;
    }
}

unload_inf :: () {
    inf := *world.inf;
    for * inf.elevators {
        for * s: it.stops { array_free(s.messages); array_free(s.adjoins); }
        array_free(it.stops);
        array_free(it.slaves);
    }
    for * inf.triggers  array_free(it.targets);
    for inf.level_sounds  free(it.name);
    array_free(inf.level_sounds);
    array_free(inf.elevators);
    array_free(inf.triggers);
    array_free(inf.teleports);
    array_free(inf.links);
    for * inf.sector_links  array_free(it.*);
    for * inf.wall_links  array_free(it.*);
    for * inf.original_vertices  array_free(it.*);
    array_free(inf.sector_links);
    array_free(inf.wall_links);
    array_free(inf.wall_first);
    array_free(inf.original_vertices);
    array_free(inf.turns);
    inf.* = .{};
}

// Once a frame (0x35e70): each elevator whose time has come moves, and on reaching a stop
// waits there, deletes itself, or completes the mission, then does what the stop says.
update_elevators :: () {
    inf := *world.inf;
    tick := world.clock.tick;
    for i: 0..inf.elevators.count-1 {
        e := *inf.elevators[i];
        if !e.alive || !(e.update_flags & ELEVATOR_MASTER_ON) || e.next_tick >= tick continue;
        if !(e.update_flags & ELEVATOR_MOVING)  start_elevator(e);
        if e.update_flags & ELEVATOR_MOVING  e.looping = maintain_sound(e.looping, e.sounds[1], get_elevator_sound_position(e));
        if !update_elevator(e) continue;

        handle_stop_delay(e);
        stop_index := e.next_stop;
        stop := *e.stops[stop_index];
        deleted := false;
        if e.update_flags & ELEVATOR_CRUSH {
            e.next_tick = tick + 145;
            e.update_flags &= ~cast(u32) ELEVATOR_CRUSH;
        } else if stop.delay == DELAY_HOLD {
            e.next_tick = SLEEP;
        } else if stop.delay == DELAY_COMPLETE || stop.delay == DELAY_TERMINATE {
            // Deleted without the stop's messages; COMPLETE then ends the mission.
            complete := stop.delay == DELAY_COMPLETE;
            delete_elevator(e);
            if complete  complete_mission();
            deleted = true;
        } else {
            e.next_tick = tick + stop.delay;
        }
        if deleted continue;

        send_stop_messages(e, stop_index);
        e = *inf.elevators[i];
        stop = *e.stops[stop_index];
        run_adjoin_commands(stop);
        sector := *world.level.sectors[e.sector];
        if stop.floor_texture != -2    sector.floor.texture = stop.floor_texture;
        if stop.ceiling_texture != -2  sector.ceiling.texture = stop.ceiling_texture;
        if stop.page  play_sound(stop.page);
        e.next_stop = advance_stops(e, 0, 1);
    }
}

// Teleporters: anything in a teleporter's sector goes (0x37b80). Only the player can be
// there yet.
update_teleports :: () {
    inf := *world.inf;
    p := *world.player;
    for * t: inf.teleports {
        if p.sector != t.sector || t.target < 0 continue;
        if !t.chute {
            p.position = t.destination;
            p.object_yaw = t.yaw;
            change_player_sector(p, t.target);
        } else if world.level.sectors[t.sector].floor.altitude - FIXED_HALF < p.position.y {
            change_player_sector(p, t.target);
        }
    }
}

// The player entering a sector, or leaving one (0x59ec4, 0x59fdc).
send_sector_events :: (from: s32, to: s32) {
    if world.player_state.dying return;
    if from >= 0  send_to_sector(from, ENTITY_PLAYER, EVENT_LEAVE, .TRIGGER);
    if to >= 0    send_to_sector(to, ENTITY_PLAYER, EVENT_ENTER, .TRIGGER);
}

// A wall crossed by the player: its front, and its mirror's back (0x56c4c).
send_wall_crossed :: (sector: s32, wall: s32) {
    send_to_wall(sector, wall, ENTITY_PLAYER, EVENT_CROSS_FRONT, .TRIGGER);
    w := *world.level.sectors[sector].walls[wall];
    if w.adjoin >= 0 && w.mirror >= 0  send_to_wall(w.adjoin, w.mirror, ENTITY_PLAYER, EVENT_CROSS_BACK, .TRIGGER);
}

// A wall's line crossed by an object other than the player (0x56c4c): the wall gets the
// event, its mirror the event for its back. Links match the object by its entity flags, so
// an object with none sets nothing off.
send_wall_crossed_by :: (entity: u32, sector: s32, wall: *Wall, event: u32) {
    if !entity return;
    send_to_wall(sector, get_wall_index(sector, wall), entity, event, .TRIGGER);
    if wall.adjoin >= 0 && wall.mirror >= 0  send_to_wall(wall.adjoin, wall.mirror, entity, event * 2, .TRIGGER);
}

// An object leaving a sector and entering another (0x59ec4).
send_object_sector_events :: (entity: u32, from: s32, to: s32) {
    if !entity return;
    if from >= 0  send_to_sector(from, entity, EVENT_LEAVE, .TRIGGER);
    if to >= 0    send_to_sector(to, entity, EVENT_ENTER, .TRIGGER);
}

// A smart object meeting a wall tells the sector behind it, to open a door (0x5af2c).
send_object_trigger :: (sector: s32, entity: u32) {
    send_to_sector(sector, entity, 0, .TRIGGER);
}

// A shot hitting a wall tells it where it hit, from the shot's entity (0x49xxx, 0x56b34).
send_wall_shot :: (sector: s32, wall: *Wall, entity: u32, at: Fixed3) {
    send_wall_event_at(sector, wall, at.x, at.z, at.y, entity, EVENT_SHOOT);
}

get_wall_index :: (sector: s32, wall: *Wall) -> s32 {
    walls := world.level.sectors[sector].walls;
    return cast(s32) ((cast(*u8) wall - cast(*u8) walls.data) / size_of(Wall));
}

// The player landing (0x2d17c).
send_landed :: (sector: s32) {
    send_to_sector(sector, ENTITY_PLAYER, EVENT_LAND, .TRIGGER);
}

// An explosion near the sector (0x5ce74, 0x5cee4).
send_explosion :: (sector: s32) {
    send_to_sector(sector, 0, EVENT_EXPLOSION, .TRIGGER);
}

// An objective picked up tells the "complete" sector.
send_objective_taken :: () {
    inf := *world.inf;
    if inf.complete_sector >= 0  send_to_sector(inf.complete_sector, 0, 0, .TRIGGER);
}

// A boss dead (0x2693c): one marked BOSS: in the O file tells the "boss" sector, or General
// Mohc the "mohc" sector.
send_boss_killed :: (o: *Object) {
    if !(o.flags & OBJECT_BOSS) return;
    inf := *world.inf;
    sector := ifx o.entity & ENTITY_MOHC then inf.mohc_sector else inf.boss_sector;
    if sector >= 0  send_to_sector(sector, 0, 0, .TRIGGER);
}

// The use key (0x2ea9c): the player's sector, nudged from inside; then a ray four units
// ahead: the wall it meets nudged at the point it meets it, the sector behind nudged from
// outside, and on through openings the eye fits.
use_key :: (p: *Player) {
    send_to_sector(p.sector, ENTITY_PLAYER, EVENT_NUDGE_FRONT, .TRIGGER);
    s, c := sin_cos(p.object_yaw);
    x1 := p.position.x + mul16(s, 4 * FIXED_ONE);
    z1 := p.position.z + mul16(c, 4 * FIXED_ONE);
    wall, sector := find_path_wall(p.sector, p.position.x, p.position.z, x1, z1);
    if !wall return;
    eye := p.position.y - p.height;
    hit_x, hit_z := get_path_hit();
    send_wall_event_at(sector, wall, hit_x, hit_z, eye, ENTITY_PLAYER, EVENT_NUDGE_FRONT);
    if wall.adjoin < 0 return;
    next := wall.adjoin;
    send_to_sector(next, ENTITY_PLAYER, EVENT_NUDGE_BACK, .TRIGGER);
    nudged := path_frame_now();
    world.level.sectors[next].collision_frame = nudged;
    n := *world.level.sectors[next];
    if !(n.ceiling.altitude < eye && eye < n.floor.altitude) return;
    while true {
        wall, sector = find_next_path_wall(next);
        if !wall break;
        hit_x, hit_z = get_path_hit();
        send_wall_event_at(sector, wall, hit_x, hit_z, eye, ENTITY_PLAYER, EVENT_NUDGE_FRONT);
        if wall.adjoin < 0 break;
        next = wall.adjoin;
        n = *world.level.sectors[next];
        if n.collision_frame != nudged {
            send_to_sector(next, ENTITY_PLAYER, EVENT_NUDGE_BACK, .TRIGGER);
            n.collision_frame = nudged;
        }
        if eye < n.ceiling.altitude || n.floor.altitude < eye break;
    }
}

// The player squeezed: the elevators of the sectors it reaches turn back (0x2fbc8).
send_crush :: (c: *Collision, p: *Player) {
    c.dst = .{p.position.x, p.position.z};
    for_each_sector_reached(c, p.sector, (c: *Collision, sector: s32) -> bool {
        send_to_sector(sector, ENTITY_PLAYER, 0, .CRUSH);
        return true;
    });
}

// The elevator that moves the floor or second floor an object stands on: its sector's first
// link, if that's an elevator moving that height (0x4ad84, 0x8ae8c).
get_floor_elevator :: (o: *Object) -> *Elevator {
    links := world.inf.sector_links[o.sector];
    if !links return null;
    link := *world.inf.links[links[0]];
    if link.type != .ELEVATOR || !link.alive return null;
    e := *world.inf.elevators[link.target];
    sector := *world.level.sectors[o.sector];
    on := (o.position.y == sector.floor.altitude && (e.flags & ELEVATOR_MOVES_FLOOR))
       || (sector.floor.altitude + sector.second_altitude == o.position.y && (e.flags & ELEVATOR_MOVES_SECOND));
    return ifx on then e else null;
}

// The horizontal speed of a moving floor under the player (0x35df4): only walls moving and
// floors scrolling carry it.
get_elevator_velocity :: (e: *Elevator) -> Fixed2 {
    if !(e.update_flags & ELEVATOR_MOVING) return .{};
    speed: Fixed = 1;
    if e.next_stop >= 0  speed = e.stops[e.next_stop].value - get_value(e).*;
    if speed == 0 return .{};
    speed = ifx speed >= 0 then e.speed else -e.speed;
    if e.type == .MOVE_WALL || e.type == .SCROLL_FLOOR || e.type == .SCROLL_CEILING {
        return .{mul16(speed, e.direction.x), mul16(speed, e.direction.z)};
    }
    return .{};
}

// The sign frame a switch shows, for a wall.
get_switch_frame :: (sector: s32, wall: s32) -> s32 {
    inf := *world.inf;
    if !inf.wall_first || sector < 0 || sector >= inf.wall_first.count return 0;
    for inf.wall_links[inf.wall_first[sector] + wall] {
        link := *inf.links[it];
        if link.type != .TRIGGER || !link.alive continue;
        t := *inf.triggers[link.target];
        if t.switch_frames return t.state;
    }
    return 0;
}

#scope_file

Special_Elevator :: enum s32 {
    BASIC; BASIC_AUTO; ENCLOSED; MID; INV; DOOR; DOOR_INV; DOOR_MID; MORPH_SPIN1; MORPH_SPIN2;
    MORPH_MOVE1; MORPH_MOVE2; EXPLOSIVE_WALL;
}

// A new elevator of a kind, with its kind's speed, trigger rule and sounds (0x3586c).
create_elevator :: (sector: s32, type: Elevator_Type) -> *Elevator, s32 {
    inf := *world.inf;
    e := array_add(*inf.elevators);
    e.type = type;
    e.sector = sector;
    s := *inf.sounds;
    if type == {
        case .MOVE_CEILING;
            e.speed = 8 * FIXED_ONE;
            e.trigger_move = TRIGGER_LAST;
            e.sounds = s.ceiling;
        case .MOVE_FLOOR; #through;
        case .MOVE_FC;
            e.speed = 8 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.sounds = s.floor;
        case .MOVE_OFFSET;
            e.speed = 8 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.sounds = s.floor;
        case .MOVE_WALL;
            e.speed = 15 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.direction.x, e.direction.z = sin_cos(0);
            e.sounds = s.ceiling;
        case .ROTATE_WALL;
            e.speed = 1024 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.sounds = s.ceiling;
        case .SCROLL_WALL;
            e.speed = 4 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
        case .SCROLL_FLOOR;
            e.speed = 4 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.flags = ELEVATOR_MOVES_FLOOR | ELEVATOR_MOVES_SECOND;
            e.direction.x, e.direction.z = sin_cos(0);
        case .SCROLL_CEILING;
            e.speed = 4 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            e.flags = ELEVATOR_MOVES_CEILING;
            e.direction.x, e.direction.z = sin_cos(0);
        case .CHANGE_LIGHT; #through;
        case .CHANGE_WALL_LIGHT;
            e.speed = 32 * FIXED_ONE;
    }
    return e, xx (inf.elevators.count - 1);
}

add_link :: (list: *[..] s32, type: Link_Type, target: s32, event_mask: u32, entity_mask: u32) -> s32 {
    inf := *world.inf;
    array_add(*inf.links, .{type = type, target = target, event_mask = event_mask, entity_mask = entity_mask});
    index: s32 = xx (inf.links.count - 1);
    array_add(list, index);
    return index;
}

add_elevator_link :: (e_index: s32, sector: s32) -> s32 {
    return add_link(*world.inf.sector_links[sector], .ELEVATOR, e_index, 0, ENTITY_PLAYER);
}

add_stop :: (e: *Elevator, value: Fixed) -> *Stop {
    stop := array_add(*e.stops);
    stop.value = value;
    return stop;
}

// The special kinds: elevators with their stops set up (0x34e40).
NUDGES :: 0xC30;        // Nudges, and two events nothing sends.
create_special_elevator :: (sector_index: s32, type: Special_Elevator) -> *Elevator {
    inf := *world.inf;
    sector := *world.level.sectors[sector_index];
    e: *Elevator;
    index: s32;
    link: s32 = -1;
    entities: u32 = ENTITY_PLAYER | ENTITY_SMART;
    if type == {
        case .BASIC; #through;
        case .INV;
            e, index = create_elevator(sector_index, ifx type == .BASIC then Elevator_Type.MOVE_FLOOR else .MOVE_CEILING);
            link = add_elevator_link(index, sector_index);
            e.trigger_move = TRIGGER_CONT;
            e.speed = 8 * FIXED_ONE;
            set_link(link, NUDGES | EVENT_ENTER, entities);
        case .BASIC_AUTO;
            e, index = create_elevator(sector_index, .MOVE_FLOOR);
            link = add_elevator_link(index, sector_index);
            highest, lowest := -FIXED_INFINITY, FIXED_INFINITY;
            for sector.walls {
                if it.adjoin < 0 continue;
                f := world.level.sectors[it.adjoin].floor.altitude;
                highest = max(highest, f);
                lowest = min(lowest, f);
            }
            if lowest == sector.floor.altitude  highest, lowest = lowest, highest;
            add_stop(e, highest);
            add_stop(e, lowest).delay = DELAY_HOLD;
            e.speed = 8 * FIXED_ONE;
            e.trigger_move = TRIGGER_CONT;
            set_link(link, NUDGES | EVENT_ENTER, entities);
        case .DOOR;
            e, index = create_elevator(sector_index, .MOVE_CEILING);
            link = add_elevator_link(index, sector_index);
            add_stop(e, sector.floor.altitude).delay = DELAY_HOLD;
            add_stop(e, sector.ceiling.altitude);
            e.trigger_move = TRIGGER_LAST;
            e.sounds = .[inf.sounds.door, 0, 0];
            e.speed = 30 * FIXED_ONE;
            set_link(link, NUDGES, entities);
        case .DOOR_INV;
            e, index = create_elevator(sector_index, .MOVE_FLOOR);
            link = add_elevator_link(index, sector_index);
            add_stop(e, sector.ceiling.altitude).delay = DELAY_HOLD;
            add_stop(e, sector.floor.altitude);
            e.trigger_move = TRIGGER_LAST;
            e.speed = 15 * FIXED_ONE;
            set_link(link, NUDGES, entities);
        case .DOOR_MID;
            half := abs(sector.ceiling.altitude - sector.floor.altitude) >> 1;
            middle := sector.floor.altitude - half;
            e, index = create_elevator(sector_index, .MOVE_CEILING);
            link = add_elevator_link(index, sector_index);
            add_stop(e, middle).delay = DELAY_HOLD;
            add_stop(e, sector.ceiling.altitude);
            go_to_initial_stop(index, 0);
            e = *inf.elevators[index];
            e.trigger_move = TRIGGER_LAST;
            e.speed = 15 * FIXED_ONE;
            set_link(link, NUDGES, entities);
            e, index = create_elevator(sector_index, .MOVE_FLOOR);
            link = add_elevator_link(index, sector_index);
            add_stop(e, middle).delay = DELAY_HOLD;
            add_stop(e, sector.floor.altitude);
            e.trigger_move = TRIGGER_LAST;
            e.speed = 15 * FIXED_ONE;
            set_link(link, NUDGES, entities);
        case .MORPH_SPIN1; #through;
        case .MORPH_SPIN2;
            e, index = create_elevator(sector_index, .ROTATE_WALL);
            link = add_elevator_link(index, sector_index);
            set_link(link, EVENT_ANY, entities);
            if type == .MORPH_SPIN2  e.flags = ELEVATOR_MOVES_FLOOR | ELEVATOR_MOVES_SECOND | ELEVATOR_MOVES_CEILING;
        case .MORPH_MOVE1; #through;
        case .MORPH_MOVE2;
            e, index = create_elevator(sector_index, .MOVE_WALL);
            link = add_elevator_link(index, sector_index);
            set_link(link, EVENT_ANY, entities);
            if type == .MORPH_MOVE2  e.flags = ELEVATOR_MOVES_FLOOR | ELEVATOR_MOVES_SECOND | ELEVATOR_MOVES_CEILING;
        case .EXPLOSIVE_WALL;
            e, index = create_elevator(sector_index, .MOVE_CEILING);
            link = add_elevator_link(index, sector_index);
            add_stop(e, sector.floor.altitude).delay = DELAY_HOLD;
            add_stop(e, sector.ceiling.altitude).delay = DELAY_TERMINATE;
            e.trigger_move = TRIGGER_LAST;
            e.speed = 0;
            e.sounds = .[0, 0, 0];
            set_link(link, EVENT_EXPLOSION, 0xFFFF_FFFF);
        case;
            return null;
    }
    go_to_initial_stop(index, 0);
    if index >= inf.elevators.count return null;
    return *inf.elevators[index];
}

set_link :: (link: s32, event_mask: u32, entity_mask: u32) {
    l := *world.inf.links[link];
    l.event_mask = event_mask;
    l.entity_mask = entity_mask;
}

// Puts an elevator at a stop at once and sets it waiting there (0x35c7c).
go_to_initial_stop :: (index: s32, stop: s32) {
    inf := *world.inf;
    e := *inf.elevators[index];
    if !e.stops {
        e.next_tick = world.clock.tick;
        return;
    }
    if stop < 0 || stop >= e.stops.count return;
    e.iter = stop;
    e.next_stop = stop;
    speed, step := e.speed, e.fixed_step;
    e.speed, e.fixed_step = 0, 0;
    dt := world.clock.dt;
    if !world.clock.dt  world.clock.dt = FIXED_ONE;
    update_elevator(e);
    world.clock.dt = dt;
    e.speed, e.fixed_step = speed, step;
    delay := e.stops[e.next_stop].delay;
    if delay == DELAY_TERMINATE {
        delete_elevator(e);
        return;
    }
    e.next_tick = ifx delay == DELAY_HOLD then SLEEP else world.clock.tick + delay;
    e.next_stop = advance_stops(e, 0, 1);
}

// The stop list moved by a number of stops from where it is, or to an absolute stop from
// the first, wrapping both ways; to the last with both 0 and a negative absolute (0x36b60).
advance_stops :: (e: *Elevator, absolute: s32, relative: s32) -> s32 {
    count: s32 = xx e.stops.count;
    if !count return -1;
    if relative > 0 {
        for 1..relative {
            e.iter += 1;
            if e.iter >= count  e.iter = 0;
        }
        return e.iter;
    }
    if relative < 0 {
        for 1..-relative {
            e.iter -= 1;
            if e.iter < 0  e.iter = count - 1;
        }
        return e.iter;
    }
    if absolute >= 0 {
        e.iter = 0;
        for 1..absolute {
            e.iter += 1;
            if e.iter >= count  e.iter = 0;
        }
        return e.iter;
    }
    return count - 1;       // The last, leaving the list's place where it is.
}

delete_elevator :: (e: *Elevator) {
    inf := *world.inf;
    index := cast(s32) (e - inf.elevators.data);
    for l: inf.sector_links[e.sector] {
        link := *inf.links[l];
        if link.type == .ELEVATOR && link.target == index  link.alive = false;
    }
    stop_sound(e.looping);
    e.looping = 0;
    e.alive = false;
}

// Which value an elevator moves.
get_value :: (e: *Elevator) -> *Fixed {
    sector := *world.level.sectors[e.sector];
    if e.type == {
        case .MOVE_CEILING;  return *sector.ceiling.altitude;
        case .MOVE_FLOOR;    #through;
        case .MOVE_FC;       return *sector.floor.altitude;
        case .MOVE_OFFSET;   return *sector.second_altitude;
        case .CHANGE_LIGHT;  return *sector.ambient;
    }
    return *e.own_value;
}

start_elevator :: (e: *Elevator) {
    if e.update_flags & ELEVATOR_MOVING return;
    if e.next_stop >= 0 && get_value(e).* != e.stops[e.next_stop].value {
        play_sound_at(e.sounds[0], get_elevator_sound_position(e));
    }
    e.next_tick = world.clock.tick;
    e.update_flags |= ELEVATOR_MOVING;
}

// Moves an elevator toward its next stop by its speed over the frame (0x36418): true when
// it's there. With no stops it moves on forever (scrolling textures, spinning things).
update_elevator :: (e: *Elevator) -> bool {
    value := get_value(e);
    position := value.*;
    target := position;
    has_stop := e.next_stop >= 0;
    if has_stop  target = e.stops[e.next_stop].value;
    if has_stop && position == target return true;

    delta: Fixed;
    if !has_stop {
        delta = mul16(e.speed, world.clock.dt);
    } else {
        delta = target - position;
        if e.speed {
            if !e.fixed_step {
                move := mul16(e.speed, world.clock.dt);
                if delta > move  delta = move;
                else if delta < -move  delta = -move;
            } else {
                delta = e.speed;
            }
        }
    }

    if e.type == {
        case .MOVE_CEILING; #through;
        case .MOVE_FLOOR;   #through;
        case .MOVE_OFFSET;  #through;
        case .MOVE_FC;      move_heights(e, delta);
        case .MOVE_WALL;    move_walls(e, delta);
        case .ROTATE_WALL;  rotate_walls(e, delta);
        case .SCROLL_WALL;  scroll_walls(e, delta);
        case .SCROLL_FLOOR; #through;
        case .SCROLL_CEILING; scroll_flats(e, delta);
        case .CHANGE_LIGHT;
            for s: get_sectors(e)  world.level.sectors[s].ambient += delta;
        case .CHANGE_WALL_LIGHT;
            e.own_value += delta;
            for s: get_sectors(e) {
                for * w: world.level.sectors[s].walls  if w.flags[0] & WALL_CHANGES_LIGHT  w.light += delta;
            }
    }
    return has_stop && get_value(e).* == target;
}

// The elevator's sector and its slaves'.
get_sectors :: (e: *Elevator) -> [] s32 {
    list := NewArray(e.slaves.count + 1, s32,, temp);
    list[0] = e.sector;
    for e.slaves  list[it_index + 1] = it.sector;
    return list;
}

// Floors, ceilings and second heights (0x365e4). What's in the sector must fit: dead things
// and pickups are cleared out of the way, and if something still doesn't fit (the player,
// mostly), an elevator closing the gap turns back to its last stop, unless the sector is
// flagged to crush.
CRUSH_MARGIN :: 0x4000;
move_heights :: (e: *Elevator, delta: Fixed) {
    sector := *world.level.sectors[e.sector];
    floor_delta, ceiling_delta, second_delta: Fixed;
    if e.type == {
        case .MOVE_CEILING; ceiling_delta = delta;
        case .MOVE_FLOOR;   floor_delta = delta;
        case .MOVE_OFFSET;  second_delta = delta;
        case .MOVE_FC;      floor_delta = delta; ceiling_delta = delta;
    }
    tallest := get_tallest_in_sector(e.sector);
    if tallest {
        tallest += CRUSH_MARGIN;
        if second_delta {
            second := sector.floor.altitude + sector.second_altitude;
            above, below: Fixed;
            remove_clutter(e.sector);
            p := *world.player;
            if p.sector == e.sector {
                h := p.height + FIXED_ONE;
                if p.position.y > second  below = max(below, h);
                else                      above = max(above, h);
            }
            for index: walk_sector(e.sector) {
                t := world.objects[index];
                h := t.height + FIXED_ONE;
                if t.position.y > second  below = max(below, h);
                else                      above = max(above, h);
            }
            second += second_delta;
            room_below := sector.floor.altitude - (second + FIXED_ONE);
            room_above := second - sector.ceiling.altitude;
            if room_below < below || room_above < above {
                e.next_stop = advance_stops(e, 0, -1);
                second_delta = 0;
            }
        } else {
            room := (sector.floor.altitude + floor_delta) - (sector.ceiling.altitude + ceiling_delta);
            if room < tallest {
                remove_clutter(e.sector);
                tallest = get_tallest_in_sector(e.sector);
                if tallest {
                    tallest += CRUSH_MARGIN;
                    if room < tallest && (floor_delta < 0 || ceiling_delta > 0) && !(sector.flags[0] & SECTOR_CRUSHING) {
                        e.next_stop = advance_stops(e, 0, -1);
                        floor_delta, ceiling_delta, second_delta = 0, 0, 0;
                    }
                }
            }
        }
    }
    for s: get_sectors(e) {
        if floor_delta  anchor_wall_textures(s, floor_delta);
        adjust_heights(s, floor_delta, ceiling_delta, second_delta);
    }
}

// The tallest thing in a sector, plus a unit (0x5cf04): 0 for nothing.
get_tallest_in_sector :: (sector: s32) -> Fixed {
    tallest: Fixed;
    p := *world.player;
    if p.sector == sector  tallest = max(tallest, p.height + FIXED_ONE);
    for walk_sector(sector)  tallest = max(tallest, world.objects[it].height + FIXED_ONE);
    return tallest;
}

// Cleared from under a closing elevator (0x5cf44): corpses, kept ones too, pickups that can
// go, and thrown proximity mines. Nothing else in the way is ever crushed: the original sends
// no CRUSH to objects. Its walk (0x5d004) stays on the slot it last gave, so it gives an
// object that stays again and again until its count runs out: only what comes before the
// first that stays, in the sector's slots, is cleared.
remove_clutter :: (sector: s32) {
    seen, slot := 0, 0;
    while true {
        slots := world.sector_objects[sector];
        index: s32 = -1;
        while seen < count_sector_objects(sector) && slot < slots.count {
            if slots[slot] >= 0 { index = slots[slot]; seen += 1; break; }
            slot += 1;
        }
        if index < 0 break;
        t := world.objects[index];
        clutter := (t.entity & ENTITY_CORPSE) || ((t.flags & OBJECT_PICKUP) && !(t.flags & OBJECT_STAYS));
        if !clutter && (t.entity & ENTITY_PROJECTILE) {
            proj := find_projectile(index);
            clutter = proj && proj.type == .LAND_MINE_PROXIMITY;
        }
        if clutter {
            free_object_actor(index);
            free_object_projectile(index);
            free_object(index);
        }
    }
}

// Moves a sector's heights (0x5aa18): what stands on the floor, ceiling or second floor goes
// with it, the player too, its height then the floor's change on the second floor, as the
// original has it; then the collision heights are worked out again.
adjust_heights :: (sector_index: s32, floor_delta: Fixed, ceiling_delta: Fixed, second_delta: Fixed) {
    sector := *world.level.sectors[sector_index];
    both := second_delta + floor_delta;
    move :: (y: *Fixed, sector: *Sector, floor_delta: Fixed, ceiling_delta: Fixed, both: Fixed) {
        if y.* == sector.floor.altitude    y.* += floor_delta;
        if y.* == sector.ceiling.altitude  y.* += ceiling_delta;
        if y.* == sector.floor.altitude + sector.second_altitude  y.* += both;
    }
    for walk_sector(sector_index) {
        move(*world.objects[it].position.y, sector, floor_delta, ceiling_delta, both);
    }
    p := *world.player;
    if p.sector == sector_index {
        y := p.position.y;
        if y == sector.floor.altitude {
            p.position.y += floor_delta;
            p.y += floor_delta;
        }
        if p.position.y == sector.ceiling.altitude {
            p.position.y += ceiling_delta;
            p.y += floor_delta;
        }
        if p.position.y == sector.floor.altitude + sector.second_altitude {
            p.position.y += both;
            p.y += floor_delta;
        }
    }
    sector.ceiling.altitude += ceiling_delta;
    sector.floor.altitude += floor_delta;
    sector.second_altitude += second_delta;
    level_update_collision_heights(sector);
}

// Texture anchors follow a moving floor (0x5a90c, 0x5a96c): an anchored wall's bottom (or
// middle, with no adjoin) and an anchored sign keep their place on it; the same from the
// other side, for the walls that look into the sector.
anchor_wall_textures :: (sector_index: s32, floor_delta: Fixed) {
    sector := *world.level.sectors[sector_index];
    offset := floor_delta * 8;
    for * w: sector.walls {
        if w.flags[0] & WALL_ANCHORED {
            if w.adjoin >= 0  w.bottom.offset.z -= offset;
            else              w.mid.offset.z -= offset;
        }
        if w.flags[0] & WALL_SIGN_ANCHORED  w.sign.offset.z -= offset;
    }
    for * w: sector.walls {
        if w.adjoin < 0 || w.mirror < 0 continue;
        m := *world.level.sectors[w.adjoin].walls[w.mirror];
        if m.flags[0] & WALL_ANCHORED {
            if m.adjoin >= 0  m.bottom.offset.z += offset;
            else              m.mid.offset.z += offset;
        }
        if m.flags[0] & WALL_SIGN_ANCHORED  m.sign.offset.z += offset;
    }
}

// Walls that morph slide along the elevator's direction (0x5c184), unless one would push
// into the player.
move_walls :: (e: *Elevator, delta: Fixed) {
    if !try_move_walls(e.sector, delta, e.direction, e.flags) return;
    for e.slaves  try_move_walls(it.sector, delta, e.direction, e.flags);
    e.own_value += delta;
}

try_move_walls :: (sector_index: s32, delta: Fixed, direction: Fixed2, flags: u32) -> bool {
    sector := *world.level.sectors[sector_index];
    dx := mul16(delta, direction.x);
    dz := mul16(delta, direction.z);
    for * w: sector.walls {
        if !(w.flags[0] & WALL_MORPHS) continue;
        if does_moving_wall_hit_player(sector_index, w, dx, dz) return false;
        if w.adjoin >= 0 && w.mirror >= 0 {
            m := *world.level.sectors[w.adjoin].walls[w.mirror];
            if (m.flags[0] & WALL_MORPHS) && does_moving_wall_hit_player(w.adjoin, m, dx, dz) return false;
        }
    }
    for * w: sector.walls {
        if !(w.flags[0] & WALL_MORPHS) continue;
        move_wall_vertex(sector_index, w, dx, dz);
        if w.adjoin >= 0 && w.mirror >= 0 {
            m := *world.level.sectors[w.adjoin].walls[w.mirror];
            if m.flags[0] & WALL_MORPHS  move_wall_vertex(w.adjoin, m, dx, dz);
        }
    }
    carry_objects(sector_index, dx, dz, flags);
    level_update_bounds(sector);
    return true;
}

// What stands on the heights the elevator moves goes with the walls (0x5c3c4), the player
// aside, whose own walk takes the elevator's speed.
carry_objects :: (sector_index: s32, dx: Fixed, dz: Fixed, flags: u32) {
    sector := *world.level.sectors[sector_index];
    for walk_sector(sector_index, live = true) {
        o := world.objects[it];
        if !(o.flags & OBJECT_MOVABLE) || !is_on_moving_height(sector, o.position.y, flags) continue;
        carry_object(it, .{dx, 0, dz});
    }
}

// An object moved with a wall or turned about a center, through collision and sliding once
// along what stops it, then put in the sector it's in (0x8ab78, 0x8aa58). A corpse or pickup
// carried into another sector drops to its second floor at once.
carry_object :: (index: s32, offset: Fixed3, rotated := false) {
    o := world.objects[index];
    m: Object_Move;
    m.offset = offset;
    m.step_down = FIXED_INFINITY;
    m.height = o.height + FIXED_HALF;
    m.width = o.width;
    move_object(index, *m);
    if m.responds && m.wall {
        slide_offset(m.response_dir, *m.offset);
        move_object(index, *m);
    }
    sector := level_find_sector(*world.level, o.position);
    if sector < 0 return;
    if !rotated && sector != o.sector && ((o.entity & ENTITY_CORPSE) || (o.flags & OBJECT_PICKUP)) {
        o.position.y = world.level.sectors[sector].col_second;
    }
    change_object_sector(index, sector);
}

// Whether a height is one the elevator's flags say it moves: the floor, the second floor, the
// ceiling (0x5c29c, 0x5c3c4).
is_on_moving_height :: (sector: *Sector, y: Fixed, flags: u32) -> bool {
    return ((flags & ELEVATOR_MOVES_FLOOR) && y == sector.floor.altitude) ||
           ((flags & ELEVATOR_MOVES_SECOND) && sector.second_altitude && sector.floor.altitude + sector.second_altitude == y) ||
           ((flags & ELEVATOR_MOVES_CEILING) && sector.ceiling.altitude == y);
}

move_wall_vertex :: (sector_index: s32, wall: *Wall, dx: Fixed, dz: Fixed) {
    sector := *world.level.sectors[sector_index];
    sector.vertices[wall.left].x += dx;
    sector.vertices[wall.left].z += dz;
    update_wall_and_previous(sector, wall);
    if sector_index == world.player.sector  world.inf.player_walls_moved = true;
}

// A wall's direction and length, and its previous wall's, which shares the vertex.
update_wall_and_previous :: (sector: *Sector, wall: *Wall) {
    update_wall :: (sector: *Sector, w: *Wall) {
        a := sector.vertices[w.left];
        b := sector.vertices[w.right];
        dx, dz := b.x - a.x, b.z - a.z;
        w.direction.x, w.direction.z, w.length = get_direction_and_length(dx, dz);
        w.angle = vec2_to_angle(dx, dz);
    }
    update_wall(sector, wall);
    index := wall - sector.walls.data;
    previous := ifx index == 0 then *sector.walls[sector.walls.count - 1] else *sector.walls[index - 1];
    update_wall(sector, previous);
}

// Whether a wall moved by (dx, dz) would overlap the player or pass over it (0x57580): only
// its left end moves, its direction and length kept.
does_moving_wall_hit_player :: (sector_index: s32, wall: *Wall, dx: Fixed, dz: Fixed) -> bool {
    sector := *world.level.sectors[sector_index];
    side0 := 0;
    overlaps_wall(sector_index, wall, *side0);
    v := *sector.vertices[wall.left];
    saved := v.*;
    v.x += dx;
    v.z += dz;
    side1 := 0;
    hit := overlaps_wall(sector_index, wall, *side1);
    v.* = saved;
    return hit || ((side0 & side1) != 0 && side0 != side1);
}

// Whether the player overlaps a wall, and which side of it it's on, 1 or -1, when it's
// within the wall's length (0x57664). A wall with an adjoin is passed while the player is
// between its sector's floor and ceiling.
overlaps_wall :: (sector_index: s32, wall: *Wall, side: *int) -> bool {
    side.* = 0;
    p := *world.player;
    sector := *world.level.sectors[sector_index];
    if wall.adjoin >= 0 && sector.floor.altitude >= p.position.y && sector.ceiling.altitude < p.position.y - p.height return false;
    width := p.width / 2 + p.width / 4;
    w0 := sector.vertices[wall.left];
    dx := p.position.x - w0.x;
    dz := p.position.z - w0.z;
    along := mul16(dx, wall.direction.x) + mul16(dz, wall.direction.z);
    if cast,no_check(u32) (along + width) <= cast,no_check(u32) (width * 2 + wall.length) {
        across := mul16(dx, wall.direction.z) - mul16(dz, wall.direction.x);
        side.* = ifx across >= 0 then 1 else -1;
        if abs(across) <= width return true;
    }
    return false;
}

// Walls that morph turn about the center (0x368dc): the turn rounded to whole angle units,
// the walls set from where they started at that angle, unless the player is in the way;
// what stands in the sector turns with them.
rotate_walls :: (e: *Elevator, delta: Fixed) {
    if delta > 0  delta = (delta + FIXED_HALF) & 0xFFFF_0000;
    else          delta = -((FIXED_HALF - delta) & 0xFFFF_0000);
    angle_value := e.own_value + delta;
    angle := angle_value >> 16;
    center := e.direction;
    if !can_rotate_walls(e.sector, angle, center) return;
    for e.slaves  if !can_rotate_walls(it.sector, it.value + angle, center) return;
    turn_walls(e.sector, angle, center);
    step := delta >> 16;
    rotate_objects(e.sector, step, center, e.flags);
    for e.slaves {
        turn_walls(it.sector, angle + it.value, center);
        rotate_objects(it.sector, step, center, e.flags);
    }
    e.own_value = angle_value;
}

// Only tested with the player in the sector or one its turning walls look into (0x5bfd8).
can_rotate_walls :: (sector_index: s32, angle: s32, center: Fixed2) -> bool {
    sector := *world.level.sectors[sector_index];
    p := *world.player;
    near := false;
    for * w: sector.walls {
        if !(w.flags[0] & WALL_MORPHS) continue;
        if p.sector == sector_index { near = true; break; }
        if w.adjoin >= 0 && w.mirror >= 0 && p.sector == w.adjoin && (world.level.sectors[w.adjoin].walls[w.mirror].flags[0] & WALL_MORPHS) { near = true; break; }
    }
    if !near return true;
    s, c := sin_cos(angle);
    for * w: sector.walls {
        if !(w.flags[0] & WALL_MORPHS) continue;
        if does_turning_wall_hit_player(sector_index, w, c, s, center) return false;
        if w.adjoin >= 0 && w.mirror >= 0 {
            m := *world.level.sectors[w.adjoin].walls[w.mirror];
            if (m.flags[0] & WALL_MORPHS) && does_turning_wall_hit_player(w.adjoin, m, c, s, center) return false;
        }
    }
    return true;
}

// As a move's test, the left end turned from where it started; the direction is worked out
// again, the length kept (0x5735c).
does_turning_wall_hit_player :: (sector_index: s32, wall: *Wall, c: Fixed, s: Fixed, center: Fixed2) -> bool {
    sector := *world.level.sectors[sector_index];
    side0 := 0;
    overlaps_wall(sector_index, wall, *side0);
    v := *sector.vertices[wall.left];
    saved_v, saved_dir, saved_length := v.*, wall.direction, wall.length;
    o := world.inf.original_vertices[sector_index][wall.left];
    x, z := o.x - center.x, o.z - center.z;
    v.* = .{mul16(x, c) - mul16(z, s) + center.x, mul16(x, s) + mul16(z, c) + center.z};
    b := sector.vertices[wall.right];
    wall.direction.x, wall.direction.z = get_direction_and_length(b.x - v.x, b.z - v.z);
    side1 := 0;
    hit := overlaps_wall(sector_index, wall, *side1);
    v.*, wall.direction, wall.length = saved_v, saved_dir, saved_length;
    return hit || ((side0 & side1) != 0 && side0 != side1);
}

turn_walls :: (sector_index: s32, angle: s32, center: Fixed2) {
    sector := *world.level.sectors[sector_index];
    s, c := sin_cos(angle);
    turn :: (sector_index: s32, w: *Wall, c: Fixed, s: Fixed, center: Fixed2) {
        sector := *world.level.sectors[sector_index];
        o := world.inf.original_vertices[sector_index][w.left];
        x, z := o.x - center.x, o.z - center.z;
        sector.vertices[w.left] = .{mul16(x, c) - mul16(z, s) + center.x, mul16(x, s) + mul16(z, c) + center.z};
        update_wall_and_previous(sector, w);
        if sector_index == world.player.sector  world.inf.player_walls_moved = true;
    }
    whole := true;
    for * w: sector.walls  if !(w.flags[0] & WALL_MORPHS)  whole = false;
    if whole  world.inf.turns[sector_index] = .{angle, center, true};
    for * w: sector.walls {
        if !(w.flags[0] & WALL_MORPHS) continue;
        turn(sector_index, w, c, s, center);
        if w.adjoin >= 0 && w.mirror >= 0 {
            m := *world.level.sectors[w.adjoin].walls[w.mirror];
            if m.flags[0] & WALL_MORPHS  turn(w.adjoin, m, c, s, center);
        }
    }
    level_update_bounds(sector);
}

// What stands on the heights the elevator moves turns with it (0x5c29c, 0x8aa58): its yaw,
// and its place about the center, moved through collision.
rotate_objects :: (sector_index: s32, step: s32, center: Fixed2, flags: u32) {
    if !step return;
    sector := *world.level.sectors[sector_index];
    s, c := sin_cos(step);
    get_turn :: (position: Fixed3, c: Fixed, s: Fixed, center: Fixed2) -> Fixed2 {
        x, z := position.x - center.x, position.z - center.z;
        return .{mul16(x, c) - mul16(z, s) + center.x - position.x, mul16(x, s) + mul16(z, c) + center.z - position.z};
    }

    p := *world.player;
    if p.sector == sector_index && is_on_moving_height(sector, p.position.y, flags) {
        p.yaw -= step;
        move := get_turn(p.position, c, s, center);
        col := *world.collision;
        if collide_player_move(col, p, *move) || collide_player_move(col, p, *move)  move_player_along_path(p, move);
    }

    for walk_sector(sector_index, live = true) {
        o := world.objects[it];
        if !(o.flags & OBJECT_MOVABLE) || !is_on_moving_height(sector, o.position.y, flags) continue;
        o.yaw = (o.yaw - step) & ANGLE_MASK;
        move := get_turn(o.position, c, s, center);
        carry_object(it, .{move.x, 0, move.z}, rotated = true);
    }
}

scroll_walls :: (e: *Elevator, delta: Fixed) {
    e.own_value += delta;
    dx := mul16(delta, e.direction.x);
    dz := mul16(delta, e.direction.z);
    for s: get_sectors(e) {
        for * w: world.level.sectors[s].walls {
            if w.flags[0] & WALL_SCROLLS_TOP    { w.top.offset.x += dx; w.top.offset.z += dz; }
            if w.flags[0] & WALL_SCROLLS_MID    { w.mid.offset.x += dx; w.mid.offset.z += dz; }
            if w.flags[0] & WALL_SCROLLS_BOTTOM { w.bottom.offset.x += dx; w.bottom.offset.z += dz; }
            if w.flags[0] & WALL_SCROLLS_SIGN   { w.sign.offset.x += dx; w.sign.offset.z += dz; }
        }
    }
}

scroll_flats :: (e: *Elevator, delta: Fixed) {
    e.own_value += delta;
    dx := mul16(delta, e.direction.x);
    dz := mul16(delta, e.direction.z);
    for s: get_sectors(e) {
        flat := ifx e.type == .SCROLL_FLOOR then *world.level.sectors[s].floor else *world.level.sectors[s].ceiling;
        flat.offset.x += dx;
        flat.offset.z += dz;
    }
}

// At a stop with a delay the elevator stops: the moving sound ends and the stopping one
// plays (0x373b0).
handle_stop_delay :: (e: *Elevator) {
    stop := *e.stops[e.next_stop];
    if (e.update_flags & ELEVATOR_MOVING) && stop.delay {
        stop_sound(e.looping);
        e.looping = 0;
        play_sound_at(e.sounds[2], get_elevator_sound_position(e));
    }
    if stop.delay  e.update_flags &= ~cast(u32) ELEVATOR_MOVING;
    else           e.update_flags |= ELEVATOR_MOVING;
}

// Where an elevator's sounds come from: its sector's first vertex at the second floor's
// height, or the center it turns about.
get_elevator_sound_position :: (e: *Elevator) -> Fixed3 {
    sector := *world.level.sectors[e.sector];
    y := sector.second_altitude + sector.floor.altitude;
    if e.type == .ROTATE_WALL return .{e.direction.x, y, e.direction.z};
    if !sector.vertices return .{0, y, 0};
    return .{sector.vertices[0].x, y, sector.vertices[0].z};
}

run_adjoin_commands :: (stop: *Stop) {
    for stop.adjoins {
        if it.sector0 >= 0 && it.wall0 >= 0 {
            w := *world.level.sectors[it.sector0].walls[it.wall0];
            w.adjoin = it.sector1;
            w.mirror = ifx it.sector1 >= 0 then it.wall1 else -1;
        }
        if it.sector1 >= 0 && it.wall1 >= 0 {
            w := *world.level.sectors[it.sector1].walls[it.wall1];
            w.adjoin = it.sector0;
            w.mirror = ifx it.sector0 >= 0 then it.wall0 else -1;
        }
        if it.sector0 >= 0  level_update_wall_parts(*world.level, *world.level.sectors[it.sector0]);
        if it.sector1 >= 0  level_update_wall_parts(*world.level, *world.level.sectors[it.sector1]);
    }
}

// A stop's messages (inf_stopHandleMessages, in the elevator task).
send_stop_messages :: (e_in: *Elevator, stop_index: s32) {
    inf := *world.inf;
    e_index := e_in - inf.elevators.data;
    count := inf.elevators[e_index].stops[stop_index].messages.count;
    for m: 0..count-1 {
        msg := inf.elevators[e_index].stops[stop_index].messages[m];
        inf.msg_arg1, inf.msg_arg2 = msg.arg1, msg.arg2;
        if msg.target.wall >= 0 {
            send_to_wall(msg.target.sector, msg.target.wall, 0, msg.event, msg.type);
        } else if msg.target.sector >= 0 {
            links := inf.sector_links[msg.target.sector];
            if links {
                for l: 0..links.count-1 {
                    link := inf.links[inf.sector_links[msg.target.sector][l]];
                    if !link.alive || !(msg.event == 0 || (msg.event & EVENT_INTERNAL) || (link.event_mask & msg.event)) continue;
                    send_sector_message(msg.target.sector, msg.type);
                    inf.msg_entity = 0;
                    inf.msg_arg1, inf.msg_arg2 = msg.arg1, msg.arg2;
                    inf.msg_event = msg.event;
                    run_link(link, msg.type);
                }
            } else {
                send_to_sector(msg.target.sector, 0, msg.event, msg.type);
            }
        } else if msg.type == .LIGHTS {
            toggle_lights();
        }
    }
}

// The level's lights swapped with the ones kept in each sector's third flags word.
toggle_lights :: () {
    for * world.level.sectors {
        light := cast(Fixed) (it.flags[2] << 16);
        it.flags[2] = cast,no_check(u32) (it.ambient >> 16);
        it.ambient = light;
    }
}

// A message to a sector: what it does to the sector itself (0x5add0), then to each link
// whose events and entities match (0x5ad08).
send_to_sector :: (sector: s32, entity: u32, event: u32, type: Inf_Message_Type) {
    send_sector_message(sector, type);
    send_link_messages(world.inf.sector_links[sector], entity, event, type);
}

send_to_wall :: (sector: s32, wall: s32, entity: u32, event: u32, type: Inf_Message_Type) {
    inf := *world.inf;
    w := *world.level.sectors[sector].walls[wall];
    if type == .SET_BITS || type == .CLEAR_BITS {
        set_wall_bits(w, type == .SET_BITS);
        return;
    }
    send_link_messages(inf.wall_links[inf.wall_first[sector] + wall], entity, event, type);
}

send_link_messages :: (links: [] s32, entity: u32, event: u32, type: Inf_Message_Type) {
    inf := *world.inf;
    for index: links {
        link := inf.links[index];
        if !link.alive continue;
        // Any internal event passes, as does an event the link wants.
        if !(event == 0 || (event & EVENT_INTERNAL) || (link.event_mask & event)) continue;
        if entity && !(link.entity_mask & entity) continue;
        inf.msg_entity = entity;
        inf.msg_event = event;
        run_link(link, type);
    }
}

run_link :: (link: Inf_Link, type: Inf_Message_Type) {
    inf := *world.inf;
    if link.type == {
        case .ELEVATOR;  elevator_message(*inf.elevators[link.target], type);
        case .TRIGGER;   trigger_message(*inf.triggers[link.target], type);
        case .TELEPORT;  // Teleports work by who's in their sector.
    }
}

set_wall_bits :: (w: *Wall, set: bool) {
    inf := *world.inf;
    word, bits := inf.msg_arg1, inf.msg_arg2;
    if word < 1 || word > 3 return;
    if set  w.flags[word - 1] |= bits;
    else    w.flags[word - 1] &= ~bits;
    if w.adjoin < 0 || w.mirror < 0 || word == 2 return;
    m := *world.level.sectors[w.adjoin].walls[w.mirror];
    shared: u32 = ifx word == 1 then cast(u32) 0xEC00 else 0xF;
    if set  m.flags[word - 1] |= bits & shared;
    else    m.flags[word - 1] &= ~(bits & shared);
}

send_sector_message :: (sector_index: s32, type: Inf_Message_Type) {
    inf := *world.inf;
    sector := *world.level.sectors[sector_index];
    word, bits := inf.msg_arg1, inf.msg_arg2;
    if type == .SET_BITS && word >= 1 && word <= 3    sector.flags[word - 1] |= bits;
    if type == .CLEAR_BITS && word >= 1 && word <= 3  sector.flags[word - 1] &= ~bits;
    // WAKEUP goes to the sector's objects that can be woken: the ones on paths and the
    // enemies; MASTER_ON and MASTER_OFF to its generators. In the original the WAKEUP case
    // falls through into theirs, so generators get it too, and take no notice once started.
    if type == .WAKEUP {
        wake_sector_objects(sector_index);
        send_sector_generator_message(sector_index, .WAKEUP);
    }
    if type == .MASTER_ON   send_sector_generator_message(sector_index, .MASTER_ON);
    if type == .MASTER_OFF  send_sector_generator_message(sector_index, .MASTER_OFF);
}

// An elevator's message (0x36bf8).
elevator_message :: (e: *Elevator, type: Inf_Message_Type) {
    inf := *world.inf;
    if !e.alive return;
    event := inf.msg_event;
    entity := inf.msg_entity;
    sector := *world.level.sectors[e.sector];
    if entity & ENTITY_SMART {
        if sector.flags[0] & SECTOR_NO_SMART return;
        if !(sector.flags[0] & SECTOR_SMART) && !(e.flags & ELEVATOR_DOOR) return;
    }
    if type == .MASTER_ON {
        e.update_flags |= ELEVATOR_MASTER_ON;
        return;
    }
    if !(e.update_flags & ELEVATOR_MASTER_ON) return;
    if event != EVENT_INTERNAL {
        if (entity & ENTITY_SMART) && e.key return;
        if e.key {
            has := false;
            message: s32;
            if e.key == {
                case KEY_RED;    has = agent.items[Item_Slot.RED_KEY] != 0;    message = 6;
                case KEY_YELLOW; has = agent.items[Item_Slot.YELLOW_KEY] != 0; message = 7;
                case KEY_BLUE;   has = agent.items[Item_Slot.BLUE_KEY] != 0;   message = 8;
            }
            if !has {
                send_message(message);
                play_sound(inf.sounds.locked);
                return;
            }
        }
    }
    tick := world.clock.tick;
    if type == {
        case .TRIGGER;
            if e.trigger_move == {
                case TRIGGER_CONT;
                    start_elevator(e);
                case TRIGGER_LAST;
                    e.next_stop = advance_stops(e, -1, 0);
                    if get_value(e).* != e.stops[e.next_stop].value  start_elevator(e);
                case TRIGGER_PREV;
                    if e.next_tick < tick  e.next_stop = advance_stops(e, 0, -1);
                    e.next_stop = advance_stops(e, 0, -1);
                    start_elevator(e);
                case;
                    if e.next_tick < tick  e.next_stop = advance_stops(e, 0, 1);
                    start_elevator(e);
            }
            if event == EVENT_EXPLOSION {
                for * w: sector.walls  w.flags[0] &= ~cast(u32) 0xC00;
            }
        case .NEXT_STOP;
            if e.next_tick < tick  e.next_stop = advance_stops(e, 0, 1);
            start_elevator(e);
        case .PREV_STOP;
            if e.next_tick > tick  e.next_stop = advance_stops(e, 0, -1);
            e.next_stop = advance_stops(e, 0, -1);
            start_elevator(e);
        case .GOTO_STOP;
            if e.stops {
                stop := advance_stops(e, xx inf.msg_arg1, 0);
                if e.stops[stop].value != get_value(e).* {
                    e.next_stop = stop;
                    start_elevator(e);
                    if e.update_flags & ELEVATOR_MOVING {
                        stop_sound(e.looping);
                        e.looping = 0;
                        play_sound_at(e.sounds[2], get_elevator_sound_position(e));
                        e.update_flags &= ~cast(u32) ELEVATOR_MOVING;
                    }
                }
            }
        case .CRUSH;
            if !(sector.flags[0] & SECTOR_CRUSHING) {
                // The original turns back a stop only for elevators that go on when
                // triggered; the others go to their last.
                if e.trigger_move == TRIGGER_CONT  e.next_stop = advance_stops(e, 0, -1);
                else                               e.next_stop = advance_stops(e, -1, 0);
                e.update_flags |= ELEVATOR_CRUSH;
                e.next_tick = 0;
            }
        case .MASTER_OFF;
            e.update_flags &= ~cast(u32) ELEVATOR_MASTER_ON;
            if e.update_flags & ELEVATOR_MOVING {
                stop_sound(e.looping);
                e.looping = 0;
                play_sound_at(e.sounds[2], get_elevator_sound_position(e));
                e.update_flags &= ~cast(u32) ELEVATOR_MOVING;
            }
        case .COMPLETE;
            // The "complete" number's goal is done (the original doesn't check the number);
            // then on a stop, as next_stop does.
            n := inf.msg_arg1;
            if n < GOAL_SLOTS  world.player_state.triggers_done[n] = true;
            if e.next_tick < tick  e.next_stop = advance_stops(e, 0, 1);
            start_elevator(e);
    }
}

// A trigger's message (0x3776c).
trigger_message :: (t: *Trigger, type: Inf_Message_Type) {
    if !t.alive return;
    if type == {
        case .TRIGGER;     fire_trigger(t);
        case .MASTER_OFF;  t.master = false;
        case .MASTER_ON;   t.master = true;
        case .DONE;
            if t.type == .SWITCH1 {
                if t.switch_frames  t.state = 0;
                t.master = true;
            }
    }
}

// A trigger fires: its sound, its message to each client that wants the event, its text,
// then its switch's state.
fire_trigger :: (t: *Trigger) {
    inf := *world.inf;
    if !t.master return;
    play_sound(t.sound);
    event := inf.msg_event;
    for target: t.targets {
        if !(target.event_mask & event) continue;
        inf.msg_arg1, inf.msg_arg2 = t.args[0], t.args[1];
        if target.target.wall >= 0 {
            send_to_wall(target.target.sector, target.target.wall, 0, t.event, t.command);
        } else if target.target.sector >= 0 {
            send_to_sector(target.target.sector, 0, t.event, t.command);
        } else if t.command == .LIGHTS {
            // "system": the game's own task, which only knows the lights.
            toggle_lights();
        }
    }
    if t.text  send_message(t.text);
    if t.type == {
        case .TOGGLE;
            if t.switch_frames {
                t.state += 1;
                if t.state >= t.switch_frames  t.state = 0;
            }
        case .SINGLE;
            if t.switch_frames {
                t.state = 1;
                t.master = false;
            }
        case .SWITCH1;
            if t.switch_frames  t.state = 1;
            t.master = false;
    }
}

// Parsing -------------------------------------------------------------------------------

Inf_Reader :: struct {
    text: string;
    in_block: bool;
}

// The next line with anything on it, comments ('#', '//', '/* */') taken off.
next_inf_line :: (r: *Inf_Reader) -> string, bool {
    while r.text {
        _, line, rest := split_from_left(r.text, #char "\n");
        r.text = rest;
        s := line;
        if r.in_block {
            found, _, after := split_from_left(s, "*/");
            if !found continue;
            r.in_block = false;
            s = after;
        }
        for i: 0..s.count-1 {
            c := s[i];
            if c == #char "#" { s.count = i; break; }
            if c == #char "/" && i + 1 < s.count {
                if s[i + 1] == #char "/" { s.count = i; break; }
                if s[i + 1] == #char "*" {
                    found, _, after := split_from_left(advance(s, i + 2), "*/");
                    if !found { r.in_block = true; s.count = i; break; }
                    s = join(slice(s, 0, i), " ", after,, temp);
                    break;
                }
            }
        }
        s = trim(s);
        if s return s, true;
    }
    return "", false;
}

// Words split at white space, as sscanf's %s reads them.
// The level item (0x1638d): each line's words read into the same buffers, so a line short of
// words keeps the last one's in their place; AMB_SOUND: <voc> <seconds> <priority>, unknown
// keywords passed over, to SEQEND. The sounds are set up with the level's tasks.
parse_level_item :: (r: *Inf_Reader) {
    buffers: [4] string;
    while true {
        line, ok := next_inf_line(r);
        if !ok return;
        words := split_words(line);
        for words  if it_index < 4  buffers[it_index] = copy_string(it,, temp);
        if !words continue;
        if equal_nocase(words[0], "SEQEND") return;
        if !equal_nocase(words[0], "AMB_SOUND:") continue;
        seconds := string_to_float64(buffers[2]);
        array_add(*world.inf.level_sounds, .{copy_string(buffers[1]), seconds, read_seq_int(buffers[3])});
    }
}

split_words :: (line: string) -> [..] string {
    words: [..] string;
    words.allocator = temp;
    s := line;
    while s {
        while s && (s[0] == #char " " || s[0] == #char "\t" || s[0] == #char "\r")  advance(*s);
        if !s break;
        start := s;
        while s && s[0] != #char " " && s[0] != #char "\t" && s[0] != #char "\r"  advance(*s);
        word := start;
        word.count = start.count - s.count;
        array_add(*words, word);
    }
    return words;
}

// strtod into 16.16, truncated (the INF reader's numbers are doubles).
inf_fixed :: (s: string) -> Fixed {
    f := parse_double(s);
    return cast(Fixed) clamp(f * 65536.0, -2147483648.0, 2147483647.0);
}

inf_angle :: (s: string) -> s32 {
    return cast,no_check(s16) cast(s32) (parse_double(s) * 45.5111);
}

// strtod: as much of a number as the text starts with, 0 for none.
parse_double :: (s: string) -> float64 {
    t := s;
    n := 0;
    if n < t.count && (t[n] == #char "-" || t[n] == #char "+")  n += 1;
    while n < t.count && ((t[n] >= #char "0" && t[n] <= #char "9") || t[n] == #char ".")  n += 1;
    f, ok := string_to_float64(slice(t, 0, n));
    return ifx ok then f else 0;
}

// As the original's atoi (0x8eae0): a sign, then digits. Masks take it too, so Imperial
// City's "entity_mask: -1" is every entity.
parse_uint :: (s: string) -> u32 {
    t := s;
    negative := t && t[0] == #char "-";
    if t && (t[0] == #char "-" || t[0] == #char "+")  t = advance(t, 1);
    value: u32;
    for 0..t.count-1 {
        c := t[it];
        if c < #char "0" || c > #char "9" break;
        value = value * 10 + c - #char "0";
    }
    return ifx negative then 0 - value else value;
}

parse_int :: (s: string) -> s32 {
    return cast,no_check(s32) parse_uint(s);
}

is_number :: (s: string, dot_too: bool) -> bool {
    if !s return false;
    c := s[0];
    return (c >= #char "0" && c <= #char "9") || c == #char "-" || (dot_too && c == #char ".");
}

find_sector :: (name: string) -> s32 {
    for world.level.sectors  if it.name && equal_nocase(it.name, name) return xx it_index;
    return -1;
}

// "name" for a sector, "name(3)" for its wall 3, "system" for neither.
parse_target :: (text: string) -> Inf_Target {
    target: Inf_Target;
    if equal_nocase(text, "SYSTEM") return target;
    name := text;
    wall := -1;
    found, before, after := split_from_left(text, #char "(");
    if found {
        name = before;
        wall = parse_int(after);
    }
    sector := find_sector(name);
    if sector < 0 return target;
    if wall != -1 {
        if wall < world.level.sectors[sector].walls.count {
            target.sector = sector;
            target.wall = xx wall;
        }
        return target;
    }
    target.sector = sector;
    return target;
}

parse_message_type :: (word: string, elevator: bool) -> Inf_Message_Type {
    if equal_nocase(word, "NEXT_STOP")  return .NEXT_STOP;
    if equal_nocase(word, "PREV_STOP")  return .PREV_STOP;
    if equal_nocase(word, "GOTO_STOP")  return .GOTO_STOP;
    if equal_nocase(word, "MASTER_ON")  return .MASTER_ON;
    if equal_nocase(word, "MASTER_OFF") return .MASTER_OFF;
    if equal_nocase(word, "SET_BITS")   return .SET_BITS;
    if equal_nocase(word, "CLEAR_BITS") return .CLEAR_BITS;
    if equal_nocase(word, "COMPLETE")   return .COMPLETE;
    if equal_nocase(word, "LIGHTS")     return .LIGHTS;
    if elevator && equal_nocase(word, "DONE")   return .DONE;
    if elevator && equal_nocase(word, "WAKEUP") return .WAKEUP;
    return .TRIGGER;
}

// A message's words after its type: GOTO_STOP and COMPLETE take a number, SET_BITS and
// CLEAR_BITS a flags word and the bits; those clear the event.
parse_message :: (words: [] string, first: int, elevator: bool, msg_type: *Inf_Message_Type, arg1: *u32, arg2: *u32, event: *u32) {
    word := ifx first < words.count then words[first] else "";
    a1 := ifx first + 1 < words.count then words[first + 1] else "";
    a2 := ifx first + 2 < words.count then words[first + 2] else "";
    msg_type.* = parse_message_type(word, elevator);
    if msg_type.* == {
        case .GOTO_STOP; #through;
        case .COMPLETE;
            arg1.* = parse_uint(a1);
            if event  event.* = 0;
        case .SET_BITS; #through;
        case .CLEAR_BITS;
            arg1.* = parse_uint(a1);
            arg2.* = parse_uint(a2);
            if event  event.* = 0;
    }
}

parse_inf :: (text: string) {
    r := Inf_Reader.{text = text};
    line, ok := next_inf_line(*r);
    while ok && !begins_with_nocase(line, "INF")  line, ok = next_inf_line(*r);
    if !ok return;
    count := -1;
    while true {
        line, ok = next_inf_line(*r);
        if !ok return;
        words := split_words(line);
        if words.count >= 2 && equal_nocase(words[0], "ITEMS") { count = parse_int(words[1]); break; }
    }
    count = min(count, 512);

    for 1..count {
        line, ok = next_inf_line(*r);
        if !ok return;
        words := split_words(line);
        while !(words.count >= 2 && equal_nocase(words[0], "ITEM:")) {
            line, ok = next_inf_line(*r);
            if !ok return;
            words = split_words(line);
        }
        kind := words[1];
        name := "";
        number := 0;
        for w: 0..words.count-2 {
            if equal_nocase(words[w], "NAME:")  name = words[w + 1];
            if equal_nocase(words[w], "NUM:")   number = parse_int(words[w + 1]);
        }
        if equal_nocase(kind, "LEVEL") {
            line, ok = next_inf_line(*r);
            if ok && contains_nocase(line, "SEQ")  parse_level_item(*r);
            continue;
        }
        is_sector := equal_nocase(kind, "SECTOR");
        if !is_sector && !equal_nocase(kind, "LINE") continue;
        line, ok = next_inf_line(*r);
        if !ok || !contains_nocase(line, "SEQ") continue;
        line, ok = next_inf_line(*r);
        sector := find_sector(name);
        // An item may have several classes; each runs until the next CLASS or SEQEND.
        while ok && contains_nocase(line, "CLASS") {
            words = split_words(line);
            class := ifx words.count > 1 then words[1] else "";
            subclass := ifx words.count > 2 then words[2] else "";
            seq_end: bool;
            if sector < 0 {
                line, ok, seq_end = skip_class(*r);
            } else if is_sector && equal_nocase(class, "ELEVATOR") {
                line, ok, seq_end = parse_elevator(*r, sector, subclass);
            } else if is_sector && equal_nocase(class, "TRIGGER") {
                line, ok, seq_end = parse_trigger(*r, sector, -1, "");
            } else if is_sector && equal_nocase(class, "TELEPORTER") {
                line, ok, seq_end = parse_teleport(*r, sector, subclass);
            } else if !is_sector && equal_nocase(class, "TRIGGER") && number >= 0 && number < world.level.sectors[sector].walls.count {
                line, ok, seq_end = parse_trigger(*r, sector, xx number, ifx words.count > 2 then subclass else "");
            } else {
                line, ok, seq_end = skip_class(*r);
            }
            if seq_end break;
        }
    }
}

skip_class :: (r: *Inf_Reader) -> string, bool, bool {
    while true {
        line, ok := next_inf_line(r);
        if !ok return "", false, true;
        if contains_nocase(line, "CLASS") return line, true, false;
        if contains_nocase(line, "SEQEND") return "", true, true;
    }
    return "", false, true;
}

// One elevator class's lines (0x1638d's elevator part).
parse_elevator :: (r: *Inf_Reader, sector: s32, subclass: string) -> string, bool, bool {
    inf := *world.inf;
    index: s32 = -1;
    link: s32 = -1;
    specials :: string.["BASIC", "BASIC_AUTO", "ENCLOSED", "MID", "INV", "DOOR", "DOOR_INV", "DOOR_MID", "MORPH_SPIN1", "MORPH_SPIN2", "MORPH_MOVE1", "MORPH_MOVE2"];
    kinds :: string.["MOVE_CEILING", "MOVE_FLOOR", "MOVE_OFFSET", "MOVE_WALL", "ROTATE_WALL", "SCROLL_WALL", "SCROLL_FLOOR", "SCROLL_CEILING", "CHANGE_LIGHT", "MOVE_FC", "CHANGE_WALL_LIGHT"];
    for specials {
        if !equal_nocase(subclass, it) continue;
        if it_index == 2 || it_index == 3 {     // Not in the game.
            line, ok, done := skip_class(r);
            return line, ok, done;
        }
        create_special_elevator(sector, xx it_index);
        links := inf.sector_links[sector];
        link = links[links.count - 1];
        index = inf.links[link].target;
        break;
    }
    if index < 0 {
        for kinds {
            if !equal_nocase(subclass, it) continue;
            _, index = create_elevator(sector, xx it_index);
            link = add_elevator_link(index, sector);
            break;
        }
    }
    if index < 0 {
        line, ok, done := skip_class(r);
        return line, ok, done;
    }

    first_stop := 0;
    delay := 0x246;
    while true {
        line, ok := next_inf_line(r);
        if !ok return "", false, true;
        if contains_nocase(line, "CLASS") {
            go_to_initial_stop(index, xx first_stop);
            return line, true, false;
        }
        words := split_words(line);
        if !words continue;
        key := words[0];
        a := words.count;
        arg :: (words: [] string, i: int) -> string { return ifx i < words.count then words[i] else ""; }
        e := *inf.elevators[index];
        if equal_nocase(key, "SEQEND") {
            go_to_initial_stop(index, xx first_stop);
            return "", true, true;
        } else if equal_nocase(key, "START:") {
            first_stop = parse_int(arg(words, 1));
        } else if equal_nocase(key, "STOP:") {
            text := arg(words, 1);
            value: Fixed;
            heights := e.type == .MOVE_CEILING || e.type == .MOVE_FLOOR || e.type == .MOVE_FC;
            if text && text[0] == #char "@" {
                value = inf_fixed(advance(text, 1));
                if heights  value = world.level.sectors[sector].floor.altitude - value;
                else if e.type == .ROTATE_WALL  value = (inf_angle(text)) << 16;   // Reads "@": 0, as the original.
            } else if is_number(text, false) {
                value = inf_fixed(text);
                if heights  value = -value;
                else if e.type == .ROTATE_WALL  value = inf_angle(text) << 16;
            } else {
                from := find_sector(text);
                if from >= 0  value = world.level.sectors[from].floor.altitude;
            }
            stop := add_stop(e, value);
            if a > 2 {
                d := arg(words, 2);
                if is_number(d, true)              delay = cast(s32) (parse_double(d) * 145.65);
                else if equal_nocase(d, "HOLD")      delay = DELAY_HOLD;
                else if equal_nocase(d, "TERMINATE") delay = DELAY_TERMINATE;
                else if equal_nocase(d, "COMPLETE")  delay = DELAY_COMPLETE;
                stop.delay = xx delay;
            }
        } else if equal_nocase(key, "SPEED:") {
            if e.type == .ROTATE_WALL  e.speed = (inf_angle(arg(words, 1)) & 0xFFFF) << 16;
            else                       e.speed = inf_fixed(arg(words, 1));
        } else if equal_nocase(key, "MASTER:") {
            e.update_flags &= ~cast(u32) ELEVATOR_MASTER_ON;
        } else if equal_nocase(key, "ANGLE:") {
            e.direction.x, e.direction.z = sin_cos(inf_angle(arg(words, 1)));
        } else if equal_nocase(key, "ADJOIN:") {
            stop_index := parse_int(arg(words, 1));
            if stop_index >= 0 && stop_index < e.stops.count {
                s0 := find_sector(arg(words, 2));
                s1 := find_sector(arg(words, 4));
                w0 := parse_int(arg(words, 3));
                w1 := parse_int(arg(words, 5));
                command: Adjoin_Command;
                command.sector0, command.sector1 = s0, s1;
                command.wall0 = ifx s0 >= 0 && w0 >= 0 && w0 < world.level.sectors[s0].walls.count then w0 else -1;
                command.wall1 = ifx s1 >= 0 && w1 >= 0 && w1 < world.level.sectors[s1].walls.count then w1 else -1;
                array_add(*e.stops[stop_index].adjoins, command);
            }
        } else if equal_nocase(key, "TEXTURE:") {
            stop_index := parse_int(arg(words, 1));
            from := find_sector(arg(words, 3));
            if stop_index >= 0 && stop_index < e.stops.count && from >= 0 {
                which := arg(words, 2);
                if which && (which[0] == #char "C" || which[0] == #char "c")  e.stops[stop_index].ceiling_texture = world.level.sectors[from].ceiling.texture;
                else e.stops[stop_index].floor_texture = world.level.sectors[from].floor.texture;
            }
        } else if equal_nocase(key, "SLAVE:") {
            slave := find_sector(arg(words, 1));
            if slave >= 0  array_add(*e.slaves, .{slave, ifx a > 2 then inf_angle(arg(words, 2)) else 0});
        } else if equal_nocase(key, "MESSAGE:") {
            stop_index := parse_int(arg(words, 1));
            if stop_index >= 0 && stop_index < e.stops.count {
                msg: Inf_Message;
                msg.target = parse_target(arg(words, 2));
                msg.type = .TRIGGER;
                if a >= 5  msg.event = parse_uint(arg(words, 4));
                if a > 3  parse_message(words, 3, true, *msg.type, *msg.arg1, *msg.arg2, *msg.event);
                array_add(*e.stops[stop_index].messages, msg);
            }
        } else if equal_nocase(key, "EVENT_MASK:") {
            m := arg(words, 1);
            inf.links[link].event_mask = ifx m && m[0] == #char "*" then EVENT_ANY else parse_uint(m);
        } else if equal_nocase(key, "ENTITY_MASK:") || equal_nocase(key, "OBJECT_MASK:") {
            // As the original has it: '*' sets the entities, a number the events.
            m := arg(words, 1);
            if m && m[0] == #char "*"  inf.links[link].entity_mask = 0xFFFF_FFFF;
            else inf.links[link].event_mask = parse_uint(m);
        } else if equal_nocase(key, "CENTER:") {
            e.direction = .{inf_fixed(arg(words, 1)), inf_fixed(arg(words, 2))};
        } else if equal_nocase(key, "KEY:") {
            k := arg(words, 1);
            if equal_nocase(k, "RED")     e.key = KEY_RED;
            if equal_nocase(k, "YELLOW")  e.key = KEY_YELLOW;
            if equal_nocase(k, "BLUE")    e.key = KEY_BLUE;
        } else if equal_nocase(key, "ADDON:") {
            n := parse_int(arg(words, 1));
            links := inf.sector_links[sector];
            if n >= 0 && n < links.count {
                link = links[n];
                index = inf.links[link].target;
            }
        } else if equal_nocase(key, "FLAGS:") {
            e.flags = parse_uint(arg(words, 1));
        } else if equal_nocase(key, "SOUND:") {
            which := parse_int(arg(words, 1));
            name := arg(words, 2);
            handle: Sound_Handle;
            if !is_number(name, false)  handle = register_sound(tprint("%", name), 0xC);
            if which >= 1 && which <= 3  e.sounds[which - 1] = handle;
        } else if equal_nocase(key, "PAGE:") {
            stop_index := parse_int(arg(words, 1));
            if stop_index >= 0 && stop_index < e.stops.count  e.stops[stop_index].page = register_sound(arg(words, 2), 0x7F);
        }
    }
    return "", false, true;
}

// A trigger: a sector's (whatever its subclass) or a line's (0x37538).
parse_trigger :: (r: *Inf_Reader, sector: s32, wall: s32, subclass: string) -> string, bool, bool {
    inf := *world.inf;
    t := array_add(*inf.triggers);
    index: s32 = xx (inf.triggers.count - 1);
    t.type = .SECTOR;
    if wall >= 0 {
        t.type = .WALL;
        if equal_nocase(subclass, "SWITCH1")  t.type = .SWITCH1;
        if equal_nocase(subclass, "TOGGLE")   t.type = .TOGGLE;
        if equal_nocase(subclass, "SINGLE")   t.type = .SINGLE;
    }
    t.command = .TRIGGER;
    if wall >= 0 {
        list := *inf.wall_links[inf.wall_first[sector] + wall];
        t.link = add_link(list, .TRIGGER, index, EVENT_ANY, ENTITY_PLAYER);
        t.link_sector, t.link_wall = sector, wall;
        if t.type == .SWITCH1 || t.type == .TOGGLE || t.type == .SINGLE {
            t.sound = inf.sounds.switch_;
            sign := world.level.sectors[sector].walls[wall].sign.texture;
            frames := get_switch_frame_count(sign);
            if frames {
                t.switch_frames = frames;
                inf.links[t.link].event_mask &= ~cast(u32) (EVENT_CROSS_FRONT | EVENT_CROSS_BACK);
            }
        }
    } else {
        t.link = add_link(*inf.sector_links[sector], .TRIGGER, index, EVENT_ANY, ENTITY_PLAYER);
        t.link_sector = sector;
    }

    while true {
        line, ok := next_inf_line(r);
        if !ok return "", false, true;
        if contains_nocase(line, "CLASS") return line, true, false;
        words := split_words(line);
        if !words continue;
        key := words[0];
        arg :: (words: [] string, i: int) -> string { return ifx i < words.count then words[i] else ""; }
        t = *inf.triggers[index];
        if equal_nocase(key, "SEQEND") {
            return "", true, true;
        } else if equal_nocase(key, "CLIENT:") {
            target := array_add(*t.targets);
            target.target = parse_target(arg(words, 1));
            if words.count > 2  target.event_mask = parse_uint(arg(words, 2));
        } else if equal_nocase(key, "MASTER:") {
            t.master = false;
        } else if equal_nocase(key, "TEXT:") {
            text := arg(words, 1);
            if is_number(text, false) && text[0] != #char "-"  t.text = cast(s32) parse_uint(text);
        } else if equal_nocase(key, "MESSAGE:") {
            parse_message(words, 1, false, *t.command, *t.args[0], *t.args[1], null);
        } else if equal_nocase(key, "EVENT_MASK:") {
            m := arg(words, 1);
            inf.links[t.link].event_mask = ifx m && m[0] == #char "*" then EVENT_ANY else parse_uint(m);
        } else if equal_nocase(key, "ENTITY_MASK:") || equal_nocase(key, "OBJECT_MASK:") {
            m := arg(words, 1);
            inf.links[t.link].entity_mask = ifx m && m[0] == #char "*" then 0xFFFF_FFFF else parse_uint(m);
        } else if equal_nocase(key, "EVENT:") {
            t.event = parse_uint(arg(words, 1));
        } else if equal_nocase(key, "SOUND:") && wall >= 0 {
            name := arg(words, 1);
            t.sound = ifx is_number(name, false) then 0 else register_sound(name, 0xC);
        }
    }
    return "", false, true;
}

parse_teleport :: (r: *Inf_Reader, sector: s32, subclass: string) -> string, bool, bool {
    inf := *world.inf;
    t := array_add(*inf.teleports);
    index: s32 = xx (inf.teleports.count - 1);
    t.sector = sector;
    t.target = -1;
    t.chute = equal_nocase(subclass, "CHUTE");
    add_link(*inf.sector_links[sector], .TELEPORT, index, EVENT_ENTER, 0xFFFF_FFFF);
    while true {
        line, ok := next_inf_line(r);
        if !ok return "", false, true;
        if contains_nocase(line, "CLASS") return line, true, false;
        words := split_words(line);
        if !words continue;
        arg :: (words: [] string, i: int) -> string { return ifx i < words.count then words[i] else ""; }
        t = *inf.teleports[index];
        if equal_nocase(words[0], "SEQEND") return "", true, true;
        if equal_nocase(words[0], "TARGET:")  t.target = find_sector(arg(words, 1));
        if equal_nocase(words[0], "MOVE:") {
            t.destination = .{inf_fixed(arg(words, 1)), inf_fixed(arg(words, 2)), inf_fixed(arg(words, 3))};
            t.yaw = inf_angle(arg(words, 4));
        }
    }
    return "", false, true;
}

// A sign that's an animated texture with no frame rate is a switch: its frames are its
// states.
get_switch_frame_count :: (texture: s32) -> s32 {
    if texture < 0 || texture >= world.textures.count return 0;
    t := *world.textures[texture];
    if t.frame_rate != 0 || t.frames.count < 2 return 0;
    return xx t.frames.count;
}

// A nudge or a shot where it meets a wall, passed on to its mirror with the event doubled
// (0x56b34): a nudge's front becomes its back, and a shot (0x100) becomes 0x200, the
// landing event, so a shot's other side answers only to that. A wall with a sign only
// answers within the sign, give or take half a unit; the mirror is tested at the same
// distance along, though from its own left end, which is the other end of the wall.
send_wall_event_at :: (sector_index: s32, wall: *Wall, x: Fixed, z: Fixed, y: Fixed, entity: u32, event: u32) {
    sector := *world.level.sectors[sector_index];
    w0 := sector.vertices[wall.left];
    along := vec2_length(w0.x - x, w0.z - z);
    index: s32 = xx (wall - sector.walls.data);
    if is_on_sign(sector_index, wall, along, y)  send_to_wall(sector_index, index, entity, event, .TRIGGER);
    if wall.adjoin >= 0 && wall.mirror >= 0 {
        mirror := *world.level.sectors[wall.adjoin].walls[wall.mirror];
        if is_on_sign(wall.adjoin, mirror, along, y)  send_to_wall(wall.adjoin, wall.mirror, entity, event * 2, .TRIGGER);
    }
}

is_on_sign :: (sector_index: s32, wall: *Wall, along: Fixed, y: Fixed) -> bool {
    if wall.sign.texture < 0 || wall.sign.texture >= world.textures.count || !world.textures[wall.sign.texture].frames return true;
    image := *world.textures[wall.sign.texture].frames[0];
    u, base_height := get_sign_origin(sector_index, wall);
    if y {
        base := base_height + (wall.sign.offset.z >> 3);
        if base + FIXED_HALF < y || base - (image.height << 13) - FIXED_HALF > y return false;
    }
    if along {
        base := (wall.sign.offset.x - u) >> 3;
        if along < base - FIXED_HALF || along > base + (image.width << 13) + FIXED_HALF return false;
    }
    return true;
}

// What a sign is placed from (0x56b84): the texture offset of the part it's on, and that
// part's base height. The part is the one that showed at load (or at the last adjoin
// change); the height is as it is now.
get_sign_origin :: (sector_index: s32, wall: *Wall) -> u: Fixed, base: Fixed {
    sector := *world.level.sectors[sector_index];
    if wall.parts == WALL_PART_TOP && wall.adjoin >= 0 return wall.top.offset.x, world.level.sectors[wall.adjoin].ceiling.altitude;
    if wall.parts & WALL_PART_BOTTOM return wall.bottom.offset.x, sector.floor.altitude;
    return wall.mid.offset.x, sector.floor.altitude;
}

contains_nocase :: (s: string, word: string) -> bool {
    if word.count > s.count return false;
    for 0..s.count - word.count  if equal_nocase(slice(s, it, word.count), word) return true;
    return false;
}

#import "String";
