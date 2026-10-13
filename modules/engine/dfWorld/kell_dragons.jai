// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Kell dragons (LOGIC: KELL, 0x38cfc, its task 0x38f6c). Idle, a dragon looks every second
// for the player in sight; then it charges, turning to the player and running on, faster the
// farther off they are, the more it hurts and the fewer its hit points (0x39108). Within 20
// units and facing them it bites: 20 off health, and three times in ten it backs off for a
// moment. Within 55 and about level, half the times it comes round to face them it leaps at
// them instead, biting where it lands. Blocked, it backs off and turns quickly. Losing sight,
// it searches. Every hit hurts its 180 hit points and adds to its pain; one in five makes it
// flinch. Dying, it falls and leaves its corpse; as a boss it tells the level's "boss" sector.
//
// The task is written as the places it waits at, as the turret's is. A hit's flinch waits
// inside the message (0x3a19c, 0x3a324); hits that come meanwhile are lost.

#scope_module

Kell_Dragon :: struct {
    object: s32;
    move: *Free_Move;           // Its animation is the move's.
    hp: Fixed = 180 * FIXED_ONE;
    alive := true;
    state: Kell_State;
    pace: s32;                  // Into KELL_PACES (+0x104).
    pain: Fixed;                // Up to 100 (+0x108).
    pain_playing: Sound_Instance;
    backing: bool;              // Backing off, after being blocked or a bite (+0x110),
    backing_until: u32;         // until then.
    last_seen: Fixed2;
    collided_tick: u32;
    dying_sector: s32;

    // Charging (0x39328).
    facing: bool;               // It faced its target last frame.
    leap: bool;                 // Drawn each time it comes round to face it.

    // Searching (0x39a80).
    retarget: bool;
    retarget_tick: u32;
    last_seen_until: u32;
    search_delay: u32;
    saved_turn_speed: s32;      // Put back when the search ends.

    // A hit's flinch.
    flinching: bool;
    hit_message: s32;
    saved_anim: Actor_Anim;

    wait: Kell_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    in_message: bool;
    task: *Task;
}

Kell_State :: enum s32 { IDLE :: 0; CHARGE :: 1; BACK_OFF :: 2; LEAP :: 3; ATTACK :: 4; DIE :: 5; SEARCH :: 6; }

Kell_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: charging the next frame.
    CHARGE;                     // A frame at a time.
    BACK_OFF;
    LEAP;                       // A frame before crouching,
    CROUCH;                     // crouching,
    AIRBORNE;                   // in the air until it stops rising or falling,
    LAND;                       // landing.
    ATTACK;                     // A frame before the bite,
    BITE;                       // biting.
    SEARCH;
    DIE;                        // Its dying action playing,
    FALL;                       // then until it lands.
}

Kell_Assets :: struct {
    loaded: bool;
    see, jump, hurt, die, bite: Sound_Handle;  // KELL-1, KELLJUMP, KELL-8, KELL-7, KELL-5.
}

// Its paces, slowest first (0xe69f0): the running action's rate and the speed.
KELL_PACES :: struct { rate: s32; speed: Fixed; }.[
    .{5, 9 * FIXED_ONE}, .{7, 12 * FIXED_ONE}, .{8, 16 * FIXED_ONE}, .{10, 24 * FIXED_ONE},
];

// The O file's Kell dragon on an object (0x38cfc).
create_kell_dragon :: (object: s32) {
    a := *world.kell_assets;
    if !a.loaded {
        a.loaded = true;
        a.see = register_sound("KELL-1.VOC", 0x54);
        a.hurt = register_sound("KELL-8.VOC", 1);
        a.bite = register_sound("KELL-5.VOC", 1);
        a.jump = register_sound("KELLJUMP.VOC", 1);
        a.die = register_sound("KELL-7.VOC", 0x54);
    }
    k := New(Kell_Dragon);
    placed := false;
    for * world.kell_dragons  if !it.* { it.* = k; placed = true; break; }
    if !placed  array_add(*world.kell_dragons, k);
    create_object_task(.KELL_DRAGON, k, object, *k.task);
    o := world.objects[object];
    o.entity = ENTITY_AI_ACTOR | ENTITY_SMART;
    o.aimable = true;
    o.kell_dragon = k;
    k.object = object;
    m := create_free_move(object);
    k.move = m;
    // The movement's defaults (0x289b8), then a walker's that slides along what it meets.
    m.physics.step_up = 6 * FIXED_ONE;
    m.physics.step_down = 8 * FIXED_ONE;
    m.physics.width = o.width;
    m.physics.height = o.height + 0x8000;
    m.collision_flags = MOVE_NO_Y | MOVE_GRAVITY | MOVE_SLIDE;
    m.target.speed = 10 * FIXED_ONE;
    m.target.speed_vertical = FIXED_ONE;
    m.target.speed_rotation = 0x1AAA;
    m.anim.frame_rate = 5;
    m.anim.frame_count = FIXED_ONE;
    m.anim.prev_clock = 0;
    m.anim.flags = ANIM_READY;
    set_up_action_animation(o, 5, *m.anim);
}

unload_kell_dragons :: () {
    for world.kell_dragons  if it  free(it);
    array_free(world.kell_dragons);
    world.kell_assets = .{};
}

// Its task's turn (tasks.jai), if its time has come.
update_kell_dragon :: (k: *Kell_Dragon) {
    if k.wake < 0 || k.wake > world.clock.tick return;
    run_kell_dragon(k, 0);
}

// A message to a Kell dragon (0x1d8e5): its task runs from where it waits, at once, until it
// yields.
send_kell_dragon_message :: (k: *Kell_Dragon, message: Actor_Message) {
    k.in_message = true;
    run_kell_dragon(k, cast(s32) message);
    k.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

run_kell_dragon :: (k: *Kell_Dragon, message_in: s32) {
    message := message_in;
    o := world.objects[k.object];
    m := k.move;
    if k.flinching {
        // Hits meanwhile are lost.
        if message || !(m.anim.flags & ANIM_READY) { wait_kell(k, k.wait, 0); return; }
        m.anim = k.saved_anim;
        set_up_action_animation(o, m.anim.action, *m.anim);
        m.target.flags &= ~TARGET_FREEZE;
        k.flinching = false;
        message = k.hit_message;
    } else if k.wait != .START && k.wait != .IDLE_HIT && k.wait != .DIE && k.wait != .FALL {
        if !take_hit(k, *message) return;
    }
    ready := (m.anim.flags & ANIM_READY) != 0;
    if k.wait == {
        case .START;
            run_state(k);
        case .IDLE;
            if message == DAMAGE || message == EXPLOSION {
                k.state = .CHARGE;
                k.wake = 0;
                wait_kell(k, .IDLE_HIT, 0);
                return;
            }
            if message { wait_kell(k, .IDLE, 0x91); return; }
            if k.state == .IDLE && sees_player(k) {
                play_sound_at(world.kell_assets.see, o.position);
                k.state = .CHARGE;
            }
            if k.state == .IDLE { wait_kell(k, .IDLE, 0x91); return; }
            run_state(k);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_kell(k, .IDLE, 0x91); return; }
            run_state(k);
        case .CHARGE;
            if message { wait_kell(k, .CHARGE, 0); return; }
            if k.state == .CHARGE  charge(k);
            if k.state == .CHARGE { wait_kell(k, .CHARGE, 0); return; }
            m.anim.flags |= ANIM_READY;
            run_state(k);
        case .BACK_OFF;
            if message { wait_kell(k, .BACK_OFF, 0); return; }
            if k.state == .BACK_OFF  back_off(k);
            if k.state == .BACK_OFF { wait_kell(k, .BACK_OFF, 0); return; }
            m.anim.flags |= ANIM_READY;
            run_state(k);
        case .LEAP;
            if message { wait_kell(k, .LEAP, 0); return; }
            if k.state != .LEAP { run_state(k); return; }
            play_action(k, 9);
            play_sound_at(world.kell_assets.jump, o.position);
            wait_kell(k, .CROUCH, 0);
        case .CROUCH;
            if message || !ready { wait_kell(k, .CROUCH, 0); return; }
            leap_at_player(k);
            wait_kell(k, .AIRBORNE, 0);
        case .AIRBORNE;
            if message || m.velocity.y { wait_kell(k, .AIRBORNE, 0); return; }
            m.target.flags |= TARGET_FREEZE;
            m.velocity.x, m.velocity.z = 0, 0;
            play_action(k, 11);
            play_sound_at(world.kell_assets.bite, o.position);
            wait_kell(k, .LAND, 0);
        case .LAND;
            if message || !ready { wait_kell(k, .LAND, 0); return; }
            if is_player_within_reach(k)  apply_damage(20 * FIXED_ONE, 0, true);
            k.state = .CHARGE;
            run_state(k);
        case .ATTACK;
            if message { wait_kell(k, .ATTACK, 0); return; }
            if k.state == .ATTACK {
                if !world.player_state.dying {
                    play_action(k, 1);
                    wait_kell(k, .BITE, 0);
                    return;
                }
                k.state = .CHARGE;
            }
            m.target.flags &= ~TARGET_FREEZE;
            run_state(k);
        case .BITE;
            if message || !ready { wait_kell(k, .BITE, 0); return; }
            // The bite (0x3a018): in reach, 20 off health, and three times in ten it backs
            // off; otherwise it bites again. Out of reach, it charges.
            play_sound_at(world.kell_assets.bite, o.position);
            if is_player_within_reach(k) {
                apply_damage(20 * FIXED_ONE, 0, true);
                if fixed_random(100) < 31  k.state = .BACK_OFF;
            } else {
                k.state = .CHARGE;
            }
            if k.state == .ATTACK { wait_kell(k, .ATTACK, 0); return; }
            m.target.flags &= ~TARGET_FREEZE;
            run_state(k);
        case .SEARCH;
            if message { wait_kell(k, .SEARCH, 0); return; }
            // With the player dying it waits on.
            if k.state == .SEARCH && !world.player_state.dying  search(k);
            if k.state == .SEARCH { wait_kell(k, .SEARCH, 0); return; }
            m.anim.flags |= ANIM_READY;
            m.target.speed_rotation = k.saved_turn_speed;
            run_state(k);
        case .DIE;
            if message || !ready { wait_kell(k, .DIE, 0); return; }
            wait_kell(k, .FALL, 0);
        case .FALL;
            if message || !has_free_move_landed(m) { wait_kell(k, .FALL, 0); return; }
            die(k);
    }
}

// The task's loop (0x38f6c): into its state, until it waits.
run_state :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    tick := cast(u32) world.clock.tick;
    if k.state == {
        case .IDLE;
            wait_kell(k, .IDLE, 0x91);
        case .CHARGE;
            k.facing = false;
            k.collided_tick = 0;
            start_running(k);
            wait_kell(k, .CHARGE, 0);
        case .BACK_OFF;
            start_running(k);
            k.backing = false;
            wait_kell(k, .BACK_OFF, 0);
        case .LEAP;
            wait_kell(k, .LEAP, 0);
        case .ATTACK;
            m.target.flags |= TARGET_FREEZE;
            wait_kell(k, .ATTACK, 0);
        case .DIE;
            // Dying (0x3a55c): it stops where it's going, carried only by a blast.
            m.target.flags |= TARGET_FREEZE;
            play_sound_at(world.kell_assets.die, o.position);
            play_action(k, 2);
            k.dying_sector = o.sector;
            wait_kell(k, .DIE, 0);
        case .SEARCH;
            k.retarget = true;
            k.collided_tick = 0;
            k.retarget_tick = 0;
            k.last_seen_until = tick + 0x1111;
            k.search_delay = 72;
            k.saved_turn_speed = m.target.speed_rotation;
            m.anim.flags &= ~ANIM_ONCE;
            set_up_action_animation(o, 0, *m.anim);
            m.target.speed_rotation = 0x3000;
            m.target.flags &= ~TARGET_FREEZE;
            wait_kell(k, .SEARCH, 0);
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next.
wait_kell :: (k: *Kell_Dragon, wait: Kell_Wait, ticks: s32) {
    k.wait = wait;
    if k.in_message return;
    k.wake = ifx ticks < 0 then -1 else world.clock.tick + ticks;
}

// An action played once at rate 8, the rate set after the action's own.
play_action :: (k: *Kell_Dragon, action: s32) {
    m := k.move;
    m.anim.flags |= ANIM_ONCE;
    set_up_action_animation(world.objects[k.object], action, *m.anim);
    m.anim.frame_rate = 8;
}

// Running: its action, at the pace drawn from fastest six times in ten, slowest otherwise.
start_running :: (k: *Kell_Dragon) {
    m := k.move;
    m.anim.flags &= ~ANIM_ONCE;
    set_up_action_animation(world.objects[k.object], 0, *m.anim);
    set_pace(k, ifx fixed_random(100) < 61 then cast(s32) 3 else 0);
}

// The pace (0x39108): from the least, by distance (25, 45, 60 units), plus half of four
// times the pain and four times the hit points lost, out of 180; at most the fastest. A new
// pace changes the running action's rate and the speed.
set_pace :: (k: *Kell_Dragon, least: s32) {
    o := world.objects[k.object];
    p := *world.player;
    distance := dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
    by_distance: Fixed;
    if distance >= 60 * FIXED_ONE       by_distance = 3 * FIXED_ONE;
    else if distance >= 45 * FIXED_ONE  by_distance = 2 * FIXED_ONE;
    else if distance >= 25 * FIXED_ONE  by_distance = FIXED_ONE;
    hurt := mul16(div16(k.pain, 100 * FIXED_ONE), 4 * FIXED_ONE) + mul16(div16(180 * FIXED_ONE - k.hp, 180 * FIXED_ONE), 4 * FIXED_ONE);
    pace := min(((div16(hurt, 2 * FIXED_ONE) + by_distance + 0x8000) >> 16) + least, 3);
    if pace == k.pace return;
    k.pace = pace;
    m := k.move;
    m.anim.frame_rate = KELL_PACES[pace].rate;
    m.anim.prev_clock = world.anim_clocks[KELL_PACES[pace].rate];
    m.target.speed = KELL_PACES[pace].speed;
}

// A shot or blast (0x3a19c, 0x3a324): its hit points, and pain, 20 for a shot and 40 for a
// blast, up to 100; a blast pushes it, all its force if it kills, half otherwise. Killed, it
// dies at once; otherwise it roars, cutting off the last, and one time in five flinches.
// False while it flinches.
take_hit :: (k: *Kell_Dragon, message: *s32) -> bool {
    o := world.objects[k.object];
    m := k.move;
    e := *world.actor_state;
    if message.* == DAMAGE {
        k.hp -= e.message_projectile.damage;
        k.pain = min(k.pain + 20 * FIXED_ONE, 100 * FIXED_ONE);
    } else if message.* == EXPLOSION {
        k.pain = min(k.pain + 40 * FIXED_ONE, 100 * FIXED_ONE);
        k.hp -= e.message_damage;
        dir := get_explosion_push(.{o.position.x, o.position.y - o.height, o.position.z});
        push := Fixed3.{mul16(e.message_force, dir.x), mul16(e.message_force, dir.y), mul16(e.message_force, dir.z)};
        if k.hp < 1  m.velocity = push;
        else         m.velocity = .{push.x / 2, push.y / 2, push.z / 2};
    } else {
        return true;
    }
    if k.hp < 1 {
        k.state = .DIE;
        message.* = 0;
        return true;
    }
    stop_sound(k.pain_playing);
    k.pain_playing = play_sound_at(world.kell_assets.hurt, o.position);
    if fixed_random(100) >= 21 return true;
    m.target.flags |= TARGET_FREEZE;
    k.saved_anim = m.anim;
    play_action(k, 12);
    k.flinching = true;
    k.hit_message = message.*;
    wait_kell(k, k.wait, 0);
    return false;
}

// Whether it sees the player, remembering where (0x39a48).
sees_player :: (k: *Kell_Dragon) -> bool {
    if !can_see_player(world.objects[k.object]) return false;
    k.last_seen = .{world.player.position.x, world.player.position.z};
    return true;
}

// The player within 20 units, counting the height.
is_player_within_reach :: (k: *Kell_Dragon) -> bool {
    o := world.objects[k.object];
    p := *world.player;
    return abs(o.position.y - p.position.y) + dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) <= 20 * FIXED_ONE;
}

// A frame of the charge (0x39328). Seeing the player: facing them within 20 units it bites;
// within 55 and 10 of their height it leaps, if the draw made when it came round to face
// them, one in two, says so (the draw stands until it next comes round). Unseen, it
// searches. Then its pace, and on: blocked, a new way and backing off, turning quickly, for
// half a second; otherwise toward the player, or the player dying any way, its pace's speed
// ahead.
charge :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    p := *world.player;
    dying := world.player_state.dying;
    if !dying && sees_player(k) {
        facing := cast,no_check(s16) o.yaw == cast,no_check(s16) m.target.yaw;
        if facing {
            if !k.facing  k.leap = fixed_random(100) < 51;
            k.facing = true;
        } else {
            k.facing = false;
        }
        dy := abs(o.position.y - p.position.y);
        distance := dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) + dy;
        if distance <= 20 * FIXED_ONE && facing {
            k.state = .ATTACK;
        } else if k.leap && distance <= 55 * FIXED_ONE && facing {
            if dy <= 10 * FIXED_ONE  k.state = .LEAP;
        }
    } else if !dying {
        k.state = .SEARCH;
    }
    if k.state != .CHARGE return;
    set_pace(k, 0);
    m.target.flags &= ~TARGET_FREEZE;
    if is_blocked(o, m, *m.target) {
        turn_from_collision(o, m, *m.target, *k.collided_tick);
        k.backing = true;
        m.target.speed_rotation = 0x2C71;
        k.backing_until = cast(u32) world.clock.tick + 72;
        return;
    }
    if k.backing {
        if k.backing_until > cast(u32) world.clock.tick return;
        k.backing = false;
        m.target.yaw = vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    } else if !dying {
        m.target.yaw = vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    } else {
        m.target.yaw = fixed_random(0x3FD2);
    }
    run_ahead(k);
}

run_ahead :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    m.target.speed_rotation = 0x1AAA;
    m.target.flags |= TARGET_MOVE_ROT;
    m.target.position.x = o.position.x + mul16(sin_yaw, KELL_PACES[k.pace].speed);
    m.target.position.z = o.position.z + mul16(cos_yaw, KELL_PACES[k.pace].speed);
    m.target.flags |= TARGET_MOVE_XZ;
}

// A frame of backing off (0x39848): turned at once away from the player and on its pace's
// speed that way, for half a second; then charging.
back_off :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    p := *world.player;
    if !k.backing {
        m.target.yaw = (vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z) + 0x2000) & ANGLE_MASK;
        sin_yaw, cos_yaw := sin_cos(m.target.yaw);
        m.target.speed_rotation = 0;
        m.target.flags |= TARGET_MOVE_ROT;
        m.target.position.x = o.position.x + mul16(sin_yaw, KELL_PACES[k.pace].speed);
        m.target.position.z = o.position.z + mul16(cos_yaw, KELL_PACES[k.pace].speed);
        m.target.flags |= TARGET_MOVE_XZ;
        k.backing = true;
        k.backing_until = cast(u32) world.clock.tick + 72;
    } else if k.backing_until <= cast(u32) world.clock.tick {
        k.state = .CHARGE;
        k.backing = false;
    }
}

// Crouched (0x39d68): turned to the player at once, making for where they stand, and off
// the floor at 100 a second toward them, 2.5 degrees under the arc that would land there
// (0x255e4).
leap_at_player :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    p := *world.player;
    m.target.position.x, m.target.position.z = p.position.x, p.position.z;
    m.target.flags |= TARGET_MOVE_XZ;
    m.target.yaw = cast,no_check(s16) vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    o.yaw = m.target.yaw;
    m.target.flags |= TARGET_MOVE_ROT;
    speed := 100 * FIXED_ONE;
    distance := dist_approx(o.position.x, o.position.z, p.position.x, p.position.z);
    time := div16(distance, speed);
    // The original divides by the time unchecked.
    if !time return;
    rise := mul16(150 * FIXED_ONE, time >> 1);
    dy := o.position.y - p.position.y;
    pitch := vec2_to_angle(dy, distance);
    leap_pitch := cast,no_check(s16) (-455 + get_arcsine(div16(rise, speed)) + pitch);
    along := div16(dy + distance, time);
    sin_yaw, cos_yaw := sin_cos(cast,no_check(s16) o.yaw);
    sin_pitch, cos_pitch := sin_cos(leap_pitch);
    m.velocity.x = mul16(cos_pitch, mul16(sin_yaw, along));
    m.velocity.z = mul16(cos_pitch, mul16(cos_yaw, along));
    m.velocity.y = mul16(-sin_pitch, along);
}

// A frame of the search (0x39a80): as the phase-one dark trooper's, turning at 0x3000.
search :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    m := k.move;
    p := *world.player;
    tick := cast(u32) world.clock.tick;
    if sees_player(k) {
        k.state = .CHARGE;
        return;
    }
    if k.retarget_tick < tick || has_arrived(*m.target, o) {
        k.retarget = true;
        if has_arrived(*m.target, o)  k.last_seen_until = 0;
    }
    if k.retarget {
        k.retarget = false;
        eye := get_player_eye();
        x, z := eye.x, eye.z;
        if tick < k.last_seen_until  x, z = k.last_seen.x, k.last_seen.z;
        offset := abs(p.position.x - o.position.x) / 4;
        angle := cast(s32) cast,no_check(s16) vec2_to_angle(o.position.x - x, o.position.z - z);
        m.target.position.x, m.target.position.z = x, z;
        offset_target(*m.target.position.x, *m.target.position.z, offset, offset / 2, angle, 0xFFF);
        m.target.flags |= TARGET_MOVE_XZ;
        m.target.yaw = vec2_to_angle(m.target.position.x - o.position.x, m.target.position.z - o.position.z);
        m.target.pitch = 0;
        m.target.roll = 0;
        m.target.flags |= TARGET_MOVE_ROT;
        k.retarget_tick = tick + k.search_delay;
    }
    if is_blocked(o, m, *m.target) {
        turn_from_collision(o, m, *m.target, *k.collided_tick);
        k.search_delay += 72;
        if k.search_delay > 0x48D  k.search_delay = 72;
        k.retarget_tick = tick + k.search_delay;
    }
}

// Landed (0x3a55c): out of water its corpse, kept, in the sector it began dying in; the
// boss's death told; then it and its object go.
die :: (k: *Kell_Dragon) {
    o := world.objects[k.object];
    if world.level.sectors[k.dying_sector].second_altitude - 1 < 0 {
        index := add_object(.SPRITE, o.data, o.position, k.dying_sector);
        c := world.objects[index];
        c.anim = 4;
        c.frame = 0;
        c.entity |= ENTITY_CORPSE | ENTITY_KEPT_CORPSE;
    }
    k.alive = false;
    send_boss_killed(o);
    free_free_move(k.move);
    o.kell_dragon = null;
    free_object(k.object);
    for * world.kell_dragons  if it.* == k { it.* = null; break; }
    end_task(k.task);
    free(k);
}

#import "Basic";
#import "engine/dfFixed";
