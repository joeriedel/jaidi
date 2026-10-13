// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Turrets (LOGIC: TURRET, 0x33fc4, its task 0x341b4): a gun hung from the ceiling. Idle, it
// looks every second for the player within 70 units, or in sight within 140; then it turns
// to the player, its pitch kept within 40 degrees of where it was hung, and fires a turret
// bolt, scattered, each time it's lined up, every half second. Losing the player for 3 s it
// turns back. Shot down below 8 of its 60 hit points it spins at random, firing wherever it
// faces, until it blows up.
//
// The task is written as the places it waits at. Messages (shots, blasts) are taken in where
// it waits, and as with every task they don't restart the wait they came in; one that leaves
// it to go on runs it on, in the sender's turn. Its own movement module turns it.

#scope_module

Turret :: struct {
    object: s32;
    move: *Free_Move;
    hp: Fixed = 60 * FIXED_ONE;
    alive := true;
    state: Turret_State;
    home_pitch, home_yaw: s32;  // Where it was hung facing.
    give_up_tick: s32;          // When aiming at nothing it turns back.

    wait: Turret_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    in_message: bool;
    task: *Task;
}

Turret_State :: enum s32 { IDLE :: 0; FIRE :: 1; AIM :: 2; HOME :: 3; SPIN :: 4; DIE :: 5; }

// Where the task waits.
Turret_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: on to aiming the next frame.
    AIM;                        // 72 ticks between looks.
    HOME;                       // A frame at a time, turning back.
    SPIN;                       // A frame at a time, spinning.
    DIE;                        // The frame it blew up.
    DONE;                       // Gone once a frame runs it.
}

// The O file's turret on an object (0x33fc4).
create_turret :: (object: s32) {
    if !world.turret_sound  world.turret_sound = register_sound("TURRET-1.VOC", 0x48);
    t := New(Turret);
    placed := false;
    for * world.turrets  if !it.* { it.* = t; placed = true; break; }
    if !placed  array_add(*world.turrets, t);
    create_object_task(.TURRET, t, object, *t.task);
    o := world.objects[object];
    o.entity = ENTITY_AI_ACTOR;
    o.aimable = true;
    o.turret = t;
    // Hung from its place: it reaches 2 units down.
    o.width, o.height = 3 * FIXED_ONE, -2 * FIXED_ONE;
    t.object = object;
    t.home_pitch, t.home_yaw = o.pitch, o.yaw;
    m := create_free_move(object);
    t.move = m;
    m.physics.width = o.width;
    m.physics.height = o.height + 0x8000;
    m.target.pitch, m.target.yaw, m.target.roll = o.pitch, o.yaw, o.roll;
    m.target.speed_rotation = 0x1E38;
}

unload_turrets :: () {
    for world.turrets  if it  free(it);
    array_free(world.turrets);
}

// Its task's turn (tasks.jai), if its time has come.
update_turret :: (t: *Turret) {
    if t.wake < 0 || t.wake > world.clock.tick return;
    run_turret(t, 0);
}

// A message to a turret (0x1d8e5): its task runs from where it waits, at once, until it
// yields.
send_turret_message :: (t: *Turret, message: Actor_Message) {
    t.in_message = true;
    run_turret(t, cast(s32) message);
    t.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

run_turret :: (t: *Turret, message_in: s32) {
    message := message_in;
    if t.wait == {
        case .START;
            run_state(t);
        case .IDLE;
            take_damage(t, *message);
            if message == DAMAGE || message == EXPLOSION {
                t.state = .AIM;
                t.wake = 0;
                wait_turret(t, .IDLE_HIT, 0);
                return;
            }
            if message { wait_turret(t, .IDLE, 0x91); return; }
            if t.state == .IDLE && is_player_close(t)  t.state = .AIM;
            if t.state == .IDLE { wait_turret(t, .IDLE, 0x91); return; }
            run_state(t);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_turret(t, .IDLE, 0x91); return; }
            run_state(t);
        case .AIM;
            take_damage(t, *message);
            if message { wait_turret(t, .AIM, 72); return; }
            if t.state == .AIM && is_lined_up(t)  look_again(t);
            if t.state == .AIM { wait_turret(t, .AIM, 72); return; }
            run_state(t);
        case .HOME;
            take_damage(t, *message);
            if message { wait_turret(t, .HOME, 0); return; }
            if t.state == .HOME && is_lined_up(t)  t.state = .IDLE;
            if t.state == .HOME { wait_turret(t, .HOME, 0); return; }
            run_state(t);
        case .SPIN;
            take_damage(t, *message);
            if message { wait_turret(t, .SPIN, 0); return; }
            if t.state == .SPIN && is_lined_up(t)  fire_wild(t);
            if t.state == .SPIN { wait_turret(t, .SPIN, 0); return; }
            run_state(t);
        case .DIE;
            t.alive = false;
            if message { wait_turret(t, .DONE, 0); return; }
            remove_turret(t);
        case .DONE;
            if message { wait_turret(t, .DONE, 0); return; }
            remove_turret(t);
    }
}

// The task's loop (0x341b4): on into its state, until it waits.
run_state :: (t: *Turret) {
    while true {
        if t.state == {
            case .IDLE;
                wait_turret(t, .IDLE, 0x91);
                return;
            case .FIRE;
                fire_at_player(t);
            case .AIM;
                aim_at_player(t);
                t.give_up_tick = world.clock.tick + 0x1B4;
                wait_turret(t, .AIM, 72);
                return;
            case .HOME;
                m := t.move;
                m.target.pitch, m.target.yaw = t.home_pitch, t.home_yaw;
                m.target.flags = (m.target.flags & ~TARGET_MOVE_XZ) | TARGET_MOVE_ROT;
                wait_turret(t, .HOME, 0);
                return;
            case .SPIN;
                wait_turret(t, .SPIN, 0);
                return;
            case .DIE;
                o := world.objects[t.object];
                spawn_hit_effect(HIT_EFFECT_EXPLOSION_HARMLESS, o.sector, o.position, t.object);
                wait_turret(t, .DIE, 0);
                return;
        }
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next.
wait_turret :: (t: *Turret, wait: Turret_Wait, ticks: s32) {
    t.wait = wait;
    if t.in_message return;
    t.wake = ifx ticks < 0 then -1 else world.clock.tick + ticks;
}

// Shots and blasts (0x34b1c, 0x34b84): under 8 hit points it spins, at none it blows up; then
// the message counts as a run.
take_damage :: (t: *Turret, message: *s32) {
    if !t.alive return;
    if message.* == DAMAGE       t.hp -= world.actor_state.message_projectile.damage;
    else if message.* == EXPLOSION  t.hp -= world.actor_state.message_damage;
    else return;
    if t.hp < 1 {
        t.state = .DIE;
        message.* = 0;
    } else if t.hp < 8 * FIXED_ONE {
        t.state = .SPIN;
        message.* = 0;
    }
}

// Whether the player is about: seen all round within 70 units, and no more than 140 off,
// counting the height (0x34408).
is_player_close :: (t: *Turret) -> bool {
    if world.player_state.dying || !is_player_visible(world.objects[t.object], 0x4000, 70 * FIXED_ONE) return false;
    return is_within_range(t);
}

is_within_range :: (t: *Turret) -> bool {
    o := world.objects[t.object];
    p := *world.player;
    return dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) + abs(o.position.y - p.position.y) <= 140 * FIXED_ONE;
}

is_lined_up :: (t: *Turret) -> bool {
    o := world.objects[t.object];
    return t.move.target.yaw == o.yaw && t.move.target.pitch == o.pitch;
}

// Toward the player, the pitch a unit under the eye and within 40 degrees of its own (0x3451c).
aim_at_player :: (t: *Turret) {
    o := world.objects[t.object];
    p := *world.player;
    m := t.move;
    m.target.yaw = vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z) & ANGLE_MASK;
    m.target.pitch = get_aim_pitch(t);
    m.target.flags = (m.target.flags & ~TARGET_MOVE_XZ) | TARGET_MOVE_ROT;
}

get_aim_pitch :: (t: *Turret) -> s32 {
    o := world.objects[t.object];
    p := *world.player;
    distance := dist_approx(o.position.x, o.position.z, p.position.x, p.position.z);
    pitch := vec2_to_angle(o.position.y - (get_player_eye().y + FIXED_ONE), distance);
    off := clamp(get_angle_difference(t.home_pitch, pitch), -0x71C, 0x71C);
    return (off + t.home_pitch) & ANGLE_MASK;
}

// Lined up (0x3451c): with the player seen and close, fire when it's ahead or a little to
// the right (the original takes the difference as unsigned), otherwise aim again. Seen but
// farther off, it waits on; unseen, it turns back once its time is up.
look_again :: (t: *Turret) {
    o := world.objects[t.object];
    if !world.player_state.dying && is_player_visible(o, 0x4000, 70 * FIXED_ONE) {
        if !is_within_range(t) return;
        p := *world.player;
        angle := vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
        if (get_angle_difference(o.yaw, angle) & ANGLE_MASK) < 0xC71 {
            t.state = .FIRE;
        } else {
            aim_at_player(t);
            t.give_up_tick = world.clock.tick + 0x1B4;
        }
        return;
    }
    if t.give_up_tick <= world.clock.tick  t.state = .HOME;
}

// A bolt from 0.3 units ahead of it at a unit under the player's eye, each part of its
// velocity scattered by up to 5 either way (0x347bc).
fire_at_player :: (t: *Turret) {
    proj := fire_bolt(t);
    if proj {
        eye := get_player_eye();
        aim_projectile(proj, .{eye.x, eye.y + FIXED_ONE, eye.z});
        proj.velocity.x += fixed_random(10 * FIXED_ONE) - 5 * FIXED_ONE;
        proj.velocity.y += fixed_random(10 * FIXED_ONE) - 5 * FIXED_ONE;
        proj.velocity.z += fixed_random(10 * FIXED_ONE) - 5 * FIXED_ONE;
    }
    t.state = .AIM;
}

// Spinning (0x348f0): a bolt the way it faces, then a new way at random, faster.
fire_wild :: (t: *Turret) {
    o := world.objects[t.object];
    proj := fire_bolt(t);
    if proj  turn_projectile(proj, o.pitch, o.yaw);
    m := t.move;
    m.target.yaw = fixed_random(0x4000);
    m.target.pitch = -fixed_random(0x71C) & ANGLE_MASK;
    m.target.speed_rotation = 0x3000;
    m.target.flags = (m.target.flags & ~TARGET_MOVE_XZ) | TARGET_MOVE_ROT;
}

fire_bolt :: (t: *Turret) -> *Projectile {
    o := world.objects[t.object];
    ahead := rotate_vector(.{0, 0, 0x4CCC}, get_weapon_matrix(-o.pitch, -o.yaw));
    at := Fixed3.{o.position.x + ahead.x, o.position.y + ahead.y, o.position.z + ahead.z};
    proj := create_projectile(.TURRET_BOLT, o.sector, at, t.object);
    play_sound_at(world.turret_sound, at);
    if !proj return null;
    proj.last_hit = t.object;
    proj.exclude = t.object;
    p := world.objects[proj.object];
    p.pitch, p.yaw = o.pitch, o.yaw;
    return proj;
}

// The task ends (0x341b4): the turret and its object go.
remove_turret :: (t: *Turret) {
    free_free_move(t.move);
    o := world.objects[t.object];
    o.turret = null;
    free_object(t.object);
    for * world.turrets  if it.* == t { it.* = null; break; }
    end_task(t.task);
    free(t);
}

#import "Basic";
#import "engine/dfFixed";
