// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dark troopers.
//
// Phase one (LOGIC: D_TROOP1, 0x3be2c, its task 0x3c078) carries a blade and a shield arm.
// Idle, it looks every second for the player in sight; then it charges, turning to the
// player and running 30 units at a time, and once within 15 and facing them it swings: 20 off
// health if they're still within 15, and it circles the player 15 units off, swinging again
// now and then, until it loses them, is blocked or they get away. Losing sight while
// charging, it searches about where it last saw them. Seven shots in ten glance off its arm,
// back the way they came; the rest take its 180 hit points, now and then making it flinch. A
// blast always hurts it (a thermal detonator's by half) and pushes it.
//
// Phase two (LOGIC: D_TROOP2, 0x3d804, its task 0x3da40) has a jetpack, a missile launcher
// and a plasma cannon, and 350 hit points. Charging, four times in ten it takes off and flies
// at the player at 60, keeping 2 units above their feet; otherwise it walks at 15. Now and
// then it looks: within 100 units and facing them, it lands and fires a missile or, six times
// in ten, a burst of 1 to 20 plasma bolts led at the player, a fifth of a second apart; then
// it circles 100 units off, firing again now and then. It searches flying. Every hit hurts
// it; one in ten makes it flinch. Dying, it also leaves plasma and missiles.
//
// Phase three (LOGIC: D_TROOP3, 0x3f5b4, its task 0x3f7f0) is General Mohc in his armor, with
// 750 hit points: phase two's, walking at 25 and flying at 70, but in place of a missile it
// fires six homing missiles in a fan, and dying it tells the level's "mohc" sector rather
// than "boss" and leaves no items.
//
// Dying, a trooper falls to the floor and leaves its corpse; marked a boss, it tells the
// level's "boss" sector.
//
// The task is written as the places it waits at, as the turret's is. Taking a hit is a task
// of its own that waits inside the message for its action to play (0x3d098, 0x3d3ec,
// 0x3ef5c, 0x3f0d4); while it does, a phase-one trooper's hits only take hit points, a phase
// two's are lost. A hit that kills through it sets the trooper dying; one in an attack is
// overridden by the attack's outcome.

#scope_module

Dark_Trooper :: struct {
    object: s32;
    phase: s32;                 // 1 to 3.
    move: *Free_Move;           // Its animation is the move's.
    hp: Fixed;
    alive := true;
    state: Dark_Trooper_State;
    last_seen: Fixed2;          // Where it last saw the player.
    collided_tick: u32;         // When it last hit something, charging or searching.
    hurt_playing, reflect_playing, rocket_playing: Sound_Instance;
    dying_sector: s32;          // Its sector when it began dying, where its corpse goes.

    flying: bool;               // Phases two and three: charging in the air.
    shots: s32;                 // Plasma bolts left in the burst.

    // Circling the player (0x3ccac, 0x3eb94): which way round.
    circle_back: bool;

    // Searching (0x3c754, 0x3e388).
    retarget: bool;             // A new place to make for.
    retarget_tick: s32;
    last_seen_until: s32;       // Until then it makes for where it last saw the player.
    search_delay: s32;          // Ticks between new places, longer each time it's blocked.
    blocked: bool;              // Phases two and three search on while just blocked.

    // A hit being taken, waiting for its action.
    hit: Dark_Trooper_Hit;
    saved_anim: Actor_Anim;     // The action it was playing, back afterward.

    wait: Dark_Trooper_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    polling: bool;              // Waiting for the AI to come back on (cheats.jai).
    in_message: bool;
    task: *Task;
}

// The original numbers them 0 idle, 1 charge, 2 circle, then phase one 3 attack, 4 die,
// 5 search; phases two and three 3 missiles, 4 plasma, 5 die, 6 search.
Dark_Trooper_State :: enum s32 { IDLE; CHARGE; CIRCLE; ATTACK; MISSILES; PLASMA; DIE; SEARCH; }

Dark_Trooper_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: charging the next frame.
    CHARGE;                     // A frame at a time.
    TAKE_OFF;                   // The jetpack lighting,
    LAND;                       // and landing to fire.
    CIRCLE;
    ATTACK;                     // Phase one: a frame before the swing,
    SWING;                      // then its swing playing.
    MISSILES;                   // Phases two and three: a frame before raising the launcher,
    MISSILE_AIM;                // raising it,
    MISSILE_AFTER;              // lowering it.
    PLASMA_AIM;                 // Raising the cannon,
    PLASMA;                     // 29 ticks between bolts,
    PLASMA_AFTER;               // lowering it.
    SEARCH;
    DIE;                        // Its dying action playing,
    FALL;                       // then until it lands.
}

// The message a hit leaves for the task, once its action has played.
Dark_Trooper_Hit :: enum u8 { NONE; SHOT; BLAST; }

Dark_Trooper_Assets :: struct {
    loaded: [3] bool;
    wake, hurt, die: [3] Sound_Handle;  // PHASE1A, 1B, 1C; PHASE2A, ...; PHASE3A, ...
    swing, reflect, rocket: Sound_Handle;   // SWORD-1, BIGREFL1, ROCKET-1.
}

// The O file's dark trooper of a phase on an object (0x3be2c, 0x3d804, 0x3f5b4).
create_dark_trooper :: (object: s32, phase: s32) {
    a := *world.dark_trooper_assets;
    if !a.loaded[phase - 1] {
        a.loaded[phase - 1] = true;
        if phase == 1 {
            a.wake[0] = register_sound("PHASE1A.VOC", 0x54);
            a.hurt[0] = register_sound("PHASE1B.VOC", 1);
            a.swing = register_sound("SWORD-1.VOC", 1);
            a.reflect = register_sound("BIGREFL1.VOC", 1);
            a.die[0] = register_sound("PHASE1C.VOC", 0x54);
            set_sound_level(a.die[0], 100);
        } else if phase == 2 {
            a.wake[1] = register_sound("PHASE2A.VOC", 0x54);
            a.hurt[1] = register_sound("PHASE2B.VOC", 1);
            a.rocket = register_sound("ROCKET-1.VOC", 0x6B);
            a.die[1] = register_sound("PHASE2C.VOC", 0x6F);
            set_sound_level(a.die[1], 100);
        } else {
            a.wake[2] = register_sound("PHASE3A.VOC", 0x54);
            a.hurt[2] = register_sound("PHASE3B.VOC", 1);
            a.rocket = register_sound("ROCKET-1.VOC", 0x6B);
            a.die[2] = register_sound("PHASE3C.VOC", 0x7F);
            set_sound_level(a.die[2], 120);
        }
    }
    t := New(Dark_Trooper);
    placed := false;
    for * world.dark_troopers  if !it.* { it.* = t; placed = true; break; }
    if !placed  array_add(*world.dark_troopers, t);
    create_object_task(.DARK_TROOPER, t, object, *t.task);
    o := world.objects[object];
    o.entity = ENTITY_AI_ACTOR | ENTITY_SMART;
    o.aimable = true;
    o.dark_trooper = t;
    t.object = object;
    t.phase = phase;
    m := create_free_move(object);
    t.move = m;
    // The movement's defaults (0x289b8), then a walker's.
    m.physics.step_up = 0x38000;
    m.physics.step_down = 4 * FIXED_ONE;
    m.physics.height = o.height;
    m.physics.width = o.width;
    m.collision_flags = MOVE_NO_Y | MOVE_GRAVITY;
    m.target.speed_vertical = FIXED_ONE;
    m.target.speed_rotation = 0x3000;
    if phase == 1 {
        t.hp = 180 * FIXED_ONE;
        m.target.speed = 30 * FIXED_ONE;
    } else {
        t.hp = ifx phase == 2 then 350 * FIXED_ONE else 750 * FIXED_ONE;
        m.physics.step_down = STEP_DOWN_ANY;
        m.collision_flags |= MOVE_SLIDE;
        m.target.speed = get_walk_speed(t);
        m.target.speed_vertical = 10 * FIXED_ONE;
    }
    if phase == 3  o.entity |= ENTITY_MOHC;
    m.anim.frame_rate = 5;
    m.anim.frame_count = FIXED_ONE;
    m.anim.prev_clock = 0;
    m.anim.flags = ANIM_READY;
    set_up_action_animation(o, ifx phase == 3 then cast(s32) 3 else 5, *m.anim);
}

unload_dark_troopers :: () {
    for world.dark_troopers  if it  free(it);
    array_free(world.dark_troopers);
    world.dark_trooper_assets = .{};
}

// Its task's turn (tasks.jai), if its time has come.
update_dark_trooper :: (t: *Dark_Trooper) {
    if !is_ai_task_due(*t.wake, *t.polling) return;
    run_dark_trooper(t, 0);
}

// A message to a dark trooper (0x1d8e5): its task runs from where it waits, at once, until
// it yields.
send_dark_trooper_message :: (t: *Dark_Trooper, message: Actor_Message) {
    t.in_message = true;
    run_dark_trooper(t, cast(s32) message);
    t.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

STEP_DOWN_ANY :: 9999 * FIXED_ONE;

// Phases two and three: walking, and the jetpack's frames in action 13 (lighting, flying,
// landing) and speed.
get_walk_speed :: (t: *Dark_Trooper) -> Fixed { return ifx t.phase == 2 then 15 * FIXED_ONE else 25 * FIXED_ONE; }

JETPACK_LIGHT_LAST :: s32.[0, 2, 1];
JETPACK_FLY        :: s32.[0, 3, 2];
JETPACK_LAND       :: s32.[0, 4, 3];

run_dark_trooper :: (t: *Dark_Trooper, message_in: s32) {
    message := message_in;
    if t.hit != .NONE {
        if !go_on_taking_hit(t, *message) return;
    } else if t.wait != .START && t.wait != .IDLE_HIT && t.wait != .DIE && t.wait != .FALL {
        if !take_hit(t, *message) return;
    }
    o := world.objects[t.object];
    m := t.move;
    ready := (m.anim.flags & ANIM_READY) != 0;
    if t.wait == {
        case .START;
            run_state(t);
        case .IDLE;
            if message == DAMAGE || message == EXPLOSION {
                t.state = .CHARGE;
                t.wake = 0;
                wait_dark_trooper(t, .IDLE_HIT, 0);
                return;
            }
            if message { wait_dark_trooper(t, .IDLE, 0x91); return; }
            if t.state == .IDLE && sees_player(t) {
                play_sound_at(world.dark_trooper_assets.wake[t.phase - 1], o.position);
                t.state = .CHARGE;
            }
            if t.state == .IDLE { wait_dark_trooper(t, .IDLE, 0x91); return; }
            run_state(t);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_dark_trooper(t, .IDLE, 0x91); return; }
            run_state(t);
        case .CHARGE;
            if message { wait_dark_trooper(t, .CHARGE, 0); return; }
            if t.state == .CHARGE {
                if t.phase == 1  charge(t);
                else if !charge_flying(t) return;
            }
            go_on_charging(t);
        case .TAKE_OFF;
            if message || !ready { wait_dark_trooper(t, .TAKE_OFF, 0); return; }
            // Off the floor: its jetpack's frame, flying at 60, dropping anywhere.
            set_up_action_animation(o, 13, *m.anim);
            fly := JETPACK_FLY[t.phase - 1];
            set_animation_frames(*m.anim, fly, fly);
            m.target.speed = ifx t.phase == 2 then 60 * FIXED_ONE else 70 * FIXED_ONE;
            m.physics.step_down = STEP_DOWN_ANY;
            t.flying = true;
            m.collision_flags &= ~(MOVE_NO_Y | MOVE_GRAVITY);
            if t.state == .CHARGE { wait_dark_trooper(t, .CHARGE, 0); return; }
            m.anim.flags |= ANIM_READY;
            run_state(t);
        case .LAND;
            if message || !ready { wait_dark_trooper(t, .LAND, 0); return; }
            m.target.speed = get_walk_speed(t);
            m.collision_flags |= MOVE_NO_Y | MOVE_GRAVITY;
            m.physics.step_down = STEP_DOWN_ANY;
            m.target.flags &= ~TARGET_MOVE_Y;
            stop_sound(t.rocket_playing);
            if t.state == .CHARGE  move_charging(t);
            go_on_charging(t);
        case .CIRCLE;
            if message { wait_dark_trooper(t, .CIRCLE, 0); return; }
            if t.state == .CIRCLE  circle(t);
            if t.state == .CIRCLE { wait_dark_trooper(t, .CIRCLE, 0); return; }
            m.anim.flags |= ANIM_READY;
            run_state(t);
        case .ATTACK;
            if message { wait_dark_trooper(t, .ATTACK, 0); return; }
            if t.state == .ATTACK {
                m.anim.flags |= ANIM_ONCE;
                set_up_action_animation(o, 1, *m.anim);
                wait_dark_trooper(t, .SWING, 0);
                return;
            }
            run_state(t);
        case .SWING;
            if message || !ready { wait_dark_trooper(t, .SWING, 0); return; }
            swing(t);
            run_state(t);
        case .MISSILES;
            if message { wait_dark_trooper(t, .MISSILES, 0); return; }
            if t.state == .MISSILES {
                m.anim.flags |= ANIM_ONCE;
                set_up_action_animation(o, ifx t.phase == 2 then cast(s32) 1 else 11, *m.anim);
                wait_dark_trooper(t, .MISSILE_AIM, 0);
                return;
            }
            run_state(t);
        case .MISSILE_AIM;
            if message || !ready { wait_dark_trooper(t, .MISSILE_AIM, 0); return; }
            if t.phase == 2  fire_missile(t);
            else             fire_homing_missiles(t);
            m.anim.flags |= ANIM_ONCE;
            set_up_action_animation(o, ifx t.phase == 2 then cast(s32) 6 else 12, *m.anim);
            wait_dark_trooper(t, .MISSILE_AFTER, 0);
        case .MISSILE_AFTER;
            if message || !ready { wait_dark_trooper(t, .MISSILE_AFTER, 0); return; }
            o.lit = false;
            t.state = .CIRCLE;
            run_state(t);
        case .PLASMA_AIM;
            if message || !ready { wait_dark_trooper(t, .PLASMA_AIM, 0); return; }
            t.shots = fixed_random(20) + 1;
            o.lit = true;
            m.target.flags |= TARGET_FREEZE;
            go_on_firing_plasma(t);
        case .PLASMA;
            if message { wait_dark_trooper(t, .PLASMA, 0x1D); return; }
            if t.state == .PLASMA {
                fire_plasma(t);
                t.shots -= 1;
                if !t.shots  t.state = .CIRCLE;
            }
            go_on_firing_plasma(t);
        case .PLASMA_AFTER;
            if message || !ready { wait_dark_trooper(t, .PLASMA_AFTER, 0); return; }
            o.lit = false;
            run_state(t);
        case .SEARCH;
            if message { wait_dark_trooper(t, .SEARCH, 0); return; }
            // With the player dying it waits on.
            if !world.player_state.dying {
                if t.phase == 1 {
                    if t.state == .SEARCH  search(t);
                } else {
                    search_flying(t);
                }
            }
            if t.state == .SEARCH || t.blocked { wait_dark_trooper(t, .SEARCH, 0); return; }
            m.anim.flags |= ANIM_READY;
            run_state(t);
        case .DIE;
            if message || !ready { wait_dark_trooper(t, .DIE, 0); return; }
            wait_dark_trooper(t, .FALL, 0);
        case .FALL;
            if message || !has_free_move_landed(m) { wait_dark_trooper(t, .FALL, 0); return; }
            die(t);
    }
}

// The task's loop (0x3c078, 0x3da40): into its state, until it waits.
run_state :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    m := t.move;
    if t.state == {
        case .IDLE;
            wait_dark_trooper(t, .IDLE, 0x91);
        case .CHARGE;
            t.collided_tick = 0;
            if t.phase == 1 {
                m.anim.flags &= ~ANIM_ONCE;
                set_up_action_animation(o, 0, *m.anim);
                wait_dark_trooper(t, .CHARGE, 0);
                return;
            }
            // Phases two and three (0x3dd70, 0x3fb20): four times in ten it lights its
            // jetpack first.
            m.target.flags &= ~TARGET_FREEZE;
            if fixed_random(100) < 41 {
                t.rocket_playing = play_sound_at(world.dark_trooper_assets.rocket, o.position);
                m.anim.flags |= ANIM_ONCE;
                set_up_action_animation(o, 13, *m.anim);
                set_animation_frames(*m.anim, 0, JETPACK_LIGHT_LAST[t.phase - 1]);
                wait_dark_trooper(t, .TAKE_OFF, 0);
                return;
            }
            m.target.speed = get_walk_speed(t);
            m.collision_flags |= MOVE_NO_Y | MOVE_GRAVITY;
            t.flying = false;
            m.anim.flags &= ~ANIM_ONCE;
            set_up_action_animation(o, 0, *m.anim);
            wait_dark_trooper(t, .CHARGE, 0);
        case .CIRCLE;
            // Circling (0x3ccac, 0x3eb94): first to a point off the player a little more
            // than a quarter turn round, turning at once.
            m.anim.flags &= ~ANIM_ONCE;
            set_up_action_animation(o, 0, *m.anim);
            t.circle_back = (world.clock.tick & 1) == 0;
            aim_circle(t, 0x10E3);
            wait_dark_trooper(t, .CIRCLE, 0);
        case .ATTACK;
            m.target.flags |= TARGET_FREEZE;
            wait_dark_trooper(t, .ATTACK, 0);
        case .MISSILES;
            // Missiles (0x3e6a8, 0x40458) and plasma (0x3e924, 0x406c4): standing on the floor.
            m.target.flags &= ~TARGET_MOVE_XZ;
            m.collision_flags |= MOVE_NO_Y | MOVE_GRAVITY;
            wait_dark_trooper(t, .MISSILES, 0);
        case .PLASMA;
            m.target.flags &= ~TARGET_MOVE_XZ;
            m.collision_flags |= MOVE_NO_Y | MOVE_GRAVITY;
            m.anim.flags |= ANIM_ONCE;
            set_up_action_animation(o, 1, *m.anim);
            wait_dark_trooper(t, .PLASMA_AIM, 0);
        case .DIE;
            // Dying (0x3d68c, 0x3f2fc, 0x4109c): it stops where it's going, carried only by a
            // blast, and falls.
            m.target.flags |= TARGET_FREEZE;
            if t.phase > 1  stop_sound(t.rocket_playing);
            play_sound_at(world.dark_trooper_assets.die[t.phase - 1], o.position);
            m.anim.flags |= ANIM_ONCE;
            set_up_action_animation(o, 2, *m.anim);
            if t.phase > 1  m.collision_flags |= MOVE_NO_Y | MOVE_GRAVITY;
            t.dying_sector = o.sector;
            wait_dark_trooper(t, .DIE, 0);
        case .SEARCH;
            t.collided_tick = 0;
            t.retarget = true;
            t.retarget_tick = 0;
            t.last_seen_until = world.clock.tick + 0x1111;
            t.search_delay = 72;
            t.blocked = false;
            m.anim.flags &= ~ANIM_ONCE;
            if t.phase == 1 {
                set_up_action_animation(o, 0, *m.anim);
            } else {
                // Phases two and three search flying at 30.
                set_up_action_animation(o, 13, *m.anim);
                m.target.speed = 30 * FIXED_ONE;
                m.collision_flags &= ~(MOVE_NO_Y | MOVE_GRAVITY);
            }
            m.target.flags &= ~TARGET_FREEZE;
            wait_dark_trooper(t, .SEARCH, 0);
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next, and the AI
// switched off makes it a wait for it (cheats.jai).
wait_dark_trooper :: (t: *Dark_Trooper, wait: Dark_Trooper_Wait, ticks: s32) {
    t.wait = wait;
    yield_ai_task(*t.wake, *t.polling, ticks, t.in_message);
}

// Hits ---------------------------------------------------------------------------------------

// A shot or blast where the task waits. False when taking it waits for an action to play.
take_hit :: (t: *Dark_Trooper, message: *s32) -> bool {
    if message.* == DAMAGE     return take_shot(t, message);
    if message.* == EXPLOSION  return take_blast(t, message);
    return true;
}

// A shot (0x3d098, 0x3ef5c, 0x40cfc): phase one turns seven in ten off its arm, back a half
// turn from the way they flew. The rest take hit points; of those that don't kill, phase one
// flinches at one in five, the others at one in ten. Either action stops it where it is until
// done.
take_shot :: (t: *Dark_Trooper, message: *s32) -> bool {
    o := world.objects[t.object];
    a := *world.dark_trooper_assets;
    proj := world.actor_state.message_projectile;
    if t.phase == 1 && fixed_random(100) < 71 {
        world.projectile_move.wall_hit = WALL_HIT_BOUNCE;
        world.projectile_move.reflect_angle = world.objects[proj.object].yaw + 0x1000;
        stop_sound(t.reflect_playing);
        t.reflect_playing = play_sound_at(a.reflect, o.position);
        start_hit_action(t, .SHOT, 13);
        return false;
    }
    t.hp -= proj.damage;
    if t.hp < 1 {
        t.state = .DIE;
        return true;
    }
    stop_sound(t.hurt_playing);
    t.hurt_playing = play_sound_at(a.hurt[t.phase - 1], o.position);
    if fixed_random(100) < (ifx t.phase == 1 then 21 else 11) {
        start_hit_action(t, .SHOT, get_flinch_action(t));
        return false;
    }
    return true;
}

get_flinch_action :: (t: *Dark_Trooper) -> s32 { return ifx t.phase == 3 then cast(s32) 10 else 12; }

// A blast (0x3d3ec, 0x3f0d4, 0x40e74): its hit points, a thermal detonator's by half to phase one,
// and a push away from it, all of it if it kills, half otherwise. Killed, it dies at once;
// otherwise it may flinch as from a shot.
take_blast :: (t: *Dark_Trooper, message: *s32) -> bool {
    o := world.objects[t.object];
    m := t.move;
    e := *world.actor_state;
    damage := e.message_damage;
    if t.phase == 1 && world.explosion_type == HIT_EFFECT_THERMAL_DETONATOR  damage >>= 1;
    t.hp -= damage;
    dir := get_explosion_push(.{o.position.x, o.position.y - o.height, o.position.z});
    push := Fixed3.{mul16(e.message_force, dir.x), mul16(e.message_force, dir.y), mul16(e.message_force, dir.z)};
    if t.hp < 1 {
        t.state = .DIE;
        m.velocity = push;
        message.* = 0;
        return true;
    }
    m.velocity = .{push.x / 2, push.y / 2, push.z / 2};
    stop_sound(t.hurt_playing);
    t.hurt_playing = play_sound_at(world.dark_trooper_assets.hurt[t.phase - 1], o.position);
    if fixed_random(100) < (ifx t.phase == 1 then 21 else 11) {
        start_hit_action(t, .BLAST, get_flinch_action(t));
        return false;
    }
    return true;
}

// Stopped, the action it was playing kept, a hit's action once.
start_hit_action :: (t: *Dark_Trooper, hit: Dark_Trooper_Hit, action: s32) {
    m := t.move;
    m.target.flags |= TARGET_FREEZE;
    t.saved_anim = m.anim;
    m.anim.flags |= ANIM_ONCE;
    set_up_action_animation(world.objects[t.object], action, *m.anim);
    t.hit = hit;
    wait_dark_trooper(t, t.wait, 0);
}

// Waiting for a hit's action: phase one's further hits take hit points and nothing else,
// the others' nothing at all. Once it has played, the action before it starts over, the
// trooper moves again, and the hit's message goes on to the task, which waits a frame more
// for it. False while it waits.
go_on_taking_hit :: (t: *Dark_Trooper, message: *s32) -> bool {
    m := t.move;
    if t.phase == 1 {
        if message.* == DAMAGE {
            t.hp -= world.actor_state.message_projectile.damage;
        } else if message.* == EXPLOSION {
            damage := world.actor_state.message_damage;
            if world.explosion_type == HIT_EFFECT_THERMAL_DETONATOR  damage >>= 1;
            t.hp -= damage;
        }
    }
    if message.* || !(m.anim.flags & ANIM_READY) {
        wait_dark_trooper(t, t.wait, 0);
        return false;
    }
    m.anim = t.saved_anim;
    set_up_action_animation(world.objects[t.object], m.anim.action, *m.anim);
    m.target.flags &= ~TARGET_FREEZE;
    message.* = ifx t.hit == .BLAST then EXPLOSION else DAMAGE;
    t.hit = .NONE;
    return true;
}

// States -------------------------------------------------------------------------------------

// Whether it sees the player, remembering where (0x3c71c, 0x3e350, 0x40100).
sees_player :: (t: *Dark_Trooper) -> bool {
    if !can_see_player(world.objects[t.object]) return false;
    t.last_seen = .{world.player.position.x, world.player.position.z};
    return true;
}

// The player within 15 units, counting the height.
is_player_within_reach :: (t: *Dark_Trooper) -> bool {
    o := world.objects[t.object];
    p := *world.player;
    return abs(o.position.y - p.position.y) + dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) <= 15 * FIXED_ONE;
}

is_facing_target :: (t: *Dark_Trooper) -> bool {
    return cast,no_check(s16) world.objects[t.object].yaw == cast,no_check(s16) t.move.target.yaw;
}

// A frame of phase one's charge (0x3c3f0): in reach and facing the player, it attacks;
// losing sight, it searches. Otherwise it runs on.
charge :: (t: *Dark_Trooper) {
    if !world.player_state.dying {
        if sees_player(t) {
            if is_player_within_reach(t) && is_facing_target(t)  t.state = .ATTACK;
        } else {
            t.state = .SEARCH;
        }
    }
    if t.state == .CHARGE  move_charging(t);
}

// A frame of phase two's and three's charge (0x3dd70, 0x3fb20): one time in ten it looks. Within 100 units and
// facing the player, it fires missiles or, six times in ten, plasma, landing first if it
// flies; losing sight, it searches. Otherwise it goes on. False when it waits to land.
charge_flying :: (t: *Dark_Trooper) -> bool {
    o := world.objects[t.object];
    m := t.move;
    p := *world.player;
    if fixed_random(100) < 11 {
        if !world.player_state.dying && sees_player(t) {
            dx := o.position.x - p.position.x;
            dy := o.position.y - p.position.y;
            dz := o.position.z - p.position.z;
            distance := fixed_sqrt(mul16(dz, dz) + mul16(dx, dx) + mul16(dy, dy));
            if distance <= 100 * FIXED_ONE && is_facing_target(t) {
                t.state = ifx fixed_random(100) > 40 then Dark_Trooper_State.PLASMA else .MISSILES;
                if t.flying {
                    m.anim.flags |= ANIM_ONCE;
                    set_up_action_animation(o, 13, *m.anim);
                    land := JETPACK_LAND[t.phase - 1];
                    set_animation_frames(*m.anim, land, land);
                    wait_dark_trooper(t, .LAND, 0);
                    return false;
                }
            }
        } else if !world.player_state.dying {
            stop_sound(t.rocket_playing);
            t.state = .SEARCH;
        }
    }
    if t.state == .CHARGE  move_charging(t);
    return true;
}

// Charging on: blocked, a new way; otherwise toward the player, or the player dying any way,
// and on the way it faces, 30 units for phase one, 15 for phase two, 25 for phase three;
// flying, it makes for 2 units above the player's feet.
move_charging :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    m := t.move;
    p := *world.player;
    m.target.flags &= ~TARGET_FREEZE;
    if is_blocked(o, m, *m.target) {
        turn_from_collision(o, m, *m.target, *t.collided_tick);
        return;
    }
    if !world.player_state.dying  m.target.yaw = vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    else                          m.target.yaw = fixed_random(0x3FD2);
    m.target.speed_rotation = 0x3000;
    m.target.flags |= TARGET_MOVE_ROT;
    ahead: Fixed = ifx t.phase == 1 then 30 * FIXED_ONE else get_walk_speed(t);
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    m.target.position.x = o.position.x + mul16(sin_yaw, ahead);
    m.target.position.z = o.position.z + mul16(cos_yaw, ahead);
    m.target.flags |= TARGET_MOVE_XZ;
    if t.flying {
        m.target.position.y = p.position.y - 2 * FIXED_ONE;
        m.target.flags |= TARGET_MOVE_Y;
    }
}

go_on_charging :: (t: *Dark_Trooper) {
    if t.state == .CHARGE { wait_dark_trooper(t, .CHARGE, 0); return; }
    t.move.anim.flags |= ANIM_READY;
    run_state(t);
}

// The swing (0x3ca88), once its action has played: 20 off health if the player is still in
// reach, then circling; otherwise charging again.
swing :: (t: *Dark_Trooper) {
    play_sound_at(world.dark_trooper_assets.swing, world.objects[t.object].position);
    if is_player_within_reach(t) {
        apply_damage(20 * FIXED_ONE, 0, true);
        t.state = .CIRCLE;
    } else {
        t.state = .CHARGE;
    }
}

// A frame of circling (0x3ccac, 0x3eb94, 0x40934): blocked, or the player dying, unseen or
// farther off than 25 units (the others: 20), it charges. At each point it attacks, phase
// one seven times in ten, the others one in ten; otherwise on round to the next, a quarter turn on, the
// other way round one time in ten.
circle :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    m := t.move;
    p := *world.player;
    if m.physics.wall || m.physics.hit_object != -1 || world.player_state.dying || !sees_player(t) {
        t.state = .CHARGE;
        return;
    }
    range: Fixed = ifx t.phase == 1 then 25 * FIXED_ONE else 20 * FIXED_ONE;
    if dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) > range {
        t.state = .CHARGE;
        return;
    }
    if !has_arrived(*m.target, o) return;
    if fixed_random(100) < (ifx t.phase == 1 then 71 else 11) {
        if t.phase == 1  t.state = .ATTACK;
        else             t.state = ifx fixed_random(100) > 40 then Dark_Trooper_State.PLASMA else .MISSILES;
        m.target.yaw = cast,no_check(s16) vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
        return;
    }
    if fixed_random(100) < 11  t.circle_back = !t.circle_back;
    aim_circle(t, 0x1000);
}

// To the point off the player (phase one 15 units, the others 100) an eighth of a turn round
// from the trooper, facing that far round again and more.
aim_circle :: (t: *Dark_Trooper, turn: s32) {
    o := world.objects[t.object];
    m := t.move;
    p := *world.player;
    angle := cast(s32) cast,no_check(s16) (vec2_to_angle(o.position.x - p.position.x, o.position.z - p.position.z) & ANGLE_MASK);
    side: s32 = ifx t.circle_back then cast(s32) -0x800 else 0x800;
    radius: Fixed = ifx t.phase == 1 then 15 * FIXED_ONE else 100 * FIXED_ONE;
    m.target.flags &= ~TARGET_FREEZE;
    sin_a, cos_a := sin_cos(angle + side);
    m.target.position.x = p.position.x + mul16(sin_a, radius);
    m.target.position.z = p.position.z + mul16(cos_a, radius);
    m.target.flags |= TARGET_MOVE_XZ;
    m.target.yaw = cast,no_check(s16) (ifx t.circle_back then angle - turn else angle + turn);
    m.target.speed_rotation = 0;
    m.target.flags |= TARGET_MOVE_ROT;
}

// Its launcher raised (0x3e6a8): a missile from 9 units up at a unit under the player's eye,
// at full light until the launcher is lowered.
fire_missile :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    p := *world.player;
    o.lit = true;
    play_sound_at(world.weapon.sounds[cast(s32) Weapon_Sound.MISSILE], o.position);
    proj := create_projectile(.MISSILE, o.sector, .{o.position.x, o.position.y - 9 * FIXED_ONE, o.position.z}, t.object);
    if !proj return;
    proj.last_hit = t.object;
    proj.exclude = t.object;
    world.objects[proj.object].yaw = vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    eye := get_player_eye();
    aim_projectile(proj, .{eye.x, eye.y + FIXED_ONE, eye.z});
}

// Its launcher raised (0x40458): six homing missiles from 11 units up, fanned either side of
// the way it faces, at full light until it's lowered. Each is fired by the trooper, not by
// the missile before it.
fire_homing_missiles :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    o.lit = true;
    play_sound_at(world.weapon.sounds[cast(s32) Weapon_Sound.MISSILE], o.position);
    for HOMING_MISSILE_FAN {
        proj := create_projectile(.HOMING_MISSILE, o.sector, .{o.position.x, o.position.y - 11 * FIXED_ONE, o.position.z}, t.object);
        if !proj continue;
        proj.exclude = t.object;
        proj.last_hit = t.object;
        p := world.objects[proj.object];
        p.yaw = cast,no_check(s16) (t.move.target.yaw + it);
        turn_projectile(proj, 0, p.yaw);
    }
}

HOMING_MISSILE_FAN :: s32.[-2275, -1365, -455, 455, 1365, 2275];

// A plasma bolt from 9 units up, the way it faces, led at the player (0x3e924, 0x406c4).
fire_plasma :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    play_sound_at(world.weapon.sounds[cast(s32) Weapon_Sound.CANNON], o.position);
    proj := create_projectile(.CANNON, o.sector, .{o.position.x, o.position.y - 9 * FIXED_ONE, o.position.z}, t.object);
    if !proj return;
    proj.last_hit = t.object;
    proj.exclude = t.object;
    world.objects[proj.object].yaw = cast,no_check(s16) t.move.target.yaw;
    lead_projectile(proj);
}

// The burst goes on every 29 ticks; done, the cannon is lowered. It stays where it stood.
go_on_firing_plasma :: (t: *Dark_Trooper) {
    if t.state == .PLASMA { wait_dark_trooper(t, .PLASMA, 0x1D); return; }
    t.move.anim.flags |= ANIM_ONCE;
    set_up_action_animation(world.objects[t.object], 6, *t.move.anim);
    wait_dark_trooper(t, .PLASMA_AFTER, 0);
}

// A frame of phase one's search (0x3c754): seeing the player, it charges. Otherwise it makes
// for where it last saw them, for 30 s, then for where they are, somewhere about it by a
// quarter of how far off they are across x; a new place each time it gets there or its time
// is up. Blocked, it takes a new way, and waits longer before the next place, up to 8 s, then
// starting over.
search :: (t: *Dark_Trooper) {
    if sees_player(t) {
        t.state = .CHARGE;
        return;
    }
    make_for_player(t);
    o := world.objects[t.object];
    m := t.move;
    if is_blocked(o, m, *m.target) {
        turn_from_collision(o, m, *m.target, *t.collided_tick);
        t.search_delay += 72;
        if t.search_delay > 0x48D  t.search_delay = 72;
        t.retarget_tick = world.clock.tick + t.search_delay;
    }
}

// A frame of phase two's and three's search (0x3e388, 0x40138): as phase one's, flying, but seeing the player it
// charges only once it isn't blocked, and blocked it waits less longer, up to 4 s.
search_flying :: (t: *Dark_Trooper) {
    if sees_player(t)  t.state = .CHARGE;
    make_for_player(t);
    o := world.objects[t.object];
    m := t.move;
    t.blocked = is_blocked(o, m, *m.target);
    if t.blocked {
        turn_from_collision(o, m, *m.target, *t.collided_tick);
        t.search_delay += 36;
        if t.search_delay > 0x246  t.search_delay = 72;
        t.retarget_tick = world.clock.tick + t.search_delay;
    }
}

make_for_player :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    m := t.move;
    p := *world.player;
    tick := world.clock.tick;
    if t.retarget_tick < tick || has_arrived(*m.target, o) {
        t.retarget = true;
        if has_arrived(*m.target, o)  t.last_seen_until = 0;
    }
    if !t.retarget return;
    t.retarget = false;
    eye := get_player_eye();
    x, z := eye.x, eye.z;
    if tick < t.last_seen_until  x, z = t.last_seen.x, t.last_seen.z;
    offset := abs(p.position.x - o.position.x) / 4;
    angle := cast(s32) cast,no_check(s16) vec2_to_angle(o.position.x - x, o.position.z - z);
    m.target.position.x, m.target.position.z = x, z;
    offset_target(*m.target.position.x, *m.target.position.z, offset, offset / 2, angle, 0xFFF);
    m.target.flags |= TARGET_MOVE_XZ;
    m.target.yaw = vec2_to_angle(m.target.position.x - o.position.x, m.target.position.z - o.position.z);
    m.target.pitch = 0;
    m.target.roll = 0;
    m.target.flags |= TARGET_MOVE_ROT;
    t.retarget_tick = tick + t.search_delay;
}

// Landed (0x3d68c, 0x3f2fc, 0x4109c): out of water its corpse, kept, in the sector it began
// dying in, and phase two's plasma and missiles; the boss's death told; then it and its object go.
die :: (t: *Dark_Trooper) {
    o := world.objects[t.object];
    if world.level.sectors[t.dying_sector].second_altitude - 1 < 0 {
        index := add_object(.SPRITE, o.data, o.position, t.dying_sector);
        c := world.objects[index];
        c.anim = 4;
        c.frame = 0;
        c.entity |= ENTITY_CORPSE | ENTITY_KEPT_CORPSE;
        if t.phase == 2 {
            drop_trooper_item(ITEM_PLASMA, o.sector, o.position, .{3 * FIXED_ONE, 0, 3 * FIXED_ONE});
            drop_trooper_item(ITEM_MISSILES, o.sector, o.position, .{0, 3 * FIXED_ONE, 3 * FIXED_ONE});
        }
    }
    t.alive = false;
    send_boss_killed(o);
    free_free_move(t.move);
    o.dark_trooper = null;
    free_object(t.object);
    for * world.dark_troopers  if it.* == t { it.* = null; break; }
    end_task(t.task);
    free(t);
}

// An item where it died, moved off a little and put on its sector's floor; gone in water.
drop_trooper_item :: (item: s32, sector: s32, at: Fixed3, offset: Fixed3) {
    index := create_item(item, sector, at);
    if index < 0 return;
    m: Object_Move;
    m.offset = offset;
    m.step_up = FIXED_ONE;
    m.step_down = STEP_DOWN_ANY;
    m.height = FIXED_ONE;
    m.width = world.objects[index].width;
    move_object(index, *m);
    o := world.objects[index];
    s := *world.level.sectors[o.sector];
    o.position.y = s.floor.altitude;
    if s.second_altitude - 1 >= 0  free_object(index);
}

#import "Basic";
#import "engine/dfFixed";
