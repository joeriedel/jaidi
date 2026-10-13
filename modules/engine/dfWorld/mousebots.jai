// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Mousebots (LOGIC: MOUSEBOT, 0x3a6e4, its task 0x3a8f8): a little droid that squeaks and
// scurries. Idle, it looks every second for the player within 25 units; then, or when hit, it
// runs about: ahead or back 22 units at a time, turning to a new heading at random each time
// it's done turning, and turning a quarter and reversing when it meets a wall. Losing the
// player for 5 s it settles down. Its 10 hit points gone, it squeals, lands, and pops into a
// wreck and a battery (none in water). It isn't aimed at.
//
// The task is written as the places it waits at, as the turret's is.

#scope_module

Mousebot :: struct {
    object: s32;
    move: *Free_Move;
    hp: Fixed = 10 * FIXED_ONE;
    alive := true;
    state: Mousebot_State;

    // Running about (0x3abd4).
    last_seen: s32;             // The tick it last saw the player.
    turning_left: bool;         // Which way it turned last.
    backing: bool;              // Going back rather than ahead.
    dying_sector: s32;          // Its sector when it began dying, where its wreck goes.

    wait: Mousebot_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    polling: bool;              // Waiting for the AI to come back on (cheats.jai).
    in_message: bool;
    task: *Task;
}

Mousebot_State :: enum s32 { IDLE :: 0; RUN :: 1; DIE :: 2; }

Mousebot_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: running the next frame.
    RUN;                        // A frame at a time.
    FALL;                       // Dying, a frame at a time until it lands.
}

Mousebot_Assets :: struct {
    squeak, hurt, squeal: Sound_Handle;     // EEEK-1, -2, -3.
    wreck: s32 = -1;                        // DEDMOUSE.FME, into frames.
}

// The O file's mousebot on an object (0x3a6e4).
create_mousebot :: (object: s32) {
    a := *world.mousebot_assets;
    if a.wreck < 0 {
        a.wreck = find_or_load_frame("DEDMOUSE.FME");
        a.squeak = register_sound("EEEK-1.VOC", 0x54);
        a.hurt = register_sound("EEEK-2.VOC", 1);
        a.squeal = register_sound("EEEK-3.VOC", 0x54);
    }
    b := New(Mousebot);
    placed := false;
    for * world.mousebots  if !it.* { it.* = b; placed = true; break; }
    if !placed  array_add(*world.mousebots, b);
    create_object_task(.MOUSEBOT, b, object, *b.task);
    o := world.objects[object];
    o.aimable = false;
    o.entity = ENTITY_AI_ACTOR | ENTITY_SMART;
    o.mousebot = b;
    b.object = object;
    m := create_free_move(object);
    b.move = m;
    // The movement's defaults (0x289b8) take the object's size before it has one, so its
    // moves meet walls only.
    m.physics.width = o.width;
    m.collision_flags = MOVE_NO_Y | MOVE_GRAVITY;
    m.target.speed_vertical = FIXED_ONE;
    o.width = get_model_radius(o) + FIXED_ONE;
    o.height = o.width >> 1;
    m.physics.height = o.height + 0x8000;
    m.target.speed = 22 * FIXED_ONE;
    m.target.speed_rotation = 0xC71;
    m.target.pitch, m.target.yaw, m.target.roll = o.pitch, o.yaw, o.roll;
}

unload_mousebots :: () {
    for world.mousebots  if it  free(it);
    array_free(world.mousebots);
}

// Its task's turn (tasks.jai), if its time has come.
update_mousebot :: (b: *Mousebot) {
    if !is_ai_task_due(*b.wake, *b.polling) return;
    run_mousebot(b, 0);
}

// A message to a mousebot (0x1d8e5): its task runs from where it waits, at once, until it
// yields.
send_mousebot_message :: (b: *Mousebot, message: Actor_Message) {
    b.in_message = true;
    run_mousebot(b, cast(s32) message);
    b.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

run_mousebot :: (b: *Mousebot, message_in: s32) {
    message := message_in;
    if b.wait == {
        case .START;
            run_state(b);
        case .IDLE;
            take_damage(b, *message);
            if message == DAMAGE || message == EXPLOSION {
                b.state = .RUN;
                b.wake = 0;
                wait_mousebot(b, .IDLE_HIT, 0);
                return;
            }
            if message { wait_mousebot(b, .IDLE, 0x91); return; }
            o := world.objects[b.object];
            if b.state == .IDLE && is_player_visible(o, 0x4000, 25 * FIXED_ONE) {
                play_sound_at(world.mousebot_assets.squeak, o.position);
                b.state = .RUN;
            }
            if b.state == .IDLE { wait_mousebot(b, .IDLE, 0x91); return; }
            run_state(b);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_mousebot(b, .IDLE, 0x91); return; }
            run_state(b);
        case .RUN;
            take_damage(b, *message);
            if message { wait_mousebot(b, .RUN, 0); return; }
            if b.state == .RUN  scurry(b);
            if b.state == .RUN { wait_mousebot(b, .RUN, 0); return; }
            run_state(b);
        case .FALL;
            if !has_free_move_landed(b.move) || message { wait_mousebot(b, .FALL, 0); return; }
            break_up(b);
    }
}

// The task's loop (0x3a8f8): on into its state, until it waits.
run_state :: (b: *Mousebot) {
    o := world.objects[b.object];
    m := b.move;
    if b.state == {
        case .IDLE;
            wait_mousebot(b, .IDLE, 0x91);
        case .RUN;
            m.target.position.x = o.position.x;
            m.target.position.y = o.position.y;
            m.target.position.z = o.position.z;
            m.target.yaw = o.yaw;
            b.last_seen = world.clock.tick;
            wait_mousebot(b, .RUN, 0);
        case .DIE;
            // Dying (0x3afe8): it stops where it's going, carried only by a blast.
            m.target.flags |= TARGET_FREEZE;
            b.dying_sector = o.sector;
            play_sound_at(world.mousebot_assets.squeal, o.position);
            wait_mousebot(b, .FALL, 0);
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next, and the AI
// switched off makes it a wait for it (cheats.jai).
wait_mousebot :: (b: *Mousebot, wait: Mousebot_Wait, ticks: s32) {
    b.wait = wait;
    yield_ai_task(*b.wake, *b.polling, ticks, b.in_message);
}

// Shots (0x3ae64) and blasts (0x3aecc): hurt, it squeaks; killed, it dies, and the message
// counts as a run. A blast sets it moving, half as hard if it lives.
take_damage :: (b: *Mousebot, message: *s32) {
    if !b.alive return;
    o := world.objects[b.object];
    if message.* == DAMAGE {
        b.hp -= world.actor_state.message_projectile.damage;
    } else if message.* == EXPLOSION {
        e := *world.actor_state;
        b.hp -= e.message_damage;
        dir := get_explosion_push(.{o.position.x, o.position.y - o.height, o.position.z});
        push := Fixed3.{mul16(e.message_force, dir.x), mul16(e.message_force, dir.y), mul16(e.message_force, dir.z)};
        if b.hp < 1  b.move.velocity = push;
        else         b.move.velocity = .{push.x / 2, push.y / 2, push.z / 2};
    } else {
        return;
    }
    if b.hp < 1 {
        b.state = .DIE;
        message.* = 0;
    } else {
        play_sound_at(world.mousebot_assets.hurt, o.position);
    }
}

// A frame of running about (0x3abd4).
scurry :: (b: *Mousebot) {
    o := world.objects[b.object];
    m := b.move;
    tick := world.clock.tick;
    if !is_player_visible(o, 0x4000, 25 * FIXED_ONE) {
        if tick - b.last_seen > 0x2D8  b.state = .IDLE;
    } else {
        b.last_seen = tick;
    }
    if b.state != .RUN return;
    // Done turning: a new heading up to nearly a turn either way, the way by the tick, and
    // a new turning speed; ahead again.
    if (o.yaw & ANGLE_MASK) == (m.target.yaw & ANGLE_MASK) {
        b.turning_left = (tick & 1) != 0;
        turn := fixed_random(0x3FD2);
        m.target.yaw = cast,no_check(s16) (ifx b.turning_left then o.yaw + turn else o.yaw - turn);
        m.target.speed_rotation = cast,no_check(s16) (fixed_random(0x3555) + 0x555);
        m.target.flags |= TARGET_MOVE_ROT;
        b.backing = false;
    }
    // Met a wall: a quarter turn and the other way, now and then a squeak.
    if m.physics.wall {
        if fixed_random(100) < 11  play_sound_at(world.mousebot_assets.squeak, o.position);
        quarter: s32 = ifx b.turning_left then cast(s32) 0x1000 else -0x1000;
        m.target.yaw = cast,no_check(s16) (m.target.yaw + quarter);
        m.target.speed_rotation = cast,no_check(s16) fixed_random(0x3555);
        b.backing = !b.backing;
    }
    distance: Fixed = ifx b.backing then -22 * FIXED_ONE else 22 * FIXED_ONE;
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    m.target.position.x = o.position.x + mul16(sin_yaw, distance);
    m.target.position.z = o.position.z + mul16(cos_yaw, distance);
    m.target.speed = 22 * FIXED_ONE;
    m.target.flags |= TARGET_MOVE_XZ;
}

// Landed (0x3afe8): a puff, and out of water the wreck and a battery; then it and its object
// go. The wreck goes into the sector it began dying in, wherever a blast has carried it since.
break_up :: (b: *Mousebot) {
    o := world.objects[b.object];
    spawn_hit_effect(HIT_EFFECT_SMALL, o.sector, o.position, b.object);
    if world.level.sectors[o.sector].second_altitude - 1 < 0 {
        wreck := add_object(.FRAME, world.mousebot_assets.wreck, o.position, b.dying_sector);
        c := world.objects[wreck];
        c.entity |= ENTITY_CORPSE;
        create_item(ITEM_BATTERY, o.sector, o.position);
    }
    b.alive = false;
    free_free_move(b.move);
    o.mousebot = null;
    free_object(b.object);
    for * world.mousebots  if it.* == b { it.* = null; break; }
    end_task(b.task);
    free(b);
}

// The model's radius as the original's loader takes it (0x580c8): its farthest vertex, by
// the fixed square root of the 16.16 coordinates squared, each rounded from the file.
get_model_radius :: (o: *Object) -> Fixed {
    if o.class != .MODEL || o.data < 0 || o.data >= world.models.count return 0;
    radius: Fixed;
    for world.models[o.data].model.vertices {
        x := to_fixed_rounded(it.x);
        y := to_fixed_rounded(it.y);
        z := to_fixed_rounded(it.z);
        radius = max(radius, fixed_sqrt(mul16(z, z) + mul16(x, x) + mul16(y, y)));
    }
    return radius;
}

// To 16.16, rounded to the nearest, a half to even, as the x87 does.
to_fixed_rounded :: (f: float) -> Fixed {
    v := cast(float64) f * 65536.0;
    r := floor(v);
    d := v - r;
    if d > 0.5 || (d == 0.5 && (cast(s64) r) & 1)  r += 1;
    return cast(Fixed) r;
}

#import "Basic";
#import "Math";
#import "engine/dfFixed";
