// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Welders (LOGIC: WELDER, 0x3b184, its task 0x3b424): a welding arm hung in the Arc Hammer's
// works. Idle, it looks every second for the player within 25 units, or in sight within 40;
// then it swings to them and, each time it has had to swing, strikes a spark 19 units out,
// which burns the player within 35 of it. It looks again every half second; losing the
// player it swings back. Its 130 hit points gone, it blows up.
//
// The task is written as the places it waits at, as the turret's is.

#scope_module

Welder :: struct {
    object: s32;
    move: *Free_Move;
    hp: Fixed = 130 * FIXED_ONE;
    alive := true;
    state: Welder_State;
    home_yaw, home_pitch: s32;  // Where it was hung facing.
    swung: bool;                // It had to swing to the player: a spark when it's there.
    swing_playing: Sound_Instance;
    hurt_playing: Sound_Instance;

    wait: Welder_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    polling: bool;              // Waiting for the AI to come back on (cheats.jai).
    in_message: bool;
    task: *Task;
}

Welder_State :: enum s32 { IDLE :: 0; ATTACK :: 1; RETURN :: 2; DIE :: 3; }

Welder_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: attacking the next frame.
    ATTACK;                     // A frame at a time, swinging.
    HOLD;                       // 72 ticks after a look.
    RETURN;                     // A frame at a time, swinging back.
    DIE;                        // The frame it dies in.
}

Welder_Assets :: struct {
    spark: s32 = -1;            // SPARK.WAX, into sprites.
    swing, stop, spark_sound, hurt, die: Sound_Handle;  // WELD-2, WELD-1, WELDSHT1, WELDHRT, WELD-DIE.
}

// The O file's welder on an object (0x3b184).
create_welder :: (object: s32) {
    a := *world.welder_assets;
    if a.spark < 0 {
        a.spark = find_or_load_sprite("SPARK.WAX");
        a.swing = register_sound("WELD-2.VOC", 0x54);
        a.stop = register_sound("WELD-1.VOC", 0x54);
        a.spark_sound = register_sound("WELDSHT1.VOC", 1);
        a.hurt = register_sound("WELDHRT.VOC", 1);
        a.die = register_sound("WELD-DIE.VOC", 0x54);
    }
    w := New(Welder);
    placed := false;
    for * world.welders  if !it.* { it.* = w; placed = true; break; }
    if !placed  array_add(*world.welders, w);
    create_object_task(.WELDER, w, object, *w.task);
    o := world.objects[object];
    o.entity = ENTITY_AI_ACTOR;
    o.aimable = true;
    o.welder = w;
    o.width, o.height = 10 * FIXED_ONE, 4 * FIXED_ONE;
    w.object = object;
    w.home_yaw, w.home_pitch = o.yaw, o.pitch;
    m := create_free_move(object);
    w.move = m;
    m.physics.width = o.width;
    m.physics.height = o.height + 0x8000;
    m.target.speed_rotation = 0x11C7;
    m.target.pitch, m.target.yaw, m.target.roll = o.pitch, o.yaw, o.roll;
}

unload_welders :: () {
    for world.welders  if it  free(it);
    array_free(world.welders);
}

// Its task's turn (tasks.jai), if its time has come.
update_welder :: (w: *Welder) {
    if !is_ai_task_due(*w.wake, *w.polling) return;
    run_welder(w, 0);
}

// A message to a welder (0x1d8e5): its task runs from where it waits, at once, until it
// yields.
send_welder_message :: (w: *Welder, message: Actor_Message) {
    w.in_message = true;
    run_welder(w, cast(s32) message);
    w.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

run_welder :: (w: *Welder, message_in: s32) {
    message := message_in;
    if w.wait == {
        case .START;
            run_state(w);
        case .IDLE;
            take_damage(w, *message);
            if message == DAMAGE || message == EXPLOSION {
                w.state = .ATTACK;
                w.wake = 0;
                wait_welder(w, .IDLE_HIT, 0);
                return;
            }
            if message { wait_welder(w, .IDLE, 0x91); return; }
            if w.state == .IDLE && !world.player_state.dying && is_player_visible(world.objects[w.object], 0x4000, 25 * FIXED_ONE) && is_within_reach(w) {
                w.state = .ATTACK;
            }
            if w.state == .IDLE { wait_welder(w, .IDLE, 0x91); return; }
            run_state(w);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_welder(w, .IDLE, 0x91); return; }
            run_state(w);
        case .ATTACK;
            take_damage(w, *message);
            if message { wait_welder(w, .ATTACK, 0); return; }
            if w.state == .ATTACK && is_facing(w) && look_and_strike(w) {
                wait_welder(w, .HOLD, 72);
                return;
            }
            if w.state == .ATTACK { wait_welder(w, .ATTACK, 0); return; }
            run_state(w);
        case .HOLD;
            take_damage(w, *message);
            if message { wait_welder(w, .HOLD, 72); return; }
            swing_to_player(w);
            if w.state == .ATTACK { wait_welder(w, .ATTACK, 0); return; }
            run_state(w);
        case .RETURN;
            take_damage(w, *message);
            if message { wait_welder(w, .RETURN, 0); return; }
            o := world.objects[w.object];
            if w.state == .RETURN && w.move.target.yaw == o.yaw {
                stop_sound(w.swing_playing);
                play_sound_at(world.welder_assets.stop, o.position);
                w.state = .IDLE;
            }
            if w.state == .RETURN { wait_welder(w, .RETURN, 0); return; }
            run_state(w);
        case .DIE;
            o := world.objects[w.object];
            if (o.yaw & ANGLE_MASK) != (w.move.target.yaw & ANGLE_MASK) || message { wait_welder(w, .DIE, 0); return; }
            spawn_hit_effect(HIT_EFFECT_EXPLOSION_HARMLESS, o.sector, o.position, w.object);
            remove_welder(w);
    }
}

// The task's loop (0x3b424): on into its state, until it waits.
run_state :: (w: *Welder) {
    o := world.objects[w.object];
    m := w.move;
    if w.state == {
        case .IDLE;
            wait_welder(w, .IDLE, 0x91);
        case .ATTACK;
            w.swung = false;
            wait_welder(w, .ATTACK, 0);
        case .RETURN;
            // Back to where it hung (0x3bb24); only its yaw is waited for.
            m.target.yaw, m.target.pitch = w.home_yaw, w.home_pitch;
            m.target.flags = (m.target.flags & ~TARGET_MOVE_XZ) | TARGET_MOVE_ROT;
            w.swing_playing = play_sound_at(world.welder_assets.swing, o.position);
            wait_welder(w, .RETURN, 0);
        case .DIE;
            // It droops, but frozen it never turns; it blows up the next frame.
            m.target.flags |= TARGET_FREEZE;
            stop_sound(w.swing_playing);
            play_sound_at(world.welder_assets.die, o.position);
            m.target.pitch = cast,no_check(s16) 0xFAAB;
            m.target.yaw = o.yaw;
            m.target.flags |= TARGET_MOVE_ROT;
            wait_welder(w, .DIE, 0);
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next, and the AI
// switched off makes it a wait for it (cheats.jai).
wait_welder :: (w: *Welder, wait: Welder_Wait, ticks: s32) {
    w.wait = wait;
    yield_ai_task(*w.wake, *w.polling, ticks, w.in_message);
}

// Shots (0x3bc04) and blasts (0x3bc80): hurt, it groans, cutting off the last; at no hit
// points it dies, and the message counts as a run.
take_damage :: (w: *Welder, message: *s32) {
    if !w.alive return;
    if message.* == DAMAGE          w.hp -= world.actor_state.message_projectile.damage;
    else if message.* == EXPLOSION  w.hp -= world.actor_state.message_damage;
    else return;
    if w.hp < 1 {
        w.state = .DIE;
        message.* = 0;
        return;
    }
    stop_sound(w.hurt_playing);
    w.hurt_playing = play_sound_at(world.welder_assets.hurt, world.objects[w.object].position);
}

// The player no more than 40 off, counting the height.
is_within_reach :: (w: *Welder) -> bool {
    o := world.objects[w.object];
    p := *world.player;
    return dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) + abs(o.position.y - p.position.y) <= 40 * FIXED_ONE;
}

is_facing :: (w: *Welder) -> bool {
    return (world.objects[w.object].yaw & ANGLE_MASK) == (w.move.target.yaw & ANGLE_MASK);
}

// Done swinging (0x3b7b4): its swing sound stops, and if it had to swing, a spark. With the
// player still within reach and in sight it holds; otherwise it swings back.
look_and_strike :: (w: *Welder) -> bool {
    o := world.objects[w.object];
    stop_sound(w.swing_playing);
    if w.swung  play_sound_at(world.welder_assets.stop, o.position);
    if is_within_reach(w) && is_player_visible(o, 0x4000, 25 * FIXED_ONE) {
        if w.swung  strike_spark(w);
        return true;
    }
    w.state = .RETURN;
    return false;
}

// A spark 19 units out along its yaw and pitch, 3 lower, played once at full light; within 35
// of it the player takes 20, to health.
strike_spark :: (w: *Welder) {
    o := world.objects[w.object];
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    sin_pitch := sin_cos(o.pitch);
    at := Fixed3.{o.position.x + mul16(sin_yaw, 19 * FIXED_ONE), o.position.y + mul16(sin_pitch, 19 * FIXED_ONE) + 3 * FIXED_ONE, o.position.z + mul16(cos_yaw, 19 * FIXED_ONE)};
    index := add_object(.SPRITE, world.welder_assets.spark, at, o.sector);
    spark := world.objects[index];
    spark.lit = true;
    set_object_size(spark);
    start_sprite_animation(index, loops = 1);
    spark.width = 0;
    play_sound_at(world.welder_assets.spark_sound, at);
    p := *world.player;
    if dist_approx(p.position.x, p.position.z, at.x, at.z) + abs(at.y - p.position.y) <= 35 * FIXED_ONE {
        apply_damage(20 * FIXED_ONE, 0, true);
    }
}

// After holding (0x3b7b4): toward the player, the pitch from a unit under the eye 19 units
// off. Already there, no swing; otherwise it swings, with its sound. Done even when a hit has
// just killed it.
swing_to_player :: (w: *Welder) {
    o := world.objects[w.object];
    p := *world.player;
    m := w.move;
    m.target.yaw = cast,no_check(s16) vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    m.target.pitch = cast,no_check(s16) vec2_to_angle(o.position.y - get_player_eye().y + FIXED_ONE, 19 * FIXED_ONE);
    if cast,no_check(s16) m.target.yaw == cast,no_check(s16) o.yaw && cast,no_check(s16) m.target.pitch == cast,no_check(s16) o.pitch {
        w.swung = false;
        m.target.flags &= ~TARGET_MOVE_ROT;
    } else {
        m.target.flags |= TARGET_MOVE_ROT;
        w.swung = true;
        w.swing_playing = play_sound_at(world.welder_assets.swing, o.position);
    }
}

// The task ends (0x3b424): the welder and its object go.
remove_welder :: (w: *Welder) {
    w.alive = false;
    free_free_move(w.move);
    o := world.objects[w.object];
    o.welder = null;
    free_object(w.object);
    for * world.welders  if it.* == w { it.* = null; break; }
    end_task(w.task);
    free(w);
}

#import "Basic";
#import "engine/dfFixed";
