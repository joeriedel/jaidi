// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Boba Fett (LOGIC: BOBA_FETT, 0x37d3c, its task 0x37fb8) flies on his jetpack, steered by
// thrust rather than moved to a point: each frame he turns toward where he's going, tilts his
// thrust to speed up or slow down, and throttles it to climb or sink to the height he wants
// (0x38bc0, 0x25988). Idle, he looks every second for the player in sight; then he searches,
// flying at the player and now and then off somewhere at random, until he sees them, or
// gives up after a minute. Attacking, he picks a way at random each time the last runs out:
// diving at the player to hover 10 units before them for 5 s, circling for 10 s, or weaving
// for 15 s, at heights picked at random every few seconds. Facing within 35 degrees of the
// player and seeing them, he fires a shot led at them every 0 to 2 s, and within 25 units
// another straight at them every quarter second that lasts a second. Every hit hurts his 200
// hit points and makes him flinch; dying, he leaves his corpse where he is, in the air or not,
// and as a boss tells the level's "boss" sector.
//
// The task is written as the places it waits at, as the turret's is. A hit's flinch waits
// inside the message (0x3887c, 0x389a8); hits that come meanwhile are lost.

#scope_module

Boba_Fett :: struct {
    object: s32;
    move: *Free_Move;           // Its animation is the move's.
    hp: Fixed = 200 * FIXED_ONE;
    alive := true;
    state: Boba_Fett_State;
    hurt_playing: Sound_Instance;
    thrust_playing: Sound_Instance;     // The movement's +0xd0.
    dying_sector: s32;          // His sector when he began dying, where his corpse goes.
    flight: Boba_Flight;

    // Attacking (0x3819c).
    mode: Boba_Mode;
    next_aimed_shot, next_close_shot, next_height, mode_until, next_swap: u32;
    lateral: Fixed;             // Circling or weaving: the push sideways.
    height: Fixed;              // The height he's after.

    // Searching (0x386cc).
    search_mode: u8;            // 0 at the player, 1 off somewhere, 2 going there.
    next_look, give_up, next_search_mode: u32;

    // A hit's flinch.
    flinching: bool;
    hit_message: s32;
    saved_anim: Actor_Anim;

    wait: Boba_Fett_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    polling: bool;              // Waiting for the AI to come back on (cheats.jai).
    in_message: bool;
    task: *Task;
}

// How he flies (the task's +0x108).
Boba_Flight :: struct {
    target: Fixed3;
    thrust_factor: Fixed = 220 * FIXED_ONE;
    pitch_range: Fixed = FIXED_ONE;     // How far the thrust may tilt, as a fraction of 45 degrees.
    pitch: s32;                 // The thrust's tilt forward.
    scale: Fixed;               // The throttle, 0 to 1.
    lateral: Fixed;             // A push sideways this frame.
}

Boba_Fett_State :: enum s32 { IDLE :: 0; ATTACK :: 1; DIE :: 2; SEARCH :: 3; }

// The attack's ways; each runs from its first frame (the first three) on.
Boba_Mode :: enum s32 { DIVE :: 0; CIRCLE :: 1; WEAVE :: 2; CHOOSE :: 4; DIVING :: 5; CIRCLING :: 6; WEAVING :: 7; }

Boba_Fett_Wait :: enum u8 {
    START;                      // Created, not run yet.
    IDLE;                       // A second between looks.
    IDLE_HIT;                   // Hit while idle: attacking the next frame.
    ATTACK;                     // A frame at a time,
    SEARCH;                     // likewise.
    DIE;                        // His dying action playing.
}

Boba_Fett_Assets :: struct {
    loaded: bool;
    see, hurt, fire, die, thrust: Sound_Handle;     // BOBA-1, -3, -2, -4, ROCKET-2.
}

// The O file's Boba Fett on an object (0x37d3c).
create_boba_fett :: (object: s32) {
    a := *world.boba_fett_assets;
    if !a.loaded {
        a.loaded = true;
        a.see = register_sound("BOBA-1.VOC", 0x54);
        a.hurt = register_sound("BOBA-3.VOC", 1);
        a.fire = register_sound("BOBA-2.VOC", 1);
        a.die = register_sound("BOBA-4.VOC", 0x54);
        a.thrust = register_sound("ROCKET-2.VOC", 0x14);
    }
    b := New(Boba_Fett);
    placed := false;
    for * world.boba_fetts  if !it.* { it.* = b; placed = true; break; }
    if !placed  array_add(*world.boba_fetts, b);
    create_object_task(.BOBA_FETT, b, object, *b.task);
    o := world.objects[object];
    o.entity = ENTITY_AI_ACTOR | ENTITY_SMART;
    o.aimable = true;
    o.height = 7 * FIXED_ONE;
    o.boba_fett = b;
    b.object = object;
    m := create_free_move(object);
    b.move = m;
    // The movement's defaults (0x289b8), then a flyer's: 2 wide, never stepping up, any drop,
    // falling and sliding but moving freely up and down.
    m.physics.width = 2 * FIXED_ONE;
    m.physics.step_up = 0;
    m.physics.step_down = 9999 * FIXED_ONE;
    m.physics.height = o.height;
    m.collision_flags = MOVE_GRAVITY | MOVE_SLIDE;
    m.target.speed = FIXED_ONE;
    m.target.speed_vertical = FIXED_ONE;
    m.target.speed_rotation = 0x1AAA;
    m.anim.frame_rate = 5;
    m.anim.frame_count = FIXED_ONE;
    m.anim.prev_clock = 0;
    m.anim.flags = ANIM_READY;
    set_up_action_animation(o, 5, *m.anim);
}

unload_boba_fetts :: () {
    for world.boba_fetts  if it  free(it);
    array_free(world.boba_fetts);
    world.boba_fett_assets = .{};
}

// Its task's turn (tasks.jai), if its time has come.
update_boba_fett :: (b: *Boba_Fett) {
    if !is_ai_task_due(*b.wake, *b.polling) return;
    run_boba_fett(b, 0);
}

// A message to Boba Fett (0x1d8e5): his task runs from where it waits, at once, until it
// yields.
send_boba_fett_message :: (b: *Boba_Fett, message: Actor_Message) {
    b.in_message = true;
    run_boba_fett(b, cast(s32) message);
    b.in_message = false;
}

#scope_file

DAMAGE    :: cast(s32) Actor_Message.DAMAGE;
EXPLOSION :: cast(s32) Actor_Message.EXPLOSION;

run_boba_fett :: (b: *Boba_Fett, message_in: s32) {
    message := message_in;
    m := b.move;
    if b.flinching {
        // Hits meanwhile are lost.
        if message || !(m.anim.flags & ANIM_READY) { wait_boba_fett(b, b.wait, 0); return; }
        m.anim = b.saved_anim;
        set_up_action_animation(world.objects[b.object], m.anim.action, *m.anim);
        b.flinching = false;
        message = b.hit_message;
    } else if b.wait == .IDLE || b.wait == .ATTACK || b.wait == .SEARCH {
        if !take_hit(b, *message) return;
    }
    if b.wait == {
        case .START;
            run_state(b);
        case .IDLE;
            if message == DAMAGE || message == EXPLOSION {
                b.state = .ATTACK;
                b.wake = 0;
                wait_boba_fett(b, .IDLE_HIT, 0);
                return;
            }
            if message { wait_boba_fett(b, .IDLE, 0x91); return; }
            o := world.objects[b.object];
            if b.state == .IDLE && can_see_player(o) {
                play_sound_at(world.boba_fett_assets.see, o.position);
                b.state = .SEARCH;
                set_up_action_animation(o, 0, *m.anim);
            }
            if b.state == .IDLE { wait_boba_fett(b, .IDLE, 0x91); return; }
            run_state(b);
        case .IDLE_HIT;
            // A message here isn't looked at: the wait it goes back to hands it back.
            if message { wait_boba_fett(b, .IDLE, 0x91); return; }
            run_state(b);
        case .ATTACK;
            if message { wait_boba_fett(b, .ATTACK, 0); return; }
            if b.state == .ATTACK  attack(b);
            if b.state == .ATTACK { wait_boba_fett(b, .ATTACK, 0); return; }
            run_state(b);
        case .SEARCH;
            if message { wait_boba_fett(b, .SEARCH, 0); return; }
            if b.state == .SEARCH  search(b);
            if b.state == .SEARCH { wait_boba_fett(b, .SEARCH, 0); return; }
            m.collision_flags |= MOVE_SLIDE;
            run_state(b);
        case .DIE;
            if message || !(m.anim.flags & ANIM_READY) { wait_boba_fett(b, .DIE, 0); return; }
            die(b);
    }
}

// The task's loop (0x37fb8): into his state, until it waits.
run_state :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    m := b.move;
    tick := cast(u32) world.clock.tick;
    if b.state == {
        case .IDLE;
            wait_boba_fett(b, .IDLE, 0x91);
        case .ATTACK;
            b.mode = .CHOOSE;
            b.next_aimed_shot = tick + cast(u32) (fixed_random(0x123 * FIXED_ONE) >> 16);
            b.next_height = 0;
            b.next_close_shot = 0;
            wait_boba_fett(b, .ATTACK, 0);
        case .SEARCH;
            b.next_look = 0;
            b.search_mode = 0;
            b.give_up = tick + 0x2223;
            b.next_search_mode = tick + 0x5B0;
            m.collision_flags |= MOVE_SLIDE;
            wait_boba_fett(b, .SEARCH, 0);
        case .DIE;
            // Dying (0x38ad4): his jetpack off, his action played once, slowly.
            m.target.flags |= TARGET_FREEZE;
            stop_sound(b.thrust_playing);
            play_sound_at(world.boba_fett_assets.die, o.position);
            m.anim.flags |= ANIM_ONCE;
            m.anim.frame_rate = 8;
            set_up_action_animation(o, 2, *m.anim);
            b.dying_sector = o.sector;
            wait_boba_fett(b, .DIE, 0);
    }
}

// A yield (0x338c8): only a run of its own sets when the task runs next, and the AI
// switched off makes it a wait for it (cheats.jai).
wait_boba_fett :: (b: *Boba_Fett, wait: Boba_Fett_Wait, ticks: s32) {
    b.wait = wait;
    yield_ai_task(*b.wake, *b.polling, ticks, b.in_message);
}

// A shot or blast (0x3887c, 0x389a8): its hit points, no push. Killed, he dies at once;
// otherwise he cries out, cutting off the last, and flinches. False while he flinches.
take_hit :: (b: *Boba_Fett, message: *s32) -> bool {
    if message.* == DAMAGE         b.hp -= world.actor_state.message_projectile.damage;
    else if message.* == EXPLOSION b.hp -= world.actor_state.message_damage;
    else return true;
    if b.hp < 1 {
        b.state = .DIE;
        message.* = 0;
        return true;
    }
    o := world.objects[b.object];
    m := b.move;
    b.saved_anim = m.anim;
    stop_sound(b.hurt_playing);
    b.hurt_playing = play_sound_at(world.boba_fett_assets.hurt, o.position);
    m.anim.flags |= ANIM_ONCE;
    m.anim.frame_rate = 6;
    set_up_action_animation(o, 12, *m.anim);
    b.flinching = true;
    b.hit_message = message.*;
    wait_boba_fett(b, b.wait, 0);
    return false;
}

// A frame of the attack (0x3819c).
attack :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    m := b.move;
    f := *b.flight;
    p := *world.player;
    tick := cast(u32) world.clock.tick;
    angle := cast(s32) cast,no_check(s16) vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
    if b.mode == {
        case .DIVE;
            // At the player: a boost up and ahead, at full throttle.
            b.mode_until = tick + 0x2D8;
            f.pitch = FIXED_ONE;
            f.scale = FIXED_ONE;
            b.mode = .DIVING;
            sin_yaw, cos_yaw := sin_cos(o.yaw);
            v := *m.velocity;
            v.y -= 15 * FIXED_ONE;
            v.x += mul16(sin_yaw, 80 * FIXED_ONE);
            v.z += mul16(cos_yaw, 80 * FIXED_ONE);
            dive_at_player(b, angle);
        case .DIVING;
            dive_at_player(b, angle);
        case .CIRCLE;
            b.mode_until = tick + 0x5B0;
            b.lateral = ifx tick & 1 then -15 * FIXED_ONE else 15 * FIXED_ONE;
            b.mode = .CIRCLING;
            circle_player(b);
        case .CIRCLING;
            circle_player(b);
        case .WEAVE;
            b.mode_until = tick + 0x888;
            b.mode = .WEAVING;
            b.next_swap = tick + 0x123;
            b.lateral = 50 * FIXED_ONE;
            weave_at_player(b);
        case .WEAVING;
            weave_at_player(b);
        case .CHOOSE;
            if !(tick & 1)  b.mode = cast(Boba_Mode) (fixed_random(3 * FIXED_ONE) >> 16);
            else            b.mode = .DIVE;
            b.mode_until = 0xFFFF_FFFF;
    }
    fly_to_target(b);
    f.lateral = 0;
    if b.mode_until < tick  b.mode = .CHOOSE;

    if cast,no_check(s16) get_angle_difference(angle, o.yaw) < 0x638 {
        if b.next_aimed_shot < tick && can_see_player(o) {
            b.next_aimed_shot = tick + cast(u32) (fixed_random(0x123 * FIXED_ONE) >> 16);
            proj := fire_shot(b, angle);
            if proj  lead_projectile(proj);
        }
        if dist_approx(p.position.x, p.position.z, o.position.x, o.position.z) < 25 * FIXED_ONE && b.next_close_shot < tick && can_see_player(o) {
            b.next_close_shot = tick + 0x24;
            proj := fire_shot(b, angle);
            if proj {
                aim_projectile(proj, p.position);
                proj.duration = tick + 0x91;
            }
        }
    }

    // A height picked at random within his sector every few seconds, kept no lower than the
    // player's head and no higher than 25 units above their feet.
    if b.next_height < tick {
        b.next_height = tick + cast(u32) (fixed_random(0x2D8 * FIXED_ONE) >> 16);
        sector := *world.level.sectors[o.sector];
        b.height = sector.floor.altitude - fixed_random(sector.floor.altitude - sector.ceiling.altitude);
    }
    top := p.position.y - p.height;
    if b.height < top  top = b.height;
    if top <= p.position.y - 25 * FIXED_ONE  top = p.position.y - 25 * FIXED_ONE;
    b.height = top;
}

// Hovering 10 units before the player along his own yaw, 5 above their feet, facing them.
dive_at_player :: (b: *Boba_Fett, angle: s32) {
    o := world.objects[b.object];
    m := b.move;
    f := *b.flight;
    p := *world.player;
    m.target.yaw = angle;
    m.target.flags |= TARGET_MOVE_ROT;
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    f.target.x = p.position.x + mul16(sin_yaw, 10 * FIXED_ONE);
    f.target.z = p.position.z + mul16(cos_yaw, 10 * FIXED_ONE);
    f.target.y = p.position.y - 5 * FIXED_ONE;
}

// Circling (0x3819c): pushed sideways at 15, always the one way; the way picked at the
// start is never used.
circle_player :: (b: *Boba_Fett) {
    p := *world.player;
    b.flight.lateral = 15 * FIXED_ONE;
    b.flight.target = .{p.position.x, b.height, p.position.z};
}

// Weaving: pushed sideways at 50, the other way every 2 s.
weave_at_player :: (b: *Boba_Fett) {
    p := *world.player;
    b.flight.lateral = b.lateral;
    b.flight.target = .{p.position.x, b.height, p.position.z};
    if b.next_swap < cast(u32) world.clock.tick {
        b.next_swap = cast(u32) world.clock.tick + 0x123;
        b.lateral = -b.lateral;
    }
}

// A shot from 4 units up, toward the player.
fire_shot :: (b: *Boba_Fett, angle: s32) -> *Projectile {
    o := world.objects[b.object];
    proj := create_projectile(.BOBA_FETT_BALL, o.sector, .{o.position.x, o.position.y - 4 * FIXED_ONE, o.position.z}, b.object);
    play_sound_at(world.boba_fett_assets.fire, o.position);
    if !proj return null;
    proj.last_hit = b.object;
    proj.exclude = b.object;
    world.objects[proj.object].yaw = angle;
    return proj;
}

// A frame of the search (0x386cc): flying at the player's eye, 3 below it, or now and then
// off somewhere 40 to 120 units away at random; every 10 s, which by the tick. Every second
// he looks; seeing the player, he attacks. After a minute he gives up and idles.
search :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    f := *b.flight;
    p := *world.player;
    tick := cast(u32) world.clock.tick;
    if b.search_mode == 0 {
        f.target = .{p.position.x, get_player_eye().y + 3 * FIXED_ONE, p.position.z};
    } else if b.search_mode == 1 {
        f.target.x, f.target.z = o.position.x, o.position.z;
        angle := cast(s32) cast,no_check(s16) fixed_random_next();
        offset_target(*f.target.x, *f.target.z, 80 * FIXED_ONE, 40 * FIXED_ONE, angle, 0x1FFF);
        b.search_mode = 2;
    }
    fly_to_target(b);
    if b.next_search_mode < tick {
        b.search_mode = ifx tick & 1 then cast(u8) 0 else 1;
        b.next_search_mode = tick + 0x5B0;
    }
    if b.next_look < tick {
        if !world.player_state.dying && can_see_player(o)  b.state = .ATTACK;
        else                                                b.next_look = tick + 0x91;
    }
    if b.give_up < tick  b.state = .IDLE;
}

// Landed or not (0x38ad4): his corpse, kept, where he is, in the sector he began dying in;
// the boss's death told; then he and his object go.
die :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    index := add_object(.SPRITE, o.data, o.position, b.dying_sector);
    c := world.objects[index];
    c.anim = 4;
    c.frame = 0;
    c.entity |= ENTITY_CORPSE | ENTITY_KEPT_CORPSE;
    b.alive = false;
    send_boss_killed(o);
    free_free_move(b.move);
    o.boba_fett = null;
    free_object(b.object);
    for * world.boba_fetts  if it.* == b { it.* = null; break; }
    end_task(b.task);
    free(b);
}

// Flying ---------------------------------------------------------------------------------------

// The height he makes for (0x38bc0): no higher than his height under the ceiling here or past
// the wall on the way, whichever is lower down, and no lower than the higher floor.
fly_to_target :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    f := *b.flight;
    sector := *world.level.sectors[o.sector];
    top := sector.ceiling.altitude + o.height;
    bottom := sector.floor.altitude;
    wall := find_path_wall(o.sector, o.position.x, o.position.z, f.target.x, f.target.z);
    if wall && wall.adjoin >= 0 {
        next := *world.level.sectors[wall.adjoin];
        top = max(top, next.ceiling.altitude + o.height);
        bottom = min(bottom, next.floor.altitude);
    }
    if top < f.target.y  top = f.target.y;
    if bottom <= top  top = bottom;
    f.target.y = top;
    fly(b);
}

// A frame of flight (0x25988): turn toward the target at up to 100 degrees a second, unless
// already flying that way; tilt the thrust, by up to 30 degrees a second, to bring the speed
// toward 100 at 128 units off and less nearer, within the tilt allowed; throttle; push
// sideways; then thrust.
fly :: (b: *Boba_Fett) {
    o := world.objects[b.object];
    m := b.move;
    f := *b.flight;
    dt := world.clock.dt;
    v := m.velocity;
    target_angle := cast,no_check(s16) vec2_to_angle(f.target.x - o.position.x, f.target.z - o.position.z);
    velocity_angle := cast,no_check(s16) vec2_to_angle(v.x, v.z);
    if target_angle != velocity_angle {
        most := cast,no_check(s16) (((cast(s64) dt) * 0x11C7_0000) >> 32);
        turn := cast,no_check(s16) get_angle_difference(cast,no_check(s16) o.yaw, target_angle);
        if turn > most        turn = most;
        else if turn < -most  turn = -most;
        o.yaw = (o.yaw + turn) & ANGLE_MASK;
    }
    distance := dist_approx(o.position.x, o.position.z, f.target.x, f.target.z) / 128;
    if distance > FIXED_ONE  distance = FIXED_ONE;
    sin_v, cos_v := sin_cos(velocity_angle);
    speed := mul16(distance, 100 * FIXED_ONE) - (mul16(v.z, cos_v) + mul16(v.x, sin_v));
    tilt := clamp(div16(speed, 100 * FIXED_ONE), -f.pitch_range, f.pitch_range);
    most_tilt := cast,no_check(s16) (((cast(s64) dt) * 0x555_0000) >> 32);
    step := cast,no_check(s16) (cast,no_check(s16) (((cast(s64) tilt) * 0x800_0000) >> 32) - cast,no_check(s16) f.pitch);
    if step > most_tilt        step = most_tilt;
    else if step < -most_tilt  step = -most_tilt;
    f.pitch += step;
    f.scale = get_throttle(f.target.y, o.position.y, v.y, f.scale, *f.pitch_range);
    if f.lateral {
        push := mul16(f.lateral, dt);
        sin_side, cos_side := sin_cos(cast,no_check(s16) (o.yaw + 0xFFF));
        m.velocity.x += mul16(push, sin_side);
        m.velocity.z += mul16(push, cos_side);
    }
    thrust(b, f.scale, cast,no_check(s16) f.pitch, f.thrust_factor);
}

// The throttle (0x2572c), up to 1, to climb or sink toward the target height against
// gravity, changed by at most the height off plus 4 times the frame's time; the further off
// it climbs, the less the thrust may tilt. Level with it, or already rising as fast as the
// height off, none.
get_throttle :: (target_y: Fixed, y: Fixed, velocity_y: Fixed, current: Fixed, pitch_range: *Fixed) -> Fixed {
    if target_y == y return 0;
    dt := world.clock.dt;
    rising := mul16(150 * FIXED_ONE, dt) - velocity_y;
    off := y - target_y;
    if rising == off return 0;
    want := off - rising;
    if want < 0  want = 0;
    pitch_range.* = clamp(FIXED_ONE - (want - 0x13333), 0, FIXED_ONE);
    if want > FIXED_ONE  want = FIXED_ONE;
    change := want - current;
    most := mul16(abs(off) + 4 * FIXED_ONE, dt);
    if most < change         change = most;
    else if change < -most   change = -most;
    return change + current;
}

// The thrust (0x2583c): the jetpack's sound kept going, as loud as the throttle squared; up
// and, tilted, ahead along his yaw. No throttle, the sound stops.
thrust :: (b: *Boba_Fett, scale: Fixed, pitch: s32, factor: Fixed) {
    o := world.objects[b.object];
    m := b.move;
    if !scale {
        if b.thrust_playing {
            stop_sound(b.thrust_playing);
            b.thrust_playing = 0;
        }
        return;
    }
    b.thrust_playing = maintain_sound(b.thrust_playing, world.boba_fett_assets.thrust, o.position);
    if last_maintained_volume {
        set_sound_volume(b.thrust_playing, mul16(mul16(scale, scale), last_maintained_volume << 16) >> 16);
    }
    force := mul16(mul16(scale, factor), world.clock.dt);
    sin_p, cos_p := sin_cos(pitch);
    ahead := mul16(sin_p, force);
    up := mul16(cos_p, force);
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    m.velocity.x += mul16(ahead, sin_yaw);
    m.velocity.y -= up;
    m.velocity.z += mul16(ahead, cos_yaw);
}

#import "Basic";
#import "engine/dfFixed";
