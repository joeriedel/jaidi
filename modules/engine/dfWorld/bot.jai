// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// A player for footage and tests: each frame it fills in the input a player would give, from
// what it can see. It plays like an unhurried player rather than a sharp one: it notices an
// enemy after a moment, turns to it with a hand's ease (speeding up and slowing down, a little
// off the mark), fires once roughly on target, sticks with that enemy until it's down or long
// out of sight, takes a breath before the next, and strafes from side to side, keeping its
// distance. With none in sight it goes to the nearest one it knows of, sector by sector
// through the openings. Built for fixed-step runs, so it looks at everything every frame. It
// draws on nothing of the game's own random numbers.

world_reset_bot :: () {
    bot = .{};
}

world_get_bot_input :: (input: *World_Input) {
    b := *bot;
    p := *world.player;
    b.frame += 1;
    if p.sector < 0 return;
    input.run = true;

    eye := Fixed3.{p.position.x, p.position.y - p.height + FIXED_ONE, p.position.z};

    // The enemy it's fighting stays the target while it lives and hasn't been out of sight
    // too long; otherwise, after a pause, the nearest one in sight. The nearest of all is
    // where to go when none is in sight.
    nearest_seen, known: s32 = -1, -1;
    nearest_distance, known_distance := FIXED_INFINITY, FIXED_INFINITY;
    target_alive, target_seen := false, false;
    for o, index: world.objects {
        if !is_bot_enemy(o) continue;
        distance := dist_approx(o.position.x, o.position.z, p.position.x, p.position.z);
        if distance < known_distance  known, known_distance = xx index, distance;
        seen := distance <= BOT_SIGHT && can_line_reach(p.sector, o.sector, eye, get_bot_aim_point(o));
        if index == b.target { target_alive = true; target_seen = seen; }
        if seen && distance < nearest_distance  nearest_seen, nearest_distance = xx index, distance;
    }
    if b.target >= 0 {
        if target_seen  b.target_last_seen = b.frame;
        if !target_alive {
            b.target = -1;
            b.look_from = b.frame + 20 + get_bot_random(b) % 25;      // A breath after a kill.
        } else if b.frame - b.target_last_seen > 45 {
            b.target = -1;
        }
    }
    if b.target < 0 && nearest_seen >= 0 && b.frame >= b.look_from {
        b.target = nearest_seen;
        b.target_last_seen = b.frame;
        b.react_until = b.frame + 15 + get_bot_random(b) % 15;       // Noticing it.
    }

    moving := is_bot_stuck(b, p);

    if b.target >= 0 {
        o := world.objects[b.target];
        aim := get_bot_aim_point(o);
        reacting := b.frame < b.react_until;
        // A slow, slight wander about the mark, as a hand on a mouse has.
        t := cast(float) b.frame;
        wander := sin(t * 0.045) * 70 + sin(t * 0.11 + 1.3) * 35;
        yaw_off: s32;
        if reacting  yaw_off = ease_bot_turn(input, b, 0);
        else         yaw_off = turn_bot_toward(input, b, p, aim.x, aim.z, wander);
        if !reacting  pitch_bot_toward(input, b, p, eye, aim);
        on_target := !reacting && target_seen && abs(yaw_off) < BOT_ON_TARGET;
        distance := fixed_to_float(dist_approx(o.position.x, o.position.z, p.position.x, p.position.z));

        if world.weapon.current == WEAPON_DETONATOR {
            // Held longer the farther the throw, then let go; a pause between throws.
            if on_target && !b.holding && b.frame >= b.next_throw {
                b.holding = true;
                b.hold_until = b.frame + cast(s32) clamp(distance / 3, 4, 50);
            }
            if b.holding {
                input.fire = true;
                if b.frame >= b.hold_until { input.fire = false; b.holding = false; b.next_throw = b.frame + 60; }
            }
        } else {
            input.fire = on_target;
        }

        // Keep the distance, with some give either way, and dodge from side to side, now and
        // then standing still.
        if distance > BOT_FAR                         b.closing = true;
        else if distance < (BOT_NEAR + BOT_FAR) / 2   b.closing = false;
        if b.closing                  input.forward = true;
        else if distance < BOT_NEAR   input.back = true;
        if b.frame >= b.strafe_until || moving == .STUCK {
            if b.strafe == 0  b.strafe = ifx get_bot_random(b) % 2 then cast(s32) 1 else -1;
            else              b.strafe = -b.strafe;
            if moving != .STUCK && get_bot_random(b) % 4 == 0  b.strafe = 0;
            b.strafe_until = b.frame + 60 + get_bot_random(b) % 90;
        }
        if b.strafe > 0  input.right = true;
        if b.strafe < 0  input.left = true;
        return;
    }

    // None in sight: toward the nearest known one, through the openings on the way to its
    // sector; else on through the level.
    waypoint_x, waypoint_z: Fixed;
    has_waypoint := false;
    if known >= 0 {
        o := world.objects[known];
        if o.sector == p.sector {
            waypoint_x, waypoint_z = o.position.x, o.position.z;
            has_waypoint = true;
        } else {
            wall := find_bot_path(p.sector, o.sector);
            if wall >= 0 {
                s := *world.level.sectors[p.sector];
                w := *s.walls[wall];
                l, r := s.vertices[w.left], s.vertices[w.right];
                waypoint_x, waypoint_z = (l.x + r.x) / 2, (l.z + r.z) / 2;
                has_waypoint = true;
            }
        }
    }
    if moving == .STUCK  b.turn_away_until = b.frame + 30 + get_bot_random(b) % 30;
    off: s32;
    if b.frame < b.turn_away_until  off = ease_bot_turn(input, b, BOT_TURN / 2);
    else if has_waypoint            off = turn_bot_toward(input, b, p, waypoint_x, waypoint_z, 0);
    else                            off = ease_bot_turn(input, b, 0);
    pitch_bot_level(input, b, p);
    if b.frame >= b.turn_away_until && abs(off) < 2048  input.forward = true;
}

#scope_file

BOT_SIGHT     :: 200 * FIXED_ONE;   // How far it looks for enemies.
BOT_NEAR      :: 25.0;              // Closer than this it backs off,
BOT_FAR       :: 60.0;              // farther it closes in.
BOT_ON_TARGET :: 300;               // Fires within this of the target's yaw (6.6 degrees).
BOT_TURN      :: 90.0;              // Its fastest turn, angle units a frame (about 120 a second).
BOT_SPRING    :: 0.12;              // How hard it pulls toward the mark: critically damped,
                                    // it settles in about half a second.

Bot :: struct {
    frame: s32;
    target: s32 = -1;
    target_last_seen: s32;
    react_until, look_from: s32;
    yaw_speed, pitch_speed: float;  // The hand's motion, angle units a frame.
    strafe: s32;                    // 1 right, -1 left, 0 none.
    strafe_until: s32;
    closing: bool;
    holding: bool;                  // A detonator held back.
    hold_until, next_throw: s32;
    turn_away_until: s32;
    last_position: Fixed3;
    still_frames: s32;
    random: u32 = 0x2545F491;
}

bot: Bot;

Bot_Motion :: enum { MOVING; STUCK; }

is_bot_enemy :: (o: *Object) -> bool {
    if !o.used || !o.aimable || o.sector < 0 return false;
    if o.entity & (ENTITY_CORPSE | ENTITY_PROJECTILE) return false;
    if o.actor && world_get_actor_hp(o.actor) <= 0 return false;
    return true;
}

// Pressing to move but going nowhere for a while.
is_bot_stuck :: (b: *Bot, p: *Player) -> Bot_Motion {
    moved := dist_approx(p.position.x, p.position.z, b.last_position.x, b.last_position.z);
    b.last_position = p.position;
    if moved < FIXED_ONE / 16  b.still_frames += 1;
    else                       b.still_frames = 0;
    if b.still_frames < 12 return .MOVING;
    b.still_frames = 0;
    return .STUCK;
}

get_bot_random :: (b: *Bot) -> s32 {
    b.random ^= b.random << 13;
    b.random ^= b.random >> 17;
    b.random ^= b.random << 5;
    return cast(s32) (b.random & 0x7FFF_FFFF);
}

// Toward the middle of what it aims at.
get_bot_aim_point :: (o: *Object) -> Fixed3 {
    return .{o.position.x, o.position.y - o.height / 2, o.position.z};
}

// Turns toward a place (with an offset, in angle units) as a hand moves a mouse: a spring
// pulling toward the mark against the motion it already has, no faster than BOT_TURN.
// Returns how far off it is.
turn_bot_toward :: (input: *World_Input, b: *Bot, p: *Player, x: Fixed, z: Fixed, offset: float) -> s32 {
    want := vec2_to_angle(x - p.position.x, z - p.position.z) & ANGLE_MASK;
    off := ((want - p.yaw + 8192) & ANGLE_MASK) - 8192;
    pull := cast(float) off + offset;
    b.yaw_speed += BOT_SPRING * BOT_SPRING * pull - 2 * BOT_SPRING * b.yaw_speed;
    b.yaw_speed = clamp(b.yaw_speed, -BOT_TURN, BOT_TURN);
    input.mouse_x += b.yaw_speed / MOUSE_TURN;
    return off;
}

// Eases the turn toward a steady speed (0 to come to rest).
ease_bot_turn :: (input: *World_Input, b: *Bot, speed: float) -> s32 {
    b.yaw_speed += (speed - b.yaw_speed) * 0.1;
    input.mouse_x += b.yaw_speed / MOUSE_TURN;
    return 0;
}

pitch_bot_toward :: (input: *World_Input, b: *Bot, p: *Player, eye: Fixed3, aim: Fixed3) {
    distance := dist_approx(eye.x, eye.z, aim.x, aim.z);
    want := vec2_to_angle(eye.y - aim.y, distance);
    want = clamp(((want + 8192) & ANGLE_MASK) - 8192, -PITCH_LIMIT, PITCH_LIMIT);
    pitch_bot_to(input, b, cast(float) (want - p.pitch));
}

pitch_bot_level :: (input: *World_Input, b: *Bot, p: *Player) {
    pitch_bot_to(input, b, cast(float) -p.pitch);
}

// The same spring up and down, gentler.
pitch_bot_to :: (input: *World_Input, b: *Bot, off: float) {
    spring := BOT_SPRING * 0.8;
    b.pitch_speed += spring * spring * off - 2 * spring * b.pitch_speed;
    b.pitch_speed = clamp(b.pitch_speed, -BOT_TURN / 2, BOT_TURN / 2);
    input.mouse_y -= b.pitch_speed / MOUSE_TURN;
}

// The first wall to go through on the way from one sector to another: a search out through
// the openings a player fits through and can step up.
find_bot_path :: (from: s32, to: s32) -> s32 {
    sectors := world.level.sectors;
    came_from := NewArray(sectors.count, s32,, temp);
    by_wall := NewArray(sectors.count, s32,, temp);
    for * came_from  it.* = -1;
    came_from[from] = from;
    queue: [..] s32;
    queue.allocator = temp;
    array_add(*queue, from);
    head := 0;
    while head < queue.count {
        s := queue[head];
        head += 1;
        if s == to break;
        sector := *sectors[s];
        for w, wall_index: sector.walls {
            n := w.adjoin;
            if n < 0 || came_from[n] >= 0 continue;
            next := *sectors[n];
            floor := max(sector.floor.altitude, next.floor.altitude);
            if sector.floor.altitude - next.floor.altitude > PLAYER_STEP continue;
            if floor - min(sector.ceiling.altitude, next.ceiling.altitude) < PLAYER_HEIGHT && !(next.flags[0] & SECTOR_DOOR) continue;
            came_from[n] = s;
            by_wall[n] = xx wall_index;
            array_add(*queue, n);
        }
    }
    if came_from[to] < 0 return -1;
    s := to;
    while came_from[s] != from  s = came_from[s];
    return by_wall[s];
}
