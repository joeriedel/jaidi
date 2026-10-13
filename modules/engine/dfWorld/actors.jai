// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Enemies, as DARK.EXE runs them (0x25cf0-0x29398, 0x32450).
//
// An actor (the original's dispatch) ties an object to up to six modules and a movement
// module. Every frame the actor task (0x25ef8) goes through the actors in turn: an idle one
// looks for the player every so often and wakes when it sees it, waking the others around
// it; an awake one runs the modules that are due, last added first, then its physics and
// movement, then the animation the last of them asked for. A module's procedure answers
// both its runs and the messages sent to the actor (0x265c4), as in the original, and
// returns the tick it next wants to run at.
//
// The modules: the thinker (where to walk), the attack, the damage (hit points, hurting,
// dying) and the movement (turning, then moving the object through collision).
//
// The original keeps the actor being run and the animation it asked for in globals (0xfe1bc,
// 0xfe1b8); so does this, as world.actor_state.

Actor_Message :: enum s32 {
    RUN               :: 0;
    CRUSH             :: 0xC;
    DAMAGE            :: 0x16;
    EXPLOSION         :: 0x17;
    WAKEUP            :: 0x19;
    TERMINAL_VELOCITY :: 0x1A;
}

ACTOR_MODULES :: 6;
NEVER :u32: 0xFFFF_FFFF;        // A module's tick that never comes.

Module_Proc :: #type (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32;

Actor_Module :: struct {
    update: Module_Proc;
    next_tick: u32;
}

World_Actor :: struct {
    object: s32;
    modules: [ACTOR_MODULES] *Actor_Module;
    move: *Move_Module;
    anims: *[16] s32;           // WAX actions by Actor_Anim_Kind; -1 for none.
    delay: s32 = 72;            // Ticks between looks for the player while idle.
    next_tick: u32;
    alert_sound: Sound_Handle;
    alert_playing: Sound_Instance;
    fov: s32 = 0x2555;          // About 210 degrees.
    aware_range: Fixed = 20 * FIXED_ONE;  // Within it, seen from any side.
    velocity: Fixed3;           // From hits and gravity.
    last_seen: Fixed2;          // Where it last saw the player's eye.
    flags: u32 = ACTOR_NPC;
    generator: s32 = -1;        // The generator that made it, told when it goes.
}

ACTOR_IDLE           :u32: 0x1;
ACTOR_MOVING         :u32: 0x2;
ACTOR_NPC            :u32: 0x4;    // Wakes by seeing the player.
ACTOR_SEES_PLAYER    :u32: 0x8;
ACTOR_OFFICER_ALERTS :u32: 0x10;
ACTOR_TROOPER_ALERTS :u32: 0x20;

// The actions an actor shows, looked up in its table.
Actor_Anim_Kind :: enum s32 {
    MOVE :: 0; ATTACK1 :: 1; DIE1 :: 2; DIE2 :: 3; DEAD :: 4; IDLE :: 5;
    ATTACK1_END :: 6; ATTACK2 :: 7; ATTACK2_END :: 8; PAIN :: 12; SEARCH :: 14;
}

// A module's animation (0x26214, 0x262fc): frames counted in 16.16 on the animation clock
// for its rate.
Actor_Anim :: struct {
    frame_rate: s32 = 5;
    frame_count: Fixed = FIXED_ONE;
    prev_clock: Fixed;          // 0: not started.
    frame: Fixed;
    start_frame: Fixed;
    flags: u32;
    action: s32 = -1;
    state: s32;                 // The module's own state.
}

ANIM_ONCE  :u32: 0x1;              // Stops on its last frame rather than looping.
ANIM_READY :u32: 0x2;              // Done, or none to play.

// Where a module wants the object to go and face.
Actor_Target :: struct {
    position: Fixed3;
    pitch, yaw, roll: s32;
    speed, speed_vertical: Fixed;
    speed_rotation: s32;        // Angle units a second; 0 turns at once.
    flags: u32;
}

TARGET_MOVE_XZ  :u32: 0x1;
TARGET_MOVE_Y   :u32: 0x2;
TARGET_MOVE_ROT :u32: 0x4;
TARGET_FREEZE   :u32: 0x8;
TARGET_ALL_MOVE :u32: TARGET_MOVE_XZ | TARGET_MOVE_Y | TARGET_MOVE_ROT;

Move_Module :: struct {
    using #as module: Actor_Module;
    physics: Object_Move;
    target: Actor_Target;
    delta: Fixed3;              // This frame's push from the actor's velocity.
    collision_wall: *Wall;      // The wall slid along,
    collision_wall_sector: s32; // and its sector.
    collision_flags: u32;
}

MOVE_NO_Y    :u32: 0x1;            // Walks; doesn't fly up and down.
MOVE_GRAVITY :u32: 0x2;
MOVE_SLIDE   :u32: 0x4;            // Slides along what it hits.

Attack_Module :: struct {
    using #as module: Actor_Module;
    target: Actor_Target;
    delay: u32 = 218;           // Ticks between decisions.
    search_delay: u32 = 218;
    melee_delay: u32;
    ranged_delay: u32 = 291;
    lost_sight_delay: u32 = 0xAAAF;  // Back to idle after not seeing the player this long.
    lost_sight_tick: u32;
    anim: Actor_Anim;
    fire_spread: Fixed = 30 * FIXED_ONE;
    accuracy_tick: u32;
    fire_offset: Fixed3;
    projectile: Projectile_Type = .RIFLE_BOLT;
    melee_sound, fire_sound: Sound_Handle;
    melee_range, min_distance: Fixed;
    max_distance: Fixed = 160 * FIXED_ONE;
    melee_damage: Fixed;
    melee_rate: Fixed = 230 * FIXED_ONE;
    attack_flags: u32 = ATTACK_RANGED | ATTACK_LIT_RANGED;
}

ATTACK_MELEE      :u32: 0x1;
ATTACK_RANGED     :u32: 0x2;
ATTACK_LIT_MELEE  :u32: 0x4;
ATTACK_LIT_RANGED :u32: 0x8;

// The attack's states.
ATTACK_DELAY    :s32: 0;
ATTACK_DECIDE   :s32: 1;
ATTACK_FIRST    :s32: 2;           // Melee, or ranged when there's no melee.
ATTACK_FIRST_END :s32: 3;
ATTACK_SECOND   :s32: 4;           // Ranged, when there's melee too.
ATTACK_SECOND_END :s32: 5;

// The damage module takes an attack module's shape for its animation and target.
Damage_Module :: struct {
    using #as attack: Attack_Module;
    hp: Fixed = 4 * FIXED_ONE;
    drop: s32 = -1;             // The item it leaves, into ITEMS.
    hurt_sound, die_sound: Sound_Handle;
    hurt_playing: Sound_Instance;
    stop_on_hit := true;
    die_effect: s32 = -1;       // Hit_Effect_Type, -1 for none.
}

// The flying module (0x26e78) and the remote's (0x26d54) have the thinker's shape: a target,
// a delay, and a state in the animation's place.
Flying_Module :: struct {
    using #as module: Actor_Module;
    target: Actor_Target;
    delay: s32 = 0x91;
    anim: Actor_Anim;
}

// The flying module's and the remote's states.
FLYING_WAIT   :s32: 0;
FLYING_MOVE   :s32: 1;
FLYING_CHOOSE :s32: 2;

// The thinker's states.
THINKER_MOVE :s32: 1;
THINKER_TURN :s32: 2;

Thinker_Module :: struct {
    using #as module: Actor_Module;
    target: Actor_Target;
    delay: s32 = 72;
    max_walk: u32 = 728;        // Ticks it walks before choosing again.
    start_delay: u32;
    anim: Actor_Anim;
    walk_until: u32;
    last_seen_until: u32 = NEVER;
    collided_tick: u32;
    target_offset: Fixed = 3 * FIXED_ONE;
    target_variation: Fixed;
    approach_variation: s32 = 0x1000;
}

world_get_actor_count :: () -> int {
    count := 0;
    for world.actors  if it  count += 1;
    return count;
}

// The actor on an object, or null.
world_get_actor :: (object: s32) -> *World_Actor { return world.objects[object].actor; }

world_is_actor_idle :: (actor: *World_Actor) -> bool { return (actor.flags & ACTOR_IDLE) != 0; }

world_get_actor_hp :: (actor: *World_Actor) -> Fixed {
    for actor.modules {
        if !it continue;
        if it.update == damage_update || it.update == barrel_damage_update || it.update == scenery_damage_update || it.update == sewer_damage_update {
            return (cast(*Damage_Module) it).hp;
        }
    }
    return 0;
}

// What the music hears of the fighting: an enemy has seen the player or been hit
// (0x23910), or is still fighting (0x2398b). The caller hands these to dfMusic.
Music_Event :: struct {
    kind: Music_Event_Kind;
    tick: s32;
}

Music_Event_Kind :: enum u8 { FIGHT; SUSTAIN; }

world_take_music_events :: () -> [] Music_Event {
    events := array_copy(world.music_events,, temp);
    array_reset_keeping_memory(*world.music_events);
    return events;
}

#scope_module

Actor_State :: struct {
    current: *World_Actor;            // Null once killed.
    current_anim: *Actor_Anim;
    alert_tick: u32;
    officer_alert, trooper_alert: s32;

    // What a message carries: the projectile that hit, or an explosion's damage and force.
    message_projectile: *Projectile;
    message_damage, message_force: Fixed;

    // The actors' and the free movement's tasks, yielding each frame: when they run next
    // and whether they're waiting for the AI to come back on (cheats.jai).
    wake, free_moves_wake: s32;
    polling, free_moves_polling: bool;
}

// The enemies and generators of the O file (0x1582e, 0x32450), by their logic: those done
// so far.
create_actors :: () {
    load_actor_sounds();
    for * l, index: world.level_objects.objects {
        o := world.objects[index];
        if o.sector < 0 continue;
        for l.logics {
            world.tasks.load_logic = xx it_index;
            found, name, rest := split_from_left(it, #char " ");
            if !found  name = it;
            if name == "GENERATOR" {
                create_generator(xx index, rest, l, xx it_index);
                break;
            }
            if create_enemy(xx index, name) break;
        }
    }
}

// The actor's attack module, if it has one.
get_attack_module :: (actor: *World_Actor) -> *Attack_Module {
    for actor.modules {
        if it && (it.update == attack_update || it.update == sewer_attack_update) return cast(*Attack_Module) it;
    }
    return null;
}

// A movement module of an object's own, outside any actor (0x2674c): the special logics'.
// Unlike an actor's, its target stays until changed.
Free_Move :: struct {
    using #as move: Move_Module;
    object: s32;
    velocity: Fixed3;           // From pushes and gravity.
    anim: Actor_Anim;           // A sprite's, played until done.
}

// In the lowest free slot, as the original's pool (0xfe1ac) gives them out.
create_free_move :: (object: s32) -> *Free_Move {
    m := New(Free_Move);
    m.object = object;
    m.anim.flags = ANIM_READY;
    placed := false;
    for * world.free_moves  if !it.* { it.* = m; placed = true; break; }
    if !placed  array_add(*world.free_moves, m);
    return m;
}

free_free_move :: (m: *Free_Move) {
    for * world.free_moves  if it.* == m { it.* = null; break; }
    free(m);
}

// Every frame (0x267a0), in the pool's order: each turns toward its target, then with
// somewhere to go or a push moves, its push slid along what it hit; a sprite steps its
// animation.
update_free_moves :: () {
    s := *world.actor_state;
    if !is_ai_task_due(*s.free_moves_wake, *s.free_moves_polling) return;
    defer yield_ai_task(*s.free_moves_wake, *s.free_moves_polling, 0, false);
    for i: 0..world.free_moves.count-1 {
        m := world.free_moves[i];
        if !m continue;
        o := world.objects[m.object];
        m.physics.wall = null;
        if m.target.flags & TARGET_MOVE_ROT  turn_object(m.object, m);
        apply_actor_physics(m.object, m, *m.velocity);
        if (m.target.flags & (TARGET_MOVE_XZ | TARGET_MOVE_Y)) || m.velocity.x || m.velocity.y || m.velocity.z {
            move_and_collide(m.object, m);
            if m.physics.responds  slide_offset(m.physics.response_dir, *m.velocity);
        }
        if o.class == .SPRITE && !(m.anim.flags & ANIM_READY) {
            o.anim = m.anim.action;
            if advance_animation(*m.anim, o)  m.anim.flags |= ANIM_READY;
        }
    }
}

// Whether it has come to rest (0x268b8): under water, or on its floor and not pushed along
// at 5 a second or more either way.
has_free_move_landed :: (m: *Free_Move) -> bool {
    o := world.objects[m.object];
    sector := *world.level.sectors[o.sector];
    if sector.second_altitude >= 1 && o.position.y > sector.floor.altitude return true;
    if abs(m.velocity.x) > 0x4FFFF || abs(m.velocity.z) > 0x4FFFF return false;
    floor := get_floor_and_ceiling(sector, o.position.y);
    return o.position.y >= floor;
}

unload_actors :: () {
    for world.free_moves  if it  free(it);
    array_free(world.free_moves);
    for world.actors  if it  free_actor(it);
    array_free(world.actors);
    world.actor_state = .{};
}

// Every frame (0x25ef8).
update_actors :: () {
    tick := cast(u32) world.clock.tick;
    s := *world.actor_state;
    if !is_ai_task_due(*s.wake, *s.polling) return;
    defer yield_ai_task(*s.wake, *s.polling, 0, false);
    remove_nulls(*world.actors);
    for i: 0..world.actors.count-1 {
        actor := world.actors[i];
        if !actor continue;
        o := world.objects[actor.object];
        if (actor.flags & ACTOR_IDLE) && (actor.flags & ACTOR_NPC) {
            if actor.next_tick < tick {
                actor.next_tick = tick + cast(u32) actor.delay;
                if is_player_visible(o, actor.fov, actor.aware_range) {
                    send_actor_message(actor, .WAKEUP);
                    alert_fight();
                    wake_actors_in_range(o.sector, 150 * FIXED_ONE, o.position, actor.object);
                }
            }
            continue;
        }
        s.current = actor;
        s.current_anim = null;
        for < m: 0..ACTOR_MODULES-1 {
            module := actor.modules[m];
            if !module || !module.update || module.next_tick >= tick continue;
            next := module.update(actor, module, .RUN);
            if !s.current break;
            module.next_tick = next;
        }
        if !s.current || (actor.flags & ACTOR_IDLE) continue;
        if actor.move {
            apply_actor_physics(actor.object, actor.move, *actor.velocity);
            move_update(actor, actor.move);
        }
        if o.class == .SPRITE && s.current_anim {
            o.anim = s.current_anim.action;
            if advance_animation(s.current_anim, o)  s.current_anim.flags |= ANIM_READY;
        }
    }
    s.current = null;
}

// A message to an actor (0x265c4): each module first, last added first, then what wakes it.
send_actor_message :: (actor: *World_Actor, message: Actor_Message) {
    s := *world.actor_state;
    s.current = actor;
    o := world.objects[actor.object];
    for < m: 0..ACTOR_MODULES-1 {
        module := actor.modules[m];
        if !module || !module.update continue;
        next := module.update(actor, module, message);
        if !s.current return;
        if next != NEVER  module.next_tick = next;
    }
    if message == .DAMAGE || message == .EXPLOSION {
        if actor.flags & ACTOR_IDLE  alert_fight();
        s.current_anim = null;
        actor.flags &= ~ACTOR_IDLE;
    } else if message == .WAKEUP {
        if actor.flags & ACTOR_IDLE  alert_fight();
        if (actor.flags & ACTOR_NPC) && (actor.flags & ACTOR_IDLE) {
            tick := cast(u32) world.clock.tick;
            if s.alert_tick < tick {
                sound: Sound_Handle;
                if actor.flags & ACTOR_OFFICER_ALERTS {
                    sound = world.actor_sounds.officer_alerts[s.officer_alert];
                    s.officer_alert = (s.officer_alert + 1) % 4;
                } else if actor.flags & ACTOR_TROOPER_ALERTS {
                    sound = world.actor_sounds.trooper_alerts[s.trooper_alert];
                    s.trooper_alert = (s.trooper_alert + 1) % 8;
                } else {
                    sound = actor.alert_sound;
                }
                actor.alert_playing = play_sound_at(sound, o.position);
                s.alert_tick = tick + 291;
            }
            actor.flags &= ~ACTOR_IDLE;
        }
    }
}

// A message to whatever acts on an object: an actor, a turret, a mousebot, a welder, a dark
// trooper, Boba Fett, a Kell dragon, or the player.
send_object_message :: (object: s32, message: Actor_Message) {
    if object == OBJECT_IS_PLAYER {
        player_message(message);
        return;
    }
    o := world.objects[object];
    if o.actor        send_actor_message(o.actor, message);
    else if o.turret  send_turret_message(o.turret, message);
    else if o.mousebot  send_mousebot_message(o.mousebot, message);
    else if o.welder  send_welder_message(o.welder, message);
    else if o.dark_trooper  send_dark_trooper_message(o.dark_trooper, message);
    else if o.boba_fett  send_boba_fett_message(o.boba_fett, message);
    else if o.kell_dragon  send_kell_dragon_message(o.kell_dragon, message);
}

// The actor on an object goes with it.
free_object_actor :: (object: s32) {
    actor := world.objects[object].actor;
    if !actor return;
    if world.actor_state.current == actor  world.actor_state.current = null;
    free_actor(actor);
}


// Wakes the actors within range of a point that a path along the ground reaches from it
// (0x5c8f8): through openings at least half a unit high, into each one's sector. The
// original tests the starting sector's bounds and heights for every sector it looks
// through, so once those pass it looks at all of them.
wake_actors_in_range :: (start: s32, range: Fixed, origin: Fixed3, exclude: s32) {
    if start < 0 return;
    first := *world.level.sectors[start];
    if origin.x - range > first.bounds_max.x || first.bounds_min.x > origin.x + range return;
    if origin.z - range > first.bounds_max.z || first.bounds_min.z > origin.z + range return;
    floor, ceiling := get_floor_and_ceiling(first, origin.y);
    if origin.y - range > floor || ceiling > origin.y + range return;
    for sector_index: 0..world.level.sectors.count-1 {
        for index: walk_sector(xx sector_index, live = true) {
            if index == exclude continue;
            o := world.objects[index];
            if !(o.entity & ENTITY_AI_ACTOR) continue;
            p := o.position;
            if p.x < origin.x - range || p.x > origin.x + range continue;
            if p.z < origin.z - range || p.z > origin.z + range continue;
            if p.y < origin.y - range || p.y > origin.y + range continue;
            sector := start;
            wall: *Wall;
            if p.x != origin.x || p.z != origin.z  wall, sector = find_path_wall(start, origin.x, origin.z, p.x, p.z);
            while wall && sector != o.sector {
                if wall.adjoin < 0 { sector = -1; break; }
                sector = wall.adjoin;
                next := *world.level.sectors[sector];
                if next.floor.altitude - next.ceiling.altitude < 0x8000 break;
                wall, sector = find_next_path_wall(sector);
            }
            if sector != o.sector continue;
            send_object_message(index, .WAKEUP);
        }
    }
}

alert_fight :: () {
    array_add(*world.music_events, .{.FIGHT, world.clock.tick});
}

sustain_fight :: () {
    array_add(*world.music_events, .{.SUSTAIN, world.clock.tick});
}

// The player's eye, where enemies aim and look (0xfe3a0).
get_player_eye :: () -> Fixed3 {
    p := *world.player;
    return .{p.position.x, p.position.y + p.bob - p.height, p.position.z};
}

// The animation clocks the timer runs (0x1ef6c): for each frame rate up to 12, frames
// counted in 16.16, rate x 450 - 1 a tick. Rates under 4 don't move.
advance_animation_clocks :: () {
    for 4..12  world.anim_clocks[it] += cast(Fixed) (it * 450 - 1);
}

Actor_Sounds :: struct {
    officer_alerts: [4] Sound_Handle;
    trooper_alerts: [8] Sound_Handle;
    trooper_hurt, trooper_die: Sound_Handle;
    rifle, pistol, concussion: Sound_Handle;
    gamorrean_alert, gamorrean_hurt, gamorrean_die, axe: Sound_Handle;
    reeyees_alert, reeyees_hurt, reeyees_die: Sound_Handle;
    bossk_alert, bossk_hurt, bossk_die: Sound_Handle;
    interrogation_alert, probe_alert, stun, probe_fire, remote_hum: Sound_Handle;
    small_explosion, probe_alarm, tiny_explosion: Sound_Handle;
    creature_alert, creature_strike, creature_hurt, creature_die: Sound_Handle;
}

#scope_file

// The enemies' sounds (0x31f70, 0x48238): alerts and hurting at 0x54, their weapons at 1,
// the player's at 0x77.
load_actor_sounds :: () {
    a := *world.actor_sounds;
    a.gamorrean_alert = register_sound("GAMOR-3.VOC", 0x54);
    a.reeyees_alert   = register_sound("REEYEE-1.VOC", 0x54);
    a.bossk_alert     = register_sound("BOSSK-1.VOC", 0x54);
    a.creature_alert  = register_sound("CREATUR1.VOC", 0x54);
    a.probe_alert     = register_sound("PROBE-1.VOC", 0x54);
    a.interrogation_alert = register_sound("INTALERT.VOC", 0x54);
    for 0..3  a.officer_alerts[it] = register_sound(tprint("RANOFC0%.VOC", ifx it == 0 then 2 else it + 3), 0x54);
    for 0..7  a.trooper_alerts[it] = register_sound(tprint("RANSTO0%.VOC", it + 1), 0x54);
    a.axe = register_sound("AXE-1.VOC", 1);
    a.stun = register_sound("INTSTUN.VOC", 1);
    a.probe_fire = register_sound("PROBFIR1.VOC", 1);
    a.creature_strike = register_sound("CREATUR2.VOC", 1);
    a.remote_hum = register_sound("REMOTE-2.VOC", 1);
    set_sound_level(a.remote_hum, 40);
    a.trooper_hurt   = register_sound("ST-HRT-1.VOC", 0x54);
    a.gamorrean_hurt = register_sound("GAMOR-2.VOC", 0x54);
    a.reeyees_hurt   = register_sound("REEYEE-2.VOC", 0x54);
    a.bossk_hurt     = register_sound("BOSSK-3.VOC", 0x54);
    a.creature_hurt  = register_sound("CREATHRT.VOC", 0x54);
    a.trooper_die    = register_sound("ST-DIE-1.VOC", 0x54);
    a.bossk_die      = register_sound("BOSSKDIE.VOC", 0x54);
    a.reeyees_die    = register_sound("REEYEE-3.VOC", 0x54);
    a.gamorrean_die  = register_sound("GAMOR-1.VOC", 0x54);
    a.creature_die   = register_sound("CREATDIE.VOC", 0x54);
    a.small_explosion = register_sound("EX-SMALL.VOC", 0x54);
    a.probe_alarm    = register_sound("PROBALM.VOC", 0x54);
    a.tiny_explosion = register_sound("EX-TINY1.VOC", 0x40);
    a.rifle  = register_sound("RIFLE-1.VOC", 0x77);
    a.pistol = register_sound("PISTOL-1.VOC", 0x77);
    a.concussion = register_sound("CONCUSS5.VOC", 0x77);
}

// The anim tables (0xe6664 and on).
TROOPER_ANIMS  :: s32.[0, 1, 3, 2, 4, 5, -1, -1, -1, -1, -1, -1, 12, -1, -1, -1];
COMMANDO_ANIMS :: s32.[0, 1, 2, 3, 4, 5,  6, -1, -1, -1, -1, -1, 12, -1, -1, -1];
OFFICER_ANIMS  :: s32.[0, 6, 2, 3, 4, 5,  1, -1, -1, -1, -1, -1, 12, -1, -1, -1];

REEYEES_ANIMS   :: s32.[0, 1, 2, 3, 4, 5, -1,  7,  8, -1, -1, -1, 12, -1, -1, -1];
GAMORREAN_ANIMS :: s32.[0, 1, 2, 3, 4, 5, -1, -1, -1, -1, -1, -1, 12, -1, -1, -1];
BOSSK_ANIMS     :: s32.[0, 1, 2, 3, 4, 5,  6, -1, -1, -1, -1, -1, 12, -1, -1, -1];
INTERROGATION_ANIMS :: s32.[0, 1, 2, 3, 4, 5, -1, 7, -1, -1, -1, -1, 12, -1, -1, -1];
PROBE_ANIMS     :: s32.[0, 1, 2, 3, 4, 5, -1, -1, -1, -1, -1, -1, 12, -1, -1, -1];
REMOTE_ANIMS    :: s32.[0, 0, 2, 3, -1, 0, -1, -1, -1, -1, -1, -1, 0, -1, -1, -1];
SEWER_ANIMS     :: s32.[-1, 1, 2, 3, 4, 5, 6, -1, -1, -1, -1, -1, -1, -1, 12, 13];
BARREL_ANIMS    :: s32.[0, -1, 1, 1, -1, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1];
SCENERY_ANIMS   :: s32.[0, -1, -1, -1, 1, 0, -1, -1, -1, -1, -1, -1, 0, -1, -1, -1];

trooper_anims   := TROOPER_ANIMS;
commando_anims  := COMMANDO_ANIMS;
officer_anims   := OFFICER_ANIMS;
reeyees_anims   := REEYEES_ANIMS;
gamorrean_anims := GAMORREAN_ANIMS;
bossk_anims     := BOSSK_ANIMS;
interrogation_anims := INTERROGATION_ANIMS;
probe_anims     := PROBE_ANIMS;
remote_anims    := REMOTE_ANIMS;
sewer_anims     := SEWER_ANIMS;
barrel_anims    := BARREL_ANIMS;
scenery_anims   := SCENERY_ANIMS;

// What each officer leaves: energy, a code or a key (0x32450).
OFFICER_NAMES :: string.["I_OFFICER", "I_OFFICER1", "I_OFFICER2", "I_OFFICER3", "I_OFFICER4",
    "I_OFFICER5", "I_OFFICER6", "I_OFFICER7", "I_OFFICER8", "I_OFFICER9", "I_OFFICERR",
    "I_OFFICERY", "I_OFFICERB"];
OFFICER_DROPS :: s32.[11, 30, 31, 32, 33, 34, 35, 36, 37, 38, 23, 24, 25];

#scope_module

// The original's enemy setup (0x32450). True when the logic made an actor.
create_enemy :: (object: s32, logic: string) -> bool {
    a := *world.actor_sounds;
    o := world.objects[object];
    if logic == "TROOP" || logic == "STORM1" || logic == "COMMANDO" {
        commando := logic == "COMMANDO";
        o.entity = ENTITY_AI_ACTOR | ENTITY_GRAVITY;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = 0;
        actor.flags |= ACTOR_TROOPER_ALERTS;
        damage := create_damage_module(actor);
        damage.hp = ifx commando then 27 * FIXED_ONE else 18 * FIXED_ONE;
        damage.drop = ITEM_RIFLE;
        damage.die_sound = a.trooper_die;
        damage.hurt_sound = a.trooper_hurt;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.fire_sound = a.rifle;
        attack.attack_flags = (attack.attack_flags & ~(ATTACK_MELEE | ATTACK_RANGED)) | ATTACK_RANGED;
        attack.projectile = .RIFLE_BOLT;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = ifx commando then 9 * FIXED_ONE else 8 * FIXED_ONE;
        thinker.delay = 116;
        thinker.start_delay = ifx commando then cast(u32) 145 else 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.collision_flags |= MOVE_NO_Y;
        actor.move.physics.width = o.width;
        actor.anims = ifx commando then *commando_anims else *trooper_anims;
        set_up_idle_animation(actor);
        return true;
    }
    for OFFICER_NAMES {
        if it != logic continue;
        o.entity = ENTITY_AI_ACTOR | ENTITY_GRAVITY;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = 0;
        actor.flags |= ACTOR_OFFICER_ALERTS;
        damage := create_damage_module(actor);
        damage.hp = 9 * FIXED_ONE;
        damage.die_sound = a.trooper_die;
        damage.hurt_sound = a.trooper_hurt;
        damage.drop = OFFICER_DROPS[it_index];
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.fire_sound = a.pistol;
        attack.attack_flags = (attack.attack_flags & ~(ATTACK_MELEE | ATTACK_RANGED)) | ATTACK_RANGED;
        attack.projectile = .PISTOL_BOLT;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = 7 * FIXED_ONE;
        thinker.delay = 0;
        thinker.start_delay = 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.collision_flags |= MOVE_NO_Y;
        actor.move.physics.width = o.width;
        actor.anims = *officer_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "G_GUARD" {
        // Melee only, with the axe; hits don't stop it.
        o.entity = ENTITY_AI_ACTOR;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = a.gamorrean_alert;
        damage := create_damage_module(actor);
        damage.hp = 90 * FIXED_ONE;
        damage.stop_on_hit = false;
        damage.die_sound = a.gamorrean_die;
        damage.hurt_sound = a.gamorrean_hurt;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.melee_delay = 0xE9;
        attack.melee_range = 13 * FIXED_ONE;
        attack.melee_damage = 40 * FIXED_ONE;
        attack.melee_rate = 360 * FIXED_ONE;
        attack.melee_sound = a.axe;
        attack.attack_flags = (attack.attack_flags & ~ATTACK_RANGED) | ATTACK_MELEE;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.approach_variation = 0xAAA;
        thinker.delay = 0;
        thinker.target.speed_rotation = 0x3FFF;
        thinker.target.speed = 12 * FIXED_ONE;
        thinker.start_delay = 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.collision_flags |= MOVE_NO_Y;
        actor.move.physics.width = o.width;
        actor.anims = *gamorrean_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "REE_YEES" || logic == "REE_YEES2" {
        // Both strike close up; REE_YEES also lobs thermal detonators from farther than their
        // blast reaches, and leaves five.
        throws := logic == "REE_YEES";
        o.entity = ENTITY_AI_ACTOR;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = a.reeyees_alert;
        damage := create_damage_module(actor);
        damage.hp = 36 * FIXED_ONE;
        if throws  damage.drop = ITEM_DETONATORS;
        damage.hurt_sound = a.reeyees_hurt;
        damage.die_sound = a.reeyees_die;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.melee_sound = 0;
        attack.max_distance = 100 * FIXED_ONE;
        attack.melee_range = 10 * FIXED_ONE;
        attack.melee_damage = 15 * FIXED_ONE;
        if throws {
            attack.projectile = .THERMAL_DETONATOR;
            attack.fire_sound = 0;
            attack.ranged_delay = 0x1B4;
            attack.attack_flags = (attack.attack_flags & ~ATTACK_LIT_RANGED) | ATTACK_MELEE | ATTACK_RANGED;
            attack.min_distance = world.hit_effects[HIT_EFFECT_THERMAL_DETONATOR].range;
        } else {
            attack.attack_flags = (attack.attack_flags & ~(ATTACK_RANGED | ATTACK_LIT_RANGED)) | ATTACK_MELEE;
        }
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = 13 * FIXED_ONE;
        thinker.start_delay = 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.collision_flags |= MOVE_NO_Y;
        actor.move.physics.width = o.width;
        actor.anims = *reeyees_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "INT_DROID" || logic == "PROBE_DROID" {
        // Flying: the thinker steers across, the flying module up and down. The interrogation
        // droid stuns close up and fires beyond; the probe droid fires, and bursts when it
        // dies.
        probe := logic == "PROBE_DROID";
        o.entity = ENTITY_AI_ACTOR | ENTITY_FLYING;
        o.aimable = true;
        actor := create_actor(object);
        actor.fov = 0x4000;
        actor.alert_sound = ifx probe then a.probe_alert else a.interrogation_alert;
        damage := create_damage_module(actor);
        damage.hp = 45 * FIXED_ONE;
        damage.drop = ITEM_POWER;
        damage.stop_on_hit = false;
        if probe {
            damage.die_effect = HIT_EFFECT_EXPLOSION;
            damage.die_sound = a.probe_alarm;
        } else {
            damage.die_sound = a.small_explosion;
        }
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        if probe {
            attack.projectile = .RIFLE_BOLT;
            attack.fire_offset.y = -0x88000;
            attack.fire_sound = a.probe_fire;
            attack.attack_flags = (attack.attack_flags & ~(ATTACK_MELEE | ATTACK_RANGED)) | ATTACK_RANGED;
        } else {
            attack.projectile = .PROBE;
            attack.fire_offset.y = 0x2666;
            attack.melee_range = 30 * FIXED_ONE;
            attack.fire_sound = a.probe_fire;
            attack.melee_sound = a.stun;
            attack.melee_damage = 5 * FIXED_ONE;
            attack.attack_flags |= ATTACK_MELEE | ATTACK_RANGED;
        }
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0;
        thinker.target.speed = 6 * FIXED_ONE;
        thinker.delay = ifx probe then cast(s32) 0 else 116;
        thinker.start_delay = 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        flying := create_flying_module(actor);
        flying.target.speed_rotation = 0x7FFF;
        flying.target.speed = 13 * FIXED_ONE;
        flying.target.speed_vertical = ifx probe then 2 * FIXED_ONE else 10 * FIXED_ONE;
        flying.delay = 0x1B4;
        add_module(actor, cast(*Actor_Module) flying);
        actor.move = create_move_module(actor);
        set_up_flying_move(actor.move, o);
        actor.anims = ifx probe then *probe_anims else *interrogation_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "REMOTE" {
        // The training remote: turns about at random, hovers, fires stinging bolts close up;
        // it opens no doors.
        o.entity = ENTITY_AI_ACTOR | ENTITY_FLYING | ENTITY_REMOTE;
        o.aimable = true;
        actor := create_actor(object);
        actor.fov = 0x4000;
        damage := create_damage_module(actor);
        damage.hp = 9 * FIXED_ONE;
        damage.die_sound = a.tiny_explosion;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.projectile = .REMOTE_BOLT;
        attack.fire_sound = a.probe_fire;
        attack.fire_offset.y = 0x4000;
        attack.attack_flags = (attack.attack_flags & ~(ATTACK_MELEE | ATTACK_RANGED)) | ATTACK_RANGED;
        attack.max_distance = 50 * FIXED_ONE;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = 15 * FIXED_ONE;
        thinker.target.speed_vertical = 10 * FIXED_ONE;
        thinker.delay = 0x1B4;
        thinker.start_delay = 0x6D;
        thinker.target_offset = 9 * FIXED_ONE;
        add_module(actor, cast(*Actor_Module) thinker);
        spin := create_flying_module(actor);
        spin.update = remote_update;
        spin.target.speed_rotation = 0x7FFF;
        spin.delay = 291;
        add_module(actor, cast(*Actor_Module) spin);
        flying := create_flying_module(actor);
        flying.target.speed_rotation = 0x7FFF;
        flying.target.speed = 13 * FIXED_ONE;
        flying.target.speed_vertical = 10 * FIXED_ONE;
        flying.delay = 291;
        add_module(actor, cast(*Actor_Module) flying);
        actor.move = create_move_module(actor);
        set_up_flying_move(actor.move, o);
        o.entity &= ~cast(u32) ENTITY_SMART;
        actor.anims = *remote_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "SEWER1" {
        // The sewer creature: under the water and unseen until it surfaces to strike, its
        // walking done below.
        o.flags |= OBJECT_HIDDEN;
        o.entity = ENTITY_AI_ACTOR;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = a.creature_alert;
        actor.fov = 0x4000;
        damage := create_damage_module(actor);
        damage.update = sewer_damage_update;
        damage.hp = 36 * FIXED_ONE;
        damage.hurt_sound = a.creature_hurt;
        damage.die_sound = a.creature_die;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.update = sewer_attack_update;
        attack.search_delay = 0x48D;
        attack.melee_delay = 0x48D;
        attack.melee_range = 13 * FIXED_ONE;
        attack.melee_damage = 20 * FIXED_ONE;
        attack.melee_rate = 360 * FIXED_ONE;
        attack.attack_flags = (attack.attack_flags & ~ATTACK_RANGED) | ATTACK_MELEE;
        attack.melee_sound = a.creature_strike;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = 18 * FIXED_ONE;
        thinker.delay = 0x3A;
        thinker.start_delay = 0x48;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.physics.step_down = 0;
        actor.move.physics.step_up = 0;
        actor.move.collision_flags = (actor.move.collision_flags & ~MOVE_GRAVITY) | MOVE_NO_Y;
        actor.move.physics.width = o.width;
        o.entity &= ~cast(u32) ENTITY_SMART;
        actor.anims = *sewer_anims;
        set_up_idle_animation(actor);
        return true;
    }
    if logic == "BARREL" {
        o.entity = ENTITY_AI_ACTOR;
        o.aimable = true;
        create_barrel_actor(object, 11 * FIXED_ONE);
        return true;
    }
    if logic == "LAND_MINE" {
        // A placed mine (projectile type 9) takes the object's place, with the barrel's
        // damage on it.
        proj := create_projectile(.LAND_MINE_PLACED, o.sector, o.position, -1);
        free_object(object);
        world.objects[proj.object].entity = ENTITY_LANDMINE;
        create_barrel_actor(proj.object, 20 * FIXED_ONE);
        return true;
    }
    if logic == "TURRET" {
        create_turret(object);
        return true;
    }
    if logic == "MOUSEBOT" {
        create_mousebot(object);
        return true;
    }
    if logic == "WELDER" {
        create_welder(object);
        return true;
    }
    if logic == "D_TROOP1" || logic == "D_TROOP2" || logic == "D_TROOP3" {
        create_dark_trooper(object, cast(s32) (logic[7] - #char "0"));
        return true;
    }
    if logic == "BOBA_FETT" {
        create_boba_fett(object);
        return true;
    }
    if logic == "KELL" {
        create_kell_dragon(object);
        return true;
    }
    if logic == "SCENERY" {
        // Scenery breaks: one hit shows its broken action, left behind.
        o.aimable = false;
        o.entity = ENTITY_SCENERY;
        actor := create_actor(object);
        actor.flags &= ~ACTOR_NPC;
        damage := create_damage_module(actor);
        damage.update = scenery_damage_update;
        damage.hp = FIXED_ONE;
        damage.anim.flags |= ANIM_READY;
        add_module(actor, cast(*Actor_Module) damage);
        actor.anims = *scenery_anims;
        return true;
    }
    if logic == "BOSSK" {
        // The concussion rifle, never scattered.
        o.entity = ENTITY_AI_ACTOR;
        o.aimable = true;
        actor := create_actor(object);
        actor.alert_sound = a.bossk_alert;
        damage := create_damage_module(actor);
        damage.hp = 45 * FIXED_ONE;
        damage.drop = ITEM_CONCUSSION;
        damage.die_sound = a.bossk_die;
        damage.hurt_sound = a.bossk_hurt;
        add_module(actor, cast(*Actor_Module) damage);
        attack := create_attack_module(actor);
        attack.projectile = .CONCUSSION;
        attack.max_distance = 100 * FIXED_ONE;
        attack.min_distance = 10 * FIXED_ONE;
        attack.fire_spread = 0;
        attack.fire_sound = a.concussion;
        attack.attack_flags = (attack.attack_flags & ~(ATTACK_MELEE | ATTACK_RANGED)) | ATTACK_RANGED;
        add_module(actor, cast(*Actor_Module) attack);
        thinker := create_thinker_module(actor);
        thinker.target.speed_rotation = 0x7FFF;
        thinker.target.speed = 9 * FIXED_ONE;
        thinker.delay = 0;
        thinker.start_delay = 291;
        thinker.anim.flags &= ~ANIM_ONCE;
        add_module(actor, cast(*Actor_Module) thinker);
        actor.move = create_move_module(actor);
        actor.move.collision_flags |= MOVE_NO_Y;
        actor.move.physics.width = o.width;
        actor.anims = *bossk_anims;
        set_up_idle_animation(actor);
        return true;
    }
    return false;
}

#scope_file

// A new actor on an object (0x25cf0).
create_actor :: (object: s32) -> *World_Actor {
    actor := New(World_Actor);
    actor.object = object;
    // At the end of the list, as the original's (0xfe1b4).
    array_add(*world.actors, actor);
    world.objects[object].actor = actor;
    world.actor_state.current = actor;
    return actor;
}

add_module :: (actor: *World_Actor, module: *Actor_Module) {
    for * actor.modules  if !it.* { it.* = module; return; }
}

free_actor :: (actor: *World_Actor) {
    tell_generator_gone(actor.generator, actor.object);
    for actor.modules  if it  free(it);
    if actor.move  free(actor.move);
    world.objects[actor.object].actor = null;
    for * world.actors  if it.* == actor { it.* = null; break; }
    free(actor);
}

// The actor being run dies for good (0x26480): it and its modules go, and the object.
kill_current_actor :: () {
    s := *world.actor_state;
    actor := s.current;
    if !actor return;
    object := actor.object;
    free_actor(actor);
    free_object_projectile(object);
    free_object(object);
    s.current = null;
}

// Idle, showing its idle action from the first frame (0x263e4).
set_up_idle_animation :: (actor: *World_Actor) {
    actor.flags = (actor.flags | ACTOR_IDLE) & ~ACTOR_MOVING;
    actor.next_tick = cast(u32) world.clock.tick + cast(u32) actor.delay;
    o := world.objects[actor.object];
    o.anim = get_anim_index(actor, .IDLE);
    o.frame = 0;
}

get_anim_index :: (actor: *World_Actor, kind: Actor_Anim_Kind) -> s32 {
    o := world.objects[actor.object];
    if o.class != .SPRITE || !actor.anims return -1;
    return actor.anims.*[kind];
}

// Starts one of the actor's actions on a module's animation (0x262fc).
set_up_animation :: (actor: *World_Actor, kind: Actor_Anim_Kind, anim: *Actor_Anim) {
    o := world.objects[actor.object];
    action: s32 = -1;
    if o.class == .SPRITE  action = actor.anims.*[kind];
    set_up_action_animation(o, action, anim);
}

#scope_module

// Starts a WAX action on an animation (0x2636c): the bosses name theirs.
set_up_action_animation :: (o: *Object, action_index: s32, anim: *Actor_Anim) {
    anim.flags |= ANIM_READY;
    if o.class != .SPRITE return;
    anim.prev_clock = 0;
    anim.action = action_index;
    anim.start_frame = 0;
    if anim.action == -1 return;
    wax := get_object_sprite(o);
    if !wax || anim.action >= wax.actions.count return;
    action := *wax.actions[anim.action];
    frames := ifx action.views then action.views[0].frames.count else 0;
    anim.frame_count = cast(Fixed) frames << 16;
    anim.frame_rate = min(action.frame_rate, 12);
    anim.flags &= ~ANIM_READY;
}

// Plays only frames first to last of its action (0x263c0).
set_animation_frames :: (anim: *Actor_Anim, first: s32, last: s32) {
    anim.start_frame = first << 16;
    anim.frame_count = (last + 1 - first) << 16;
}

#scope_file

set_current_animation :: (anim: *Actor_Anim) {
    if anim.action != -1  world.actor_state.current_anim = anim;
}

// One frame of an animation on its clock (0x26214): true once a play-once one has ended,
// on its last frame.
advance_animation :: (anim: *Actor_Anim, o: *Object) -> bool {
    clock := world.anim_clocks[anim.frame_rate];
    if !anim.prev_clock {
        anim.prev_clock = clock;
        anim.flags &= ~ANIM_READY;
        o.frame = anim.start_frame >> 16;
        anim.frame = anim.start_frame;
        return false;
    }
    anim.frame += clock - anim.prev_clock;
    anim.prev_clock = clock;
    end := anim.start_frame + anim.frame_count;
    if end <= anim.frame {
        if anim.flags & ANIM_ONCE {
            anim.frame = end - FIXED_ONE;
            o.frame = anim.frame >> 16;
            return true;
        }
        while end <= anim.frame  anim.frame -= anim.frame_count;
    }
    o.frame = anim.frame >> 16;
    return false;
}

// Seeing ------------------------------------------------------------------------------------

#scope_module

// Whether an object sees the player (0x3353c): within the close range from any side,
// otherwise within its field of view.
is_player_visible :: (o: *Object, fov: s32, close: Fixed) -> bool {
    p := *world.player;
    distance := dist_approx(o.position.x, o.position.z, p.position.x, p.position.z);
    if close < distance {
        angle := vec2_to_angle(p.position.x - o.position.x, p.position.z - o.position.z);
        off := get_angle_difference(angle, o.yaw);
        half := fov >> 1;
        if !(-half < off && off < half) return false;
    }
    return can_see_player_from_distance(o);
}

#scope_file

// The chance of seeing the player by distance and light (0x334ac): crouching doubles the
// distance; in the dark, without the headlamp, up to 248 units more; then it must come
// under a random 200 to 256. The headlamp takes off twice the player's light level, which
// the original takes from a 16.16 distance, so it's next to nothing.
can_see_player_from_distance :: (o: *Object) -> bool {
    p := *world.player;
    distance := dist_approx(o.position.x, o.position.z, p.position.x, p.position.z);
    if p.height < 3 * FIXED_ONE  distance *= 2;
    if !world.player_state.headlamp {
        ambient := world.level.sectors[p.sector].ambient;
        if ambient > 22 * FIXED_ONE  ambient = 31 * FIXED_ONE;
        distance += 248 * FIXED_ONE - ambient * 8;
    } else {
        distance -= get_player_light_level() * 2;
    }
    if distance >= 256 * FIXED_ONE return false;
    if distance >= fixed_random(256 * FIXED_ONE) + 200 * FIXED_ONE return false;
    return can_see_player(o);
}

#scope_module

// A line from the object's top to the player's feet, or to its head when the first was
// stopped by something other than a wall with nothing behind it (0x5ab68).
can_see_player :: (o: *Object) -> bool {
    p := *world.player;
    from := Fixed3.{o.position.x, o.position.y - o.height, o.position.z};
    if can_line_reach(o.sector, p.sector, from, p.position) return true;
    if sight_hit_wall return false;
    head := Fixed3.{p.position.x, p.position.y - p.height, p.position.z};
    return can_line_reach(o.sector, p.sector, from, head);
}

#scope_file

// Physics and movement ----------------------------------------------------------------------

// The actor's velocity this frame (0x29054): its push, gravity for those that fall, a stop
// on the floor or ceiling, friction, and death from a fall fast enough, met on landing. The
// free movement's modules (0x267a0) come through here too.
apply_actor_physics :: (object: s32, m: *Move_Module, velocity: *Fixed3) {
    o := world.objects[object];
    dt := world.clock.dt;
    v := velocity.*;
    m.delta = .{mul16(v.x, dt), mul16(v.y, dt), mul16(v.z, dt)};
    friction := FIXED_ONE - dt * 2;
    if m.collision_flags & MOVE_GRAVITY {
        floor, ceiling := get_floor_and_ceiling(*world.level.sectors[o.sector], o.position.y);
        if o.position.y < floor  v.y += mul16(150 * FIXED_ONE, dt);
        hit_ceiling: bool;
        if v.y < 0 && o.position.y <= ceiling + m.physics.height {
            hit_ceiling = true;
        } else if v.y < 0 || o.position.y < floor {
            // In the air.
            friction = FIXED_ONE - dt / 2;
            v.x = mul16(v.x, friction);
            v.z = mul16(v.z, friction);
            velocity.* = stop_slow(v);
            return;
        }
        // The fall's message goes to the moving object's own logics (0x2646c, 0x8adf8): an
        // actor's damage module, or the task of a special logic, which takes no notice.
        if v.y > 160 * FIXED_ONE {
            actor := o.actor;
            send_object_message(object, .TERMINAL_VELOCITY);
            if actor && !world.actor_state.current return;
            if !world.objects[object].used return;
        }
        if hit_ceiling { if v.y < 0  v.y = 0; }
        else           { if v.y >= 0  v.y = 0; }
    } else {
        v.y = mul16(v.y, friction);
    }
    v.x = mul16(v.x, friction);
    v.z = mul16(v.z, friction);
    velocity.* = stop_slow(v);
}

stop_slow :: (v: Fixed3) -> Fixed3 {
    r := v;
    if abs(r.x) < 0x1999  r.x = 0;
    if abs(r.y) < 0x1999  r.y = 0;
    if abs(r.z) < 0x1999  r.z = 0;
    return r;
}

// The movement module's run (0x28a60): turn, then move.
move_update :: (actor: *World_Actor, m: *Move_Module) {
    m.physics.wall = null;
    if m.target.flags & TARGET_MOVE_ROT  turn_object(actor.object, m);
    if (m.target.flags & (TARGET_MOVE_XZ | TARGET_MOVE_Y)) || m.delta.x || m.delta.y || m.delta.z {
        move_and_collide(actor.object, m);
    }
    m.target.flags &= ~TARGET_ALL_MOVE;
}

// A module's target given to the movement (0x28ad4).
update_move_target :: (m: *Move_Module, target: *Actor_Target) {
    if target.flags & TARGET_FREEZE {
        m.target.flags |= TARGET_FREEZE;
        return;
    }
    m.target.flags &= ~TARGET_FREEZE;
    if target.flags & TARGET_MOVE_XZ {
        m.target.position.x = target.position.x;
        m.target.position.z = target.position.z;
        m.target.speed = target.speed;
        m.target.flags |= TARGET_MOVE_XZ;
    }
    if target.flags & TARGET_MOVE_Y {
        m.target.position.y = target.position.y;
        m.target.speed_vertical = target.speed_vertical;
        m.target.flags |= TARGET_MOVE_Y;
    }
    if target.flags & TARGET_MOVE_ROT {
        m.target.pitch = target.pitch;
        m.target.yaw = target.yaw;
        m.target.roll = target.roll;
        m.target.speed_rotation = target.speed_rotation;
        m.target.flags |= TARGET_MOVE_ROT;
    }
}

// Turning toward the target's angles (0x28bd8), at once or by the turning speed.
turn_object :: (object: s32, m: *Move_Module) {
    if m.target.flags & TARGET_FREEZE return;
    o := world.objects[object];
    speed := m.target.speed_rotation & 0xFFFF;
    if speed == 0 {
        o.pitch, o.yaw, o.roll = m.target.pitch, m.target.yaw, m.target.roll;
        return;
    }
    pitch_off := get_angle_difference(o.pitch, m.target.pitch);
    yaw_off   := get_angle_difference(o.yaw, m.target.yaw);
    roll_off  := get_angle_difference(o.roll, m.target.roll);
    if !(pitch_off | yaw_off | roll_off) return;
    step := mul16(speed << 16, world.clock.dt) >> 16;
    o.yaw = (o.yaw + limit_turn(yaw_off, step)) & ANGLE_MASK;
    if o.class == .MODEL {
        o.pitch = (o.pitch + limit_turn(pitch_off, step)) & ANGLE_MASK;
        o.roll  = (o.roll + limit_turn(roll_off, step)) & ANGLE_MASK;
    }
}

limit_turn :: (off: s32, step: s32) -> s32 {
    if !off return 0;
    if off > step return step;
    if -step <= off return off;
    return -step;
}

// Moving toward the target by its speed, then by the push (0x28d2c). A smart object that
// hits a wall tells the sector behind it, to open a door; one that slides goes on along
// what it hit.
move_and_collide :: (object: s32, m: *Move_Module) {
    o := world.objects[object];
    dt := world.clock.dt;
    m.collision_wall = null;
    move: Fixed3;
    if !(m.target.flags & TARGET_FREEZE) {
        want: Fixed3;
        if m.target.flags & TARGET_MOVE_XZ {
            want.x = m.target.position.x - o.position.x;
            want.z = m.target.position.z - o.position.z;
        }
        if !(m.collision_flags & MOVE_NO_Y) && (m.target.flags & TARGET_MOVE_Y) {
            want.y = m.target.position.y - o.position.y;
        }
        if want.x || want.z {
            step := mul16(m.target.speed, dt);
            dir_x, dir_z := get_direction_and_length(want.x, want.z);
            if want.x && dir_x  move.x = clamp(mul16(step, dir_x), -abs(want.x), abs(want.x));
            if want.z && dir_z  move.z = clamp(mul16(step, dir_z), -abs(want.z), abs(want.z));
        }
        if want.y {
            step := mul16(m.target.speed_vertical, dt);
            if want.y < 0  step = -step;
            move.y = clamp(step, -abs(want.y), abs(want.y));
        }
    }
    move.y += m.delta.y;
    if move.x || move.y || move.z {
        m.physics.offset = move;
        move_object(object, *m.physics);
        if m.physics.responds {
            wall := m.physics.wall;
            if wall && (o.entity & ENTITY_SMART) {
                sector := ifx wall.adjoin >= 0 then wall.adjoin else m.physics.wall_sector;
                send_object_trigger(sector, o.entity);
            }
            if m.collision_flags & MOVE_SLIDE {
                m.collision_wall = wall;
                m.collision_wall_sector = m.physics.wall_sector;
                slide_offset(m.physics.response_dir, *m.physics.offset);
                move_object(object, *m.physics);
            }
        }
    }
    if m.delta.x || m.delta.z {
        m.physics.offset = .{m.delta.x, 0, m.delta.z};
        m.physics.infinite_drop = true;
        move_object(object, *m.physics);
        if (m.collision_flags & MOVE_SLIDE) && m.physics.responds {
            m.collision_wall = m.physics.wall;
            m.collision_wall_sector = m.physics.wall_sector;
            slide_offset(m.physics.response_dir, *m.physics.offset);
            move_object(object, *m.physics);
        }
    }
}

// Whether it stands on the floor and isn't being pushed fast (0x264c0). In water it counts as
// there.
is_on_floor :: (actor: *World_Actor) -> bool {
    o := world.objects[actor.object];
    sector := *world.level.sectors[o.sector];
    if sector.second_altitude > 0 && o.position.y > sector.floor.altitude return true;
    if abs(actor.velocity.x) >= 5 * FIXED_ONE && abs(actor.velocity.z) >= 5 * FIXED_ONE return false;
    floor, _ := get_floor_and_ceiling(sector, o.position.y);
    return o.position.y >= floor;
}

// Modules -----------------------------------------------------------------------------------

create_move_module :: (actor: *World_Actor) -> *Move_Module {
    o := world.objects[actor.object];
    m := New(Move_Module);
    m.physics.step_up = 0x38000;
    m.physics.step_down = 4 * FIXED_ONE;
    m.physics.height = o.height;
    m.physics.width = 0x18000;
    m.target.speed = FIXED_ONE;
    m.target.speed_vertical = FIXED_ONE;
    m.target.speed_rotation = 45;
    m.collision_flags = MOVE_NO_Y | MOVE_GRAVITY;
    o.entity |= ENTITY_SMART;
    return m;
}

create_attack_module :: (actor: *World_Actor) -> *Attack_Module {
    m := New(Attack_Module);
    init_attack_module(actor, m);
    m.update = attack_update;
    return m;
}

// The attack module's defaults (0x26fe4).
init_attack_module :: (actor: *World_Actor, m: *Attack_Module) {
    o := world.objects[actor.object];
    m.anim.flags |= ANIM_ONCE | ANIM_READY;
    m.lost_sight_tick = cast(u32) world.clock.tick + 0x4446;
    m.fire_offset.y = -(o.height / 2 + FIXED_ONE);
}

create_damage_module :: (actor: *World_Actor) -> *Damage_Module {
    m := New(Damage_Module);
    init_attack_module(actor, cast(*Attack_Module) m);
    m.update = damage_update;
    m.next_tick = NEVER;
    return m;
}

create_thinker_module :: (actor: *World_Actor) -> *Thinker_Module {
    m := New(Thinker_Module);
    m.target.speed = 4 * FIXED_ONE;
    m.target.speed_vertical = 10 * FIXED_ONE;
    m.anim.state = THINKER_TURN;
    m.update = thinker_update;
    return m;
}

create_flying_module :: (actor: *World_Actor) -> *Flying_Module {
    m := New(Flying_Module);
    m.target.speed = 4 * FIXED_ONE;
    m.target.speed_vertical = 10 * FIXED_ONE;
    m.anim.state = FLYING_CHOOSE;
    m.anim.flags &= ~ANIM_ONCE;
    m.update = flying_update;
    return m;
}

// Flying, not falling: no ground to keep to, sliding along what it meets, down any drop
// (0x32450).
set_up_flying_move :: (m: *Move_Module, o: *Object) {
    m.collision_flags = MOVE_SLIDE;
    m.physics.step_down = 200 * FIXED_ONE;
    m.physics.width = o.width;
}

// The flying module (0x26f08): after a wait, when it's in the player's sector, rises or
// sinks to about the player's eye, varied by up to 3.5 units, until it gets there or is
// stopped. It runs on messages too, the original not telling them apart here.
flying_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    f := cast(*Flying_Module) module;
    o := world.objects[actor.object];
    tick := cast(u32) world.clock.tick;
    if f.anim.state == FLYING_WAIT {
        wait := fixed_random(f.delay);
        f.anim.state = FLYING_CHOOSE;
        return cast,no_check(u32) wait + tick;
    }
    if f.anim.state == FLYING_MOVE {
        if is_blocked(o, actor.move, *f.target)  f.anim.state = FLYING_WAIT;
        if has_arrived(*f.target, o)  f.anim.state = FLYING_WAIT;
    } else if f.anim.state == FLYING_CHOOSE {
        if o.sector == world.player.sector {
            f.target.position.y = get_player_eye().y - (fixed_random(5 * FIXED_ONE) - 0x18000);
            f.anim.state = FLYING_MOVE;
            f.target.flags |= TARGET_MOVE_Y;
        } else {
            f.anim.state = FLYING_WAIT;
        }
    }
    update_move_target(actor.move, *f.target);
    return 0;
}

// The remote's own module (0x26de4): after a wait, turns to a heading at random.
remote_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    f := cast(*Flying_Module) module;
    o := world.objects[actor.object];
    tick := cast(u32) world.clock.tick;
    if f.anim.state == FLYING_WAIT {
        wait := fixed_random(f.delay);
        f.anim.state = FLYING_CHOOSE;
        return cast,no_check(u32) wait + tick;
    }
    if f.anim.state == FLYING_MOVE {
        if has_arrived(*f.target, o)  f.anim.state = FLYING_WAIT;
    } else if f.anim.state == FLYING_CHOOSE {
        f.target.yaw = cast(s32) (fixed_random_next() & cast(u32) ANGLE_MASK);
        f.target.pitch = o.pitch;
        f.target.roll = o.roll;
        f.anim.state = FLYING_MOVE;
        f.target.flags |= TARGET_MOVE_ROT;
    }
    update_move_target(actor.move, *f.target);
    return 0;
}

// The thinker (0x26aa0): walks toward the player, or where it last saw it, a little to one
// side, choosing again on arriving, after walking long enough, or on hitting something.
thinker_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    if message != .RUN return NEVER;
    t := cast(*Thinker_Module) module;
    o := world.objects[actor.object];
    m := actor.move;
    tick := cast(u32) world.clock.tick;
    if t.anim.state == THINKER_MOVE {
        arrived := has_arrived(*t.target, o);
        if t.walk_until < tick || arrived {
            if arrived  t.last_seen_until = NEVER;
            t.anim.state = THINKER_TURN;
        } else {
            if !(actor.flags & ACTOR_SEES_PLAYER) {
                t.last_seen_until = tick + 0x1111;
            } else if t.last_seen_until != NEVER {
                t.walk_until = 0;
                t.max_walk = t.start_delay;
                t.last_seen_until = NEVER;
            }
            if is_blocked(o, m, *t.target) {
                turn_from_collision(o, m, *t.target, *t.collided_tick);
                if !(actor.flags & ACTOR_SEES_PLAYER) {
                    t.max_walk += 218;
                    if t.max_walk > 0x5B0  t.max_walk = 291;
                    t.walk_until = tick + t.max_walk;
                }
            }
        }
    } else if t.anim.state == THINKER_TURN {
        eye := get_player_eye();
        target_x, target_z := eye.x, eye.z;
        if t.last_seen_until < tick  target_x, target_z = actor.last_seen.x, actor.last_seen.z;
        offset: Fixed;
        if !(actor.flags & ACTOR_SEES_PLAYER) {
            // min(|dx|, |dx|): the original compares dx with itself.
            dx := abs(world.player.position.x - o.position.x);
            offset = dx / 4;
        } else {
            offset = t.target_offset;
        }
        angle := vec2_to_angle(o.position.x - target_x, o.position.z - target_z);
        t.target.position.z = target_z;
        t.target.position.x = target_x;
        offset_target(*t.target.position.x, *t.target.position.z, offset, t.target_variation, angle, t.approach_variation);
        t.target.flags = (t.target.flags & ~TARGET_MOVE_Y) | TARGET_MOVE_XZ;
        t.target.yaw = vec2_to_angle(t.target.position.x - o.position.x, t.target.position.z - o.position.z);
        t.target.pitch = 0;
        t.target.roll = 0;
        t.target.flags |= TARGET_MOVE_ROT;
        if !(actor.flags & ACTOR_MOVING) {
            if o.class == .SPRITE  set_up_animation(actor, .MOVE, *t.anim);
            actor.flags |= ACTOR_MOVING;
        }
        t.anim.state = THINKER_MOVE;
        t.walk_until = tick + t.max_walk;
        if (o.entity & ENTITY_REMOTE) && !(actor.flags & ACTOR_IDLE) && (actor.flags & ACTOR_MOVING) {
            play_sound_at(world.actor_sounds.remote_hum, o.position);
        }
    }
    if o.class == .SPRITE  set_current_animation(*t.anim);
    update_move_target(m, *t.target);
    return 0;
}

#scope_module

// Whether the object is where its target says, in what the target moves (0x2610c).
has_arrived :: (target: *Actor_Target, o: *Object) -> bool {
    if (target.flags & TARGET_MOVE_XZ) && (target.position.x != o.position.x || target.position.z != o.position.z) return false;
    if (target.flags & TARGET_MOVE_Y) && target.position.y != o.position.y return false;
    if (target.flags & TARGET_MOVE_ROT) {
        if cast,no_check(s16) target.yaw != cast,no_check(s16) o.yaw return false;
        if cast,no_check(s16) target.pitch != cast,no_check(s16) o.pitch return false;
        if cast,no_check(s16) target.roll != cast,no_check(s16) o.roll return false;
    }
    return true;
}

// Moves a point off along an angle, both varied at random (0x2617c).
offset_target :: (x: *Fixed, z: *Fixed, offset: Fixed, variation: Fixed, angle: s32, angle_variation: s32) -> s32 {
    turn: s32;
    if angle_variation {
        turn = cast,no_check(s16) ((fixed_random(angle_variation << 17) - (angle_variation << 16)) >> 16);
    }
    distance := offset;
    if variation  distance = fixed_random(variation * 2) + offset - variation;
    s, c := sin_cos(angle + turn);
    x.* += mul16(distance, s);
    z.* += mul16(distance, c);
    return angle + turn;
}

// Whether the last move was stopped (0x29280). One that can fly takes the height of the
// opening it hit, or rises over the object, if it fits, and isn't counted as stopped.
is_blocked :: (o: *Object, m: *Move_Module, target: *Actor_Target) -> bool {
    if !m.physics.responds && !m.collision_wall return false;
    if m.collision_flags & MOVE_NO_Y return true;
    wall, wall_sector := m.physics.wall, m.physics.wall_sector;
    if !wall  wall, wall_sector = m.collision_wall, m.collision_wall_sector;
    if !wall {
        if m.physics.hit_object < 0 return true;
        top: Fixed;
        if m.physics.hit_object == OBJECT_IS_PLAYER  top = world.player.position.y - world.player.height;
        else { h := world.objects[m.physics.hit_object]; top = h.position.y - h.height; }
        gap := top - world.level.sectors[o.sector].ceiling.altitude;
        if o.height + FIXED_ONE < gap {
            target.position.y = top - gap / 2 + o.height / 2;
            target.flags |= TARGET_MOVE_Y;
            return false;
        }
        return true;
    }
    if wall.adjoin < 0 return true;
    here := *world.level.sectors[wall_sector];
    next := *world.level.sectors[wall.adjoin];
    floor := min(here.floor.altitude, next.floor.altitude);
    ceiling := max(here.ceiling.altitude, next.ceiling.altitude);
    if o.height + FIXED_ONE < floor - ceiling {
        target.position.y = floor - (floor - ceiling) / 2 + o.height / 2;
        target.flags |= TARGET_MOVE_Y;
        return false;
    }
    return true;
}

// A new way after hitting something (0x29398): at random if it hit something less than a
// second ago, otherwise along what it hit, whichever way is nearer its facing.
turn_from_collision :: (o: *Object, m: *Move_Module, target: *Actor_Target, collided_tick: *u32) {
    tick := cast(u32) world.clock.tick;
    angle: s32;
    if tick - collided_tick.* < 0x91 {
        angle = cast(s32) (fixed_random_next() & cast(u32) ANGLE_MASK);
    } else {
        response := m.physics.response_angle;
        off := get_angle_difference(o.yaw, cast,no_check(s16) (response + (world.clock.tick & 0xFF) - 0x80));
        if (off & 0x1FFF) < 0x1000  angle = response;
        else                        angle = cast,no_check(s16) (response + 0xE001);
    }
    s, c := sin_cos(angle);
    target.position.x = o.position.x + s * 0x80;
    target.position.z = o.position.z + c * 0x80;
    target.pitch = 0;
    target.flags = (target.flags | TARGET_MOVE_XZ | TARGET_MOVE_ROT) & ~TARGET_MOVE_Y;
    target.roll = 0;
    target.yaw = angle & ANGLE_MASK;
    collided_tick.* = tick;
}

#scope_file

// The attack (0x27144): waits, decides by sight and distance, faces the player and fires
// or strikes, then plays the attack's end.
attack_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    a := cast(*Attack_Module) module;
    o := world.objects[actor.object];
    tick := cast(u32) world.clock.tick;
    if message != .RUN {
        if message == .WAKEUP  a.lost_sight_tick = tick + a.lost_sight_delay;
        if !(actor.flags & ACTOR_IDLE) return NEVER;
        return a.delay;
    }
    p := *world.player;
    eye := get_player_eye();
    if a.anim.state == {
        case ATTACK_DELAY;
            if !(a.anim.flags & ANIM_READY) {
                if o.class == .SPRITE  set_current_animation(*a.anim);
                update_move_target(actor.move, *a.target);
                return a.delay;
            }
            o.lit = false;
            wait := fixed_random(cast,no_check(Fixed) a.delay);
            a.anim.state = ATTACK_DECIDE;
            if a.accuracy_tick < tick {
                if !a.fire_spread {
                    a.accuracy_tick = NEVER;
                } else {
                    a.fire_spread -= mul16(world.clock.dt, 2 * FIXED_ONE);
                    if a.fire_spread < 9 * FIXED_ONE  a.fire_spread = 9 * FIXED_ONE;
                    a.accuracy_tick = tick + 0x91;
                }
            }
            a.target.flags &= ~TARGET_ALL_MOVE;
            return tick + cast,no_check(u32) wait;

        case ATTACK_DECIDE;
            sustain_fight();
            s := *world.player_state;
            if s.dying && s.revive_tick <= world.clock.tick {
                a.anim.state = ATTACK_DELAY;
                a.anim.flags |= ANIM_READY;
                return a.delay;
            }
            if !can_see_player_from_distance(o) {
                set_player_seen(actor, false, 0, 0);
                a.anim.state = ATTACK_DELAY;
                a.anim.flags |= ANIM_READY;
                if a.lost_sight_tick < tick {
                    a.delay = a.search_delay;
                    set_up_idle_animation(actor);
                }
                return a.delay;
            }
            set_player_seen(actor, true, eye.x, eye.z);
            a.lost_sight_tick = tick + a.lost_sight_delay;
            distance := dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
            up := abs(o.position.y - o.height - eye.y);
            if vec2_to_angle(up, distance) > 0x8E2 {
                a.anim.state = ATTACK_DELAY;
                a.anim.flags |= ANIM_READY;
                return a.delay;
            }
            distance += abs(p.position.y - o.position.y);
            if a.max_distance < distance {
                a.anim.state = ATTACK_DELAY;
                a.anim.flags |= ANIM_READY;
                return a.delay;
            }
            if !(a.attack_flags & ATTACK_MELEE) {
                if distance < a.min_distance {
                    a.anim.state = ATTACK_DELAY;
                    a.anim.flags |= ANIM_READY;
                    return a.delay;
                }
                a.anim.state = ATTACK_FIRST;
                a.delay = a.ranged_delay;
            } else if a.melee_range < distance {
                if !(a.attack_flags & ATTACK_RANGED) || distance < a.min_distance {
                    a.anim.state = ATTACK_DELAY;
                    a.anim.flags |= ANIM_READY;
                    return a.delay;
                }
                a.anim.state = ATTACK_SECOND;
                a.delay = a.ranged_delay;
            } else {
                a.anim.state = ATTACK_FIRST;
                a.delay = a.melee_delay;
            }
            if o.class == .SPRITE {
                set_up_animation(actor, ifx a.anim.state == ATTACK_FIRST then .ATTACK1 else .ATTACK2, *a.anim);
            }
            a.target.position.x = o.position.x;
            a.target.position.z = o.position.z;
            a.target.flags |= TARGET_MOVE_XZ;
            a.target.yaw = vec2_to_angle(eye.x - o.position.x, eye.z - o.position.z);
            a.target.pitch = o.pitch;
            a.target.roll = o.roll;
            a.target.flags |= TARGET_MOVE_ROT;

        case ATTACK_FIRST;
            if a.anim.flags & ANIM_READY {
                a.anim.state = ATTACK_FIRST_END;
                if a.attack_flags & ATTACK_MELEE {
                    distance := abs(o.position.y - p.position.y) + dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
                    if distance < a.melee_range {
                        play_sound_at(a.melee_sound, o.position);
                        apply_damage(a.melee_damage, 0, true);
                        if a.attack_flags & ATTACK_LIT_MELEE  o.lit = true;
                    }
                } else {
                    fire_at_player(actor, a);
                }
            }

        case ATTACK_FIRST_END;
            if o.class == .SPRITE  set_up_animation(actor, .ATTACK1_END, *a.anim);
            a.anim.state = ATTACK_DELAY;

        case ATTACK_SECOND;
            if a.anim.flags & ANIM_READY {
                a.anim.state = ATTACK_SECOND_END;
                fire_at_player(actor, a, second = true);
            }

        case ATTACK_SECOND_END;
            if o.class == .SPRITE  set_up_animation(actor, .ATTACK2_END, *a.anim);
            a.anim.state = ATTACK_DELAY;
    }
    if o.class == .SPRITE  set_current_animation(*a.anim);
    update_move_target(actor.move, *a.target);
    return a.delay;
}

// A shot at the player's eye, a unit low, scattered by the spread (0x27144). A thermal
// detonator from the second attack is lobbed instead, unscattered, to land at the player's
// feet under the eye, with no fuse and no bounces: it goes off where it lands.
fire_at_player :: (actor: *World_Actor, a: *Attack_Module, second := false) {
    o := world.objects[actor.object];
    if a.attack_flags & ATTACK_LIT_RANGED  o.lit = true;
    proj := create_projectile(a.projectile, o.sector, .{o.position.x, a.fire_offset.y + o.position.y, o.position.z}, actor.object);
    play_sound_at(a.fire_sound, o.position);
    if !proj return;
    proj.last_hit = actor.object;
    proj.exclude = actor.object;
    world.objects[proj.object].yaw = o.yaw;
    eye := get_player_eye();
    if second && a.projectile == .THERMAL_DETONATOR {
        proj.bounces = 0;
        proj.duration = NEVER;
        p := *world.player;
        aim_projectile_arcing(proj, .{p.position.x, eye.y + FIXED_ONE, p.position.z});
        if a.fire_offset.x || a.fire_offset.z {
            proj.delta.x = a.fire_offset.x;
            proj.delta.z = a.fire_offset.z;
            move_projectile(proj);
        }
        return;
    }
    if a.fire_offset.x || a.fire_offset.z {
        proj.delta.x = a.fire_offset.x;
        proj.delta.z = a.fire_offset.z;
        move_projectile(proj);
    }
    aim_projectile(proj, .{eye.x, eye.y + FIXED_ONE, eye.z});
    if a.fire_spread {
        spread := a.fire_spread;
        proj.velocity.x += fixed_random(spread * 2) - spread;
        proj.velocity.y += fixed_random(spread * 2) - spread;
        proj.velocity.z += fixed_random(spread * 2) - spread;
    }
}

set_player_seen :: (actor: *World_Actor, seen: bool, x: Fixed, z: Fixed) {
    actor.flags &= ~ACTOR_SEES_PLAYER;
    if seen {
        actor.flags |= ACTOR_SEES_PLAYER;
        actor.last_seen = .{x, z};
    }
}

// The damage module (0x27b60): hit points taken by shots, explosions, crushing and falls;
// hurting, or dying with a push; once dead and on the floor, its effect, its item and its
// corpse, and it's gone.
damage_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    d := cast(*Damage_Module) module;
    o := world.objects[actor.object];
    if message == {
        case .RUN;
            if d.anim.flags & ANIM_READY {
                if d.hp > 0 return NEVER;
                if is_on_floor(actor) {
                    die(actor, d);
                    return 0;
                }
            }

        case .CRUSH; #through;
        case .TERMINAL_VELOCITY;
            if d.hp > 0 {
                d.hp = 0;
                if d.stop_on_hit  d.target.flags |= TARGET_FREEZE;
                start_dying(actor, d, .DIE2);
            }

        case .DAMAGE;
            if d.hp > 0 {
                proj := world.actor_state.message_projectile;
                damage := proj.damage;
                shooter := proj.shooter;
                if shooter >= 0 && (world.objects[shooter].entity & ENTITY_AI_ACTOR) == (o.entity & ENTITY_AI_ACTOR)  damage = proj.damage / 2;
                d.hp -= damage;
                if d.stop_on_hit  d.target.flags |= TARGET_FREEZE;
                push := get_projectile_push(proj);
                if d.hp < 1 {
                    add_velocity(actor, .{push.x * 4, push.y * 2, push.z * 4});
                    start_dying(actor, d, ifx proj.type == .PUNCH then Actor_Anim_Kind.DIE1 else .DIE2);
                } else {
                    add_velocity(actor, .{push.x * 2, push.y, push.z * 2});
                    stop_sound(d.hurt_playing);
                    d.hurt_playing = play_sound_at(d.hurt_sound, o.position);
                    if o.class == .SPRITE  set_up_animation(actor, .PAIN, *d.anim);
                }
            }

        case .EXPLOSION;
            if d.hp > 0 {
                e := *world.actor_state;
                d.hp -= e.message_damage;
                if d.stop_on_hit  d.target.flags |= TARGET_FREEZE;
                dir := get_explosion_push(.{o.position.x, o.position.y - o.height, o.position.z});
                push := Fixed3.{mul16(e.message_force, dir.x), mul16(e.message_force, dir.y), mul16(e.message_force, dir.z)};
                if d.hp < 1 {
                    add_velocity(actor, push);
                    start_dying(actor, d, .DIE2);
                } else {
                    add_velocity(actor, .{push.x / 2, push.y / 2, push.z / 2});
                    stop_sound(d.hurt_playing);
                    d.hurt_playing = play_sound_at(d.hurt_sound, o.position);
                    if o.class == .SPRITE  set_up_animation(actor, .PAIN, *d.anim);
                }
            }

        case;
            return d.next_tick;
    }
    if o.class == .SPRITE  set_current_animation(*d.anim);
    update_move_target(actor.move, *d.target);
    return 0;
}

// A barrel, or a placed mine's actor (0x32450): awake from the start but never looking for
// the player, only its damage (0x28464), and held still.
create_barrel_actor :: (object: s32, hp: Fixed) {
    o := world.objects[object];
    actor := create_actor(object);
    actor.flags &= ~ACTOR_NPC;
    damage := create_damage_module(actor);
    damage.update = barrel_damage_update;
    damage.hp = hp;
    damage.anim.flags |= ANIM_READY;
    add_module(actor, cast(*Actor_Module) damage);
    actor.move = create_move_module(actor);
    actor.move.collision_flags |= MOVE_NO_Y;
    actor.move.physics.width = o.width;
    damage.target.speed = 0;
    damage.target.speed_rotation = 0;
    damage.target.flags = TARGET_FREEZE;
    actor.move.target.speed = 0;
    actor.move.target.speed_rotation = 0;
    actor.move.target.flags = TARGET_FREEZE;
    actor.anims = *barrel_anims;
}

// The barrel's damage (0x28464): blown up by shots or a blast that take its hit points, as
// an unseen barrel projectile's explosion. A blast pushes it, and when it blows up sends a
// second, silent blast after it, a quarter of its push along, half a second later. Gone once
// its blowing up has shown.
barrel_damage_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    d := cast(*Damage_Module) module;
    o := world.objects[actor.object];
    if message == {
        case .RUN;
            if d.anim.flags & ANIM_READY {
                if d.hp > 0 return NEVER;
                kill_current_actor();
                return 0;
            }

        case .DAMAGE;
            if (d.anim.flags & ANIM_READY) && d.hp > 0 {
                d.hp -= world.actor_state.message_projectile.damage;
                if d.hp > 0 return NEVER;
                blow_up_barrel(actor, o);
                o.lit = true;
                set_up_animation(actor, .DIE1, *d.anim);
            }

        case .EXPLOSION;
            if (d.anim.flags & ANIM_READY) && d.hp > 0 {
                e := *world.actor_state;
                d.hp -= e.message_damage;
                dir := get_explosion_push(.{o.position.x, o.position.y - o.height, o.position.z});
                push_x, push_z := mul16(e.message_force, dir.x), mul16(e.message_force, dir.z);
                if d.hp > 0 {
                    add_velocity(actor, .{push_x >> 1, 0, push_z >> 1});
                    return NEVER;
                }
                o.lit = true;
                blow_up_barrel(actor, o);
                add_velocity(actor, .{push_x, 0, push_z});
                second := blow_up_barrel(actor, o);
                second.hit_effect = HIT_EFFECT_SILENT;
                second.duration = cast(u32) world.clock.tick + 0x24;
                m: Object_Move;
                m.offset = .{mul16(actor.velocity.x, 0x4000), 0, mul16(actor.velocity.z, 0x4000)};
                m.step_up = FIXED_ONE;
                m.step_down = FIXED_INFINITY;
                m.height = FIXED_ONE;
                m.width = world.objects[second.object].width;
                move_object(second.object, *m);
                set_up_animation(actor, .DIE1, *d.anim);
            }

        case;
            return NEVER;
    }
    set_current_animation(*d.anim);
    update_move_target(actor.move, *d.target);
    return 0;
}

blow_up_barrel :: (actor: *World_Actor, o: *Object) -> *Projectile {
    proj := create_projectile(.BARREL, o.sector, o.position, actor.object);
    proj.velocity = .{};
    return proj;
}

// Scenery's damage (0x28714): broken by a shot or a blast that takes its hit point, it shows
// its broken action, which then stays as an object of its own.
scenery_damage_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    d := cast(*Damage_Module) module;
    o := world.objects[actor.object];
    if message == {
        case .RUN;
            if d.anim.flags & ANIM_READY {
                if d.hp > 0 return NEVER;
                dead := get_anim_index(actor, .DEAD);
                if dead != -1 {
                    left := add_object(.SPRITE, o.data, o.position, -1);
                    l := world.objects[left];
                    l.frame = 0;
                    l.anim = dead;
                    l.width = o.width;
                    change_object_sector(left, o.sector);
                }
                kill_current_actor();
                return 0;
            }

        case .DAMAGE;
            if !(d.anim.flags & ANIM_READY) || d.hp <= 0 return NEVER;
            d.hp -= world.actor_state.message_projectile.damage;
            if d.hp > 0 return NEVER;
            set_up_animation(actor, .DEAD, *d.anim);

        case .EXPLOSION;
            if !(d.anim.flags & ANIM_READY) return NEVER;
            if d.hp > 0  d.hp -= world.actor_state.message_damage;
            if d.hp > 0 return NEVER;
            set_up_animation(actor, .DEAD, *d.anim);

        case;
            return NEVER;
    }
    set_current_animation(*d.anim);
    return 0;
}

// The sewer creature's damage (0x28154): no push, and once dead it's on the water's surface,
// floating; dying from a strike (its attack's actions showing) or otherwise. The corpse
// floats there.
sewer_damage_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    d := cast(*Damage_Module) module;
    o := world.objects[actor.object];
    sector := *world.level.sectors[o.sector];
    if message == {
        case .RUN;
            if d.anim.flags & ANIM_READY {
                if d.hp > 0 return NEVER;
                dead := get_anim_index(actor, .DEAD);
                if dead != -1 {
                    corpse := add_object(.SPRITE, o.data, .{o.position.x, sector.floor.altitude, o.position.z}, -1);
                    c := world.objects[corpse];
                    c.frame = 0;
                    c.anim = dead;
                    c.entity |= ENTITY_CORPSE;
                    change_object_sector(corpse, o.sector);
                }
                kill_current_actor();
                return 0;
            }

        case .DAMAGE; #through;
        case .EXPLOSION;
            if d.hp >= 1 {
                if message == .DAMAGE  d.hp -= world.actor_state.message_projectile.damage;
                else                   d.hp -= world.actor_state.message_damage;
                if d.hp > 0 {
                    stop_sound(d.hurt_playing);
                    d.hurt_playing = play_sound_at(d.hurt_sound, o.position);
                    return NEVER;
                }
                striking := o.anim == 1 || o.anim == 6;
                start_dying(actor, d, ifx striking then Actor_Anim_Kind.DIE1 else .DIE2);
                o.position.y = sector.floor.altitude;
                actor.move.collision_flags &= ~MOVE_GRAVITY;
            }

        case;
            return d.next_tick;
    }
    set_current_animation(*d.anim);
    update_move_target(actor.move, *d.target);
    return 0;
}

// The sewer creature's attack (0x277ec): below the water, unseen and with no width, it waits;
// seeing the player it surfaces, and strikes if near enough, or looks about; then it goes
// under again.
sewer_attack_update :: (actor: *World_Actor, module: *Actor_Module, message: Actor_Message) -> u32 {
    a := cast(*Attack_Module) module;
    o := world.objects[actor.object];
    sector := *world.level.sectors[o.sector];
    tick := cast(u32) world.clock.tick;
    if message != .RUN {
        if message == .WAKEUP  a.lost_sight_tick = tick + a.lost_sight_delay;
        if !(actor.flags & ACTOR_IDLE) return NEVER;
        return a.delay;
    }
    p := *world.player;
    if a.anim.state == {
        case ATTACK_DELAY;
            if a.anim.flags & ANIM_READY {
                o.width = 0;
                o.flags |= OBJECT_HIDDEN;
                actor.move.collision_flags |= MOVE_NO_Y;
                o.position.y = sector.floor.altitude + sector.second_altitude;
                wait := fixed_random(cast,no_check(Fixed) a.delay);
                a.target.flags &= ~(TARGET_ALL_MOVE | TARGET_FREEZE);
                a.anim.state = ATTACK_DECIDE;
                return tick + cast,no_check(u32) wait;
            }

        case ATTACK_DECIDE;
            sustain_fight();
            if !can_see_player_from_distance(o) {
                set_player_seen(actor, false, 0, 0);
                a.anim.flags |= ANIM_READY;
                a.anim.state = ATTACK_DELAY;
                if a.lost_sight_tick < tick {
                    a.delay = a.search_delay;
                    set_up_idle_animation(actor);
                }
                return a.delay;
            }
            eye := get_player_eye();
            set_player_seen(actor, true, eye.x, eye.z);
            actor.move.collision_flags &= ~MOVE_NO_Y;
            o.position.y = sector.floor.altitude;
            distance := abs(o.position.y - p.position.y) + dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
            if a.melee_range < distance {
                a.anim.state = ATTACK_DELAY;
                a.delay = a.search_delay;
            } else {
                a.anim.state = ATTACK_FIRST;
                a.delay = a.melee_delay;
                a.target.position.x = o.position.x;
                a.target.position.z = o.position.z;
                a.target.flags |= TARGET_MOVE_XZ;
                a.target.yaw = vec2_to_angle(eye.x - o.position.x, eye.z - o.position.z);
                a.target.pitch = o.pitch;
                a.target.roll = o.roll;
                a.target.flags |= TARGET_MOVE_ROT;
            }
            a.lost_sight_tick = tick + a.lost_sight_delay;
            a.target.flags |= TARGET_FREEZE;
            o.width = 3 * FIXED_ONE;
            o.flags &= ~OBJECT_HIDDEN;
            set_up_animation(actor, ifx a.anim.state == ATTACK_FIRST then Actor_Anim_Kind.ATTACK1 else .SEARCH, *a.anim);

        case ATTACK_FIRST;
            if a.anim.flags & ANIM_READY {
                a.anim.state = ATTACK_FIRST_END;
                play_sound_at(a.melee_sound, o.position);
                distance := abs(o.position.y - p.position.y) + dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
                if distance <= a.melee_range  apply_damage(a.melee_damage, 0, true);
            }

        case ATTACK_FIRST_END;
            set_up_animation(actor, .ATTACK1_END, *a.anim);
            a.anim.state = ATTACK_DELAY;
    }
    set_current_animation(*a.anim);
    update_move_target(actor.move, *a.target);
    return a.delay;
}

// Falls rather than flies from here on, and stops showing as aimed at (0x26564); its
// alert stops, its death sounds, and it shows its dying.
start_dying :: (actor: *World_Actor, d: *Damage_Module, kind: Actor_Anim_Kind) {
    o := world.objects[actor.object];
    actor.move.collision_flags |= MOVE_GRAVITY;
    stop_sound(actor.alert_playing);
    play_sound_at(d.die_sound, o.position);
    d.target.flags |= TARGET_FREEZE;
    if o.class == .SPRITE  set_up_animation(actor, kind, *d.anim);
}

add_velocity :: (actor: *World_Actor, push: Fixed3) {
    actor.velocity.x += push.x;
    actor.velocity.y += push.y;
    actor.velocity.z += push.z;
}

// Dead and on the floor (0x27b60): the effect, the item dropped where it stood and brought
// to the floor, the corpse, out of water; then the actor and its object go. The corpse
// stands no lower than the sector's second floor, which lifts one killed under a bridge
// onto it, as in the original.
die :: (actor: *World_Actor, d: *Damage_Module) {
    o := world.objects[actor.object];
    sector := o.sector;
    spawn_hit_effect(d.die_effect, sector, o.position, actor.object);
    if world.level.sectors[sector].second_altitude - 1 < 0 {
        if d.drop != -1  drop_item(d.drop, sector, o.position);
        dead := get_anim_index(actor, .DEAD);
        if dead != -1 {
            o = world.objects[actor.object];
            y := min(o.position.y, world.level.sectors[sector].col_second);
            corpse := add_object(.SPRITE, o.data, .{o.position.x, y, o.position.z}, sector);
            c := world.objects[corpse];
            c.anim = dead;
            c.frame = 0;
            c.entity |= ENTITY_CORPSE;
        }
    }
    kill_current_actor();
}

// An item made where something died (0x3194b), moved off a little to settle and dropped to
// the floor; gone if that's water.
drop_item :: (item: s32, sector: s32, at: Fixed3) {
    index := create_item(item, sector, at);
    if index < 0 return;
    m: Object_Move;
    m.offset = .{2 * FIXED_ONE, 0, 2 * FIXED_ONE};
    m.step_up = FIXED_ONE;
    m.step_down = FIXED_INFINITY;
    m.height = FIXED_ONE;
    m.width = world.objects[index].width;
    move_object(index, *m);
    o := world.objects[index];
    floor, _ := get_floor_and_ceiling(*world.level.sectors[o.sector], o.position.y);
    o.position.y = floor;
    if world.level.sectors[o.sector].second_altitude - 1 >= 0  free_object(index);
}
