// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Shots and what they hit, as DARK.EXE moves them (0x48794-0x4ad84), and the effects where
// they land (0x4b110-0x4b890).
//
// A projectile is an object with a velocity. Each frame (0x4ad84) it moves along it through
// the openings it fits, stopping at a wall it can't pass, the floor or the ceiling (0x49d50),
// then looks for an object its path meets in the sectors it went through, nearest sector
// first (0x4a668); an object hit gets the projectile's damage as a message, a wall hit the
// INF's shoot event. Where it stops, its hit effect shows: a sprite played once, with a sound,
// waking enemies near it and, for explosions, hurting what's in range and sending the INF's
// explosion event to the sectors around.
//
// Thrown and fired ones fall under gravity (arcing), placed mines drop to the floor and wait
// for the player, homing missiles turn toward the player a little more each frame.

Projectile_Type :: enum s32 {
    PUNCH :: 0; PISTOL_BOLT :: 1; RIFLE_BOLT :: 2; THERMAL_DETONATOR :: 3; REPEATER :: 4;
    PLASMA :: 5; MORTAR :: 6; LAND_MINE :: 7; LAND_MINE_PROXIMITY :: 8; LAND_MINE_PLACED :: 9;
    CONCUSSION :: 10; CANNON :: 11; MISSILE :: 12; TURRET_BOLT :: 13; REMOTE_BOLT :: 14;
    BARREL :: 15; HOMING_MISSILE :: 16; PROBE :: 17; BOBA_FETT_BALL :: 18;
}

world_get_projectile_count :: () -> int {
    count := 0;
    for world.projectiles  if it  count += 1;
    return count;
}

// A projectile of a type at a place, heading by pitch and yaw, fired by no one: for tests
// and dev options. Its object, or -1.
world_launch_projectile :: (type: Projectile_Type, at: Fixed3, pitch: s32, yaw: s32) -> s32 {
    sector := level_find_sector(*world.level, at);
    if sector < 0 return -1;
    proj := create_projectile(type, sector, at, -1);
    turn_projectile(proj, pitch, yaw);
    return proj.object;
}

#scope_module

Projectile :: struct {
    object: s32;
    type: Projectile_Type;
    damage: Fixed;
    falloff: Fixed;             // Taken off the damage every falloff_delay ticks,
    falloff_tick: u32;
    falloff_delay: u32;
    min_damage: Fixed;          // down to this.
    force: Fixed;               // How much of its speed pushes what it hits.
    delta: Fixed3;              // This frame's move.
    velocity: Fixed3;
    speed: Fixed;
    dir: Fixed3;                // x and z the heading; y the climb over the distance across.
    horizontal_bounce, vertical_bounce: Fixed;
    last_hit: s32 = -1;         // Not hit again: who fired it, until it bounces.
    shooter: s32 = -1;          // Who fired it, for halving damage between enemies.
    exclude: s32 = -1;          // Not hurt by its explosion.
    duration: u32;              // The tick it's out of range (a mine: goes off, or looks again).
    turn_rate: s16;             // A homing missile's, a second.
    bounces: s32;               // In a magnetically sealed sector; -1 bounces always.
    reflect_variation: s32;
    flight_sound: Sound_Handle;
    flight_playing: Sound_Instance;
    pass_sound: Sound_Handle;   // Played when it passes the camera.
    reflect_sound: Sound_Handle;
    update: Projectile_Update;
    reflect_effect: s32 = -1;
    hit_effect: s32 = -1;
    flags: u32;
}

Projectile_Update :: enum u8 { NONE; STRAIGHT; ARCING; LAND_MINE; HOMING; }

PROJECTILE_PASS_SOUND :u32: 0x1;   // Its pass sound hasn't played since it last turned.
PROJECTILE_EXPLODES   :u32: 0x2;   // Its hit effect shows when it runs out of range.

// How a move ended (0x49d50, 0x4abac).
Projectile_Hit :: enum s32 { SKY :: -1; NONE :: 0; SOLID :: 4; OUT_OF_RANGE :: 5; WATER :: 6; }

// What a wall or object hit does with the projectile (0xfeea4).
WALL_HIT_IGNORE  :s32: 0;
WALL_HIT_NO_EXPLOSION :s32: 1;
WALL_HIT_EXPLODE :s32: 2;
WALL_HIT_BOUNCE  :s32: 4;

Hit_Effect :: struct {
    art: s32 = -1;              // Into the world's sprites.
    force, damage, range, wake_range: Fixed;
    sound: Sound_Handle;
}

HIT_EFFECT_SMALL :s32: 0;
HIT_EFFECT_THERMAL_DETONATOR :s32: 1;
HIT_EFFECT_CONCUSSION :s32: 4;
HIT_EFFECT_CONCUSSION_2 :s32: 5;
HIT_EFFECT_PLASMA :s32: 2;
HIT_EFFECT_PUNCH :s32: 8;
HIT_EFFECT_CANNON :s32: 9;
HIT_EFFECT_SPLASH :s32: 14;
HIT_EFFECT_SILENT :s32: 13;        // Unseen and unheard.
HIT_EFFECT_EXPLOSION :s32: 15;     // GENEXP.WAX, 35 damage.
HIT_EFFECT_EXPLOSION_HARMLESS :s32: 16;

// The projectiles' art and sounds (0x482d0) and the hit effects (0x4b110), all loaded with
// the level as the original does; play only looks them up.
load_projectile_assets :: () {
    w := *world.projectile_assets;
    for PROJECTILE_ART {
        if it.class == {
            case .MODEL;  w.art[it_index] = find_or_load_model(it.name);
            case .FRAME;  w.art[it_index] = find_or_load_frame(it.name);
            case;         w.art[it_index] = find_or_load_sprite(it.name);
        }
    }
    for PROJECTILE_SOUNDS  w.sounds[it_index] = register_sound(it.name, it.priority);

    for HIT_EFFECTS {
        e := *world.hit_effects[it_index];
        e.art = ifx it.art then find_or_load_sprite(it.art) else -1;
        e.force = it.force * FIXED_ONE;
        e.damage = it.damage * FIXED_ONE;
        e.range = it.range * FIXED_ONE;
        e.wake_range = it.wake_range * FIXED_ONE;
        e.sound = ifx it.sound then register_sound(it.sound, it.priority) else 0;
    }
    world.effect_puffs = 0;
}

unload_projectiles :: () {
    for world.projectiles  if it  free(it);
    array_free(world.projectiles);
    array_free(world.hit_queue);
}

// A projectile of a type, its object at a place (0x48794), by the type's entry in
// PROJECTILE_KINDS. The shooter's own shots don't hurt it between enemies.
create_projectile :: (type: Projectile_Type, sector: s32, at: Fixed3, shooter: s32) -> *Projectile {
    w := *world.projectile_assets;
    k := *PROJECTILE_KINDS[type];
    tick := cast(u32) world.clock.tick;
    proj := New(Projectile);
    proj.type = type;
    proj.shooter = shooter;
    proj.update = k.update;
    proj.damage = k.damage;
    proj.min_damage = k.min_damage;
    proj.falloff = k.falloff;
    proj.falloff_delay = k.falloff_delay;
    if k.falloff  proj.falloff_tick = tick + k.falloff_delay;
    proj.force = k.force;
    proj.speed = k.speed;
    proj.horizontal_bounce = k.horizontal_bounce;
    proj.vertical_bounce = k.vertical_bounce;
    proj.bounces = k.bounces;
    proj.reflect_variation = k.reflect_variation;
    proj.turn_rate = k.turn_rate;
    proj.duration = tick + k.duration;
    proj.reflect_effect = k.reflect_effect;
    proj.hit_effect = k.hit_effect;
    if k.flight >= 0   proj.flight_sound = w.sounds[k.flight];
    if k.pass >= 0     proj.pass_sound = w.sounds[k.pass];
    if k.reflect >= 0  proj.reflect_sound = w.sounds[k.reflect];
    proj.flags = PROJECTILE_PASS_SOUND;
    if k.flags & KIND_EXPLODES  proj.flags |= PROJECTILE_EXPLODES;

    class := Object_Class.SPIRIT;
    art: s32 = -1;
    if k.art >= 0  class, art = PROJECTILE_ART[k.art].class, w.art[k.art];
    proj.object = add_object(class, art, at, -1);
    o := world.objects[proj.object];
    set_object_size(o);
    o.width = 0;
    if type == .THERMAL_DETONATOR  o.height = FIXED_ONE;
    if type == .HOMING_MISSILE     o.width, o.height = FIXED_ONE, FIXED_ONE;
    o.lit = (k.flags & KIND_LIT) != 0;
    o.aimable = type == .HOMING_MISSILE;
    o.entity = ENTITY_PROJECTILE;
    // Only what lies about waiting is carried by moving walls (0x48794).
    if type != .THERMAL_DETONATOR && type != .LAND_MINE && type != .LAND_MINE_PROXIMITY && type != .LAND_MINE_PLACED {
        o.flags &= ~cast(u32) OBJECT_MOVABLE;
    }
    if type == .LAND_MINE || type == .LAND_MINE_PROXIMITY  o.entity |= ENTITY_LANDMINE_WEAPON;
    if class == .SPRITE  start_sprite_animation(proj.object);
    // At the end of the list, as the original's (0xfee50).
    array_add(*world.projectiles, proj);
    change_object_sector(proj.object, sector);
    return proj;
}

// Every frame (0x4ad84): damage falling off, running out of range (mines: going off when
// something comes near), being carried by a moving floor, moving, the sounds, and the end of
// those that hit something.
update_projectiles :: () {
    tick := cast(u32) world.clock.tick;
    remove_nulls(*world.projectiles);
    for index: 0..world.projectiles.count-1 {
        proj := world.projectiles[index];
        if !proj continue;
        o := world.objects[proj.object];
        hit := Projectile_Hit.NONE;
        if tick < proj.duration {
            if proj.falloff && proj.falloff_tick < tick {
                proj.damage -= proj.falloff;
                if proj.damage < proj.min_damage {
                    proj.falloff_tick = NEVER;
                    proj.damage = proj.min_damage;
                } else {
                    proj.falloff_tick += proj.falloff_delay;
                }
            }
        } else if proj.type == .LAND_MINE_PROXIMITY {
            // Armed: anything that walks within 15 units sets it off.
            if is_anything_in_reach(o.sector, 15 * FIXED_ONE, o.position, proj.object, ENTITY_PLAYER | ENTITY_AI_ACTOR) {
                arm_mine(proj, 0x91);
            }
        } else if proj.type == .LAND_MINE_PLACED {
            // Only the player sets these off. Far from it, the mine looks again in a time
            // that grows with the distance: a second for every 64 units.
            p := *world.player;
            distance := dist_approx(p.position.x, p.position.z, o.position.x, o.position.z);
            if distance <= 20 * FIXED_ONE {
                if o.position.y - 20 * FIXED_ONE <= p.position.y && p.position.y <= o.position.y + 20 * FIXED_ONE
                    && is_anything_in_reach(o.sector, 20 * FIXED_ONE, o.position, proj.object, ENTITY_PLAYER) {
                    arm_mine(proj, 0x57);
                }
            } else {
                proj.duration = tick + cast,no_check(u32) (mul16(distance / 64, 0x91A666) >> 16);
            }
        } else {
            hit = .OUT_OF_RANGE;
        }
        if hit == .NONE {
            carry_on_moving_floor(proj, o);
            if proj.update == {
                case .STRAIGHT;  hit = update_straight(proj);
                case .ARCING;    hit = update_arcing(proj);
                case .LAND_MINE; hit = update_land_mine(proj);
                case .HOMING;    hit = update_homing(proj);
            }
        }
        if proj.flight_sound  proj.flight_playing = maintain_sound(proj.flight_playing, proj.flight_sound, o.position);
        if proj.pass_sound && (proj.flags & PROJECTILE_PASS_SOUND) {
            eye := get_player_eye();
            if abs(o.position.y - eye.y) + dist_approx(eye.x, eye.z, o.position.x, o.position.z) < 15 * FIXED_ONE {
                proj.flight_playing = play_sound_at(proj.pass_sound, o.position);
                proj.flags &= ~PROJECTILE_PASS_SOUND;
            }
        } else if proj.pass_sound && proj.flight_playing {
            place_sound(proj.flight_playing, proj.pass_sound, o.position);
            proj.flight_playing = 0;
        }
        if hit != .NONE  end_projectile(proj, hit);
    }
}

// A mine set off (0x4ad54): it goes in so many ticks, beeping.
arm_mine :: (proj: *Projectile, ticks: u32) {
    o := world.objects[proj.object];
    proj.type = .LAND_MINE;
    proj.duration = cast(u32) world.clock.tick + ticks;
    play_sound_at(world.projectile_assets.sounds[PROJECTILE_SOUND_BEEP], o.position);
}

// A projectile on its sector's floor (or second floor) is carried with it when the
// sector's first link is an elevator that moves it (0x4ad84): the floor's speed is added to
// its velocity every frame it stays there, so one at rest gathers speed.
carry_on_moving_floor :: (proj: *Projectile, o: *Object) {
    e := get_floor_elevator(o);
    if !e return;
    v := get_elevator_velocity(e);
    proj.velocity.x += v.x;
    proj.velocity.z += v.z;
}

// Straight on along its velocity (0x49544).
update_straight :: (proj: *Projectile) -> Projectile_Hit {
    dt := world.clock.dt;
    proj.delta = .{mul16(proj.velocity.x, dt), mul16(proj.velocity.y, dt), mul16(proj.velocity.z, dt)};
    return move_projectile(proj);
}

// Falling under gravity, 120 units a second each second (0x49a20); its climb follows.
update_arcing :: (proj: *Projectile) -> Projectile_Hit {
    dt := world.clock.dt;
    proj.delta.x = mul16(proj.velocity.x, dt);
    proj.velocity.y += mul16(dt, 120 * FIXED_ONE);
    proj.delta.y = mul16(proj.velocity.y, dt);
    proj.delta.z = mul16(proj.velocity.z, dt);
    across := vec2_length(proj.velocity.x, proj.velocity.z);
    proj.dir.y = ifx across then div16(proj.velocity.y, across) else 0;
    return move_projectile(proj);
}

// A placed mine drops to its floor and stays (0x49aa0). Only its fall moves it: x and z
// keep whatever move it last had, none.
update_land_mine :: (proj: *Projectile) -> Projectile_Hit {
    o := world.objects[proj.object];
    floor := get_floor_and_ceiling(*world.level.sectors[o.sector], o.position.y);
    if o.position.y >= floor return .NONE;
    dt := world.clock.dt;
    proj.velocity.y += mul16(dt, 120 * FIXED_ONE);
    proj.delta.y = mul16(proj.velocity.y, dt);
    return move_projectile(proj);
}

// Turns toward the player a frame's worth of its turn rate (0x49b04), yaw first, then pitch
// toward a unit under the top of the player's head (none if that's more than 45 degrees
// off level); the rate grows each frame to about 50 degrees a second. Within 8 units of the
// player across, it goes off on odd ticks whether it has met it or not.
update_homing :: (proj: *Projectile) -> Projectile_Hit {
    o := world.objects[proj.object];
    p := *world.player;
    dt := world.clock.dt;
    target_y := p.position.y - p.height + FIXED_ONE;
    step := cast,no_check(s16) ((cast(s32) proj.turn_rate * dt) >> 16);
    dx := p.position.x - o.position.x;
    dz := p.position.z - o.position.z;
    turn := get_angle_difference(o.yaw, vec2_to_angle(dx, dz));
    o.yaw = cast,no_check(s16) (o.yaw + clamp_turn(turn, step));
    sin_yaw, cos_yaw := sin_cos(o.yaw);
    across := mul16(sin_yaw, dx) + mul16(cos_yaw, dz);
    pitch := cast,no_check(s16) vec2_to_angle(o.position.y - target_y, across);
    if pitch > 0x7FF && pitch < 0x37FF  pitch = 0;
    turn = get_angle_difference(o.pitch, pitch);
    o.pitch = cast,no_check(s16) (o.pitch + clamp_turn(turn, step));
    if proj.turn_rate < 0x238E  proj.turn_rate += cast,no_check(s16) ((cast(s64) dt * 0x71C) >> 16);
    turn_projectile(proj, o.pitch, o.yaw);
    hit := update_straight(proj);
    if hit == .NONE && dist_approx(o.position.x, o.position.z, p.position.x, p.position.z) < 8 * FIXED_ONE && (world.clock.tick & 1) {
        hit = .SOLID;
    }
    return hit;
}

clamp_turn :: (turn: s32, step: s16) -> s32 {
    if step < turn  return step;
    if turn < -step return -step;
    return turn;
}

// A projectile that has hit or run out (0x4abac): its effect where it stopped, unless above
// the ceiling or under the floor, then it goes.
end_projectile :: (proj: *Projectile, hit: Projectile_Hit) {
    o := world.objects[proj.object];
    stop_sound(proj.flight_playing);
    sector := *world.level.sectors[o.sector];
    inside := o.position.y <= sector.floor.altitude && sector.ceiling.altitude <= o.position.y;
    if hit == {
        case .SOLID;
            if inside  spawn_hit_effect(proj.hit_effect, o.sector, o.position, proj.exclude);
        case .OUT_OF_RANGE;
            if (proj.flags & PROJECTILE_EXPLODES) && inside && proj.type != .PUNCH {
                spawn_hit_effect(proj.hit_effect, o.sector, o.position, proj.exclude);
            }
        case .WATER;
            spawn_hit_effect(HIT_EFFECT_SPLASH, o.sector, o.position, proj.exclude);
    }
    // A placed mine carries an actor, for its damage.
    free_object_actor(proj.object);
    free_object(proj.object);
    for * world.projectiles  if it.* == proj { it.* = null; break; }
    free(proj);
}

// The projectile on an object goes with it, unspent.
free_object_projectile :: (object: s32) {
    proj := find_projectile(object);
    if !proj return;
    stop_sound(proj.flight_playing);
    for * world.projectiles  if it.* == proj { it.* = null; break; }
    free(proj);
}

find_projectile :: (object: s32) -> *Projectile {
    for world.projectiles  if it && it.object == object return it;
    return null;
}

// Aims at a point (0x4a9e4).
aim_projectile :: (proj: *Projectile, target: Fixed3) {
    o := world.objects[proj.object];
    dx := target.x - o.position.x;
    dy := target.y - o.position.y;
    dz := target.z - o.position.z;
    sin_yaw, cos_yaw := get_direction_and_length(dx, dz);
    across := mul16(sin_yaw, dx) + mul16(cos_yaw, dz);
    sin_pitch, cos_pitch := get_direction_and_length(-dy, across);
    set_projectile_heading(proj, sin_pitch, cos_pitch, sin_yaw, cos_yaw);
}

// Aims ahead of the player by the time it takes to reach them (0x4aa64), a unit under their
// head. The original leads by the velocity blasts and moving floors give and the vertical
// speed, not by walking.
lead_projectile :: (proj: *Projectile) {
    o := world.objects[proj.object];
    p := *world.player;
    time := div16(dist_approx(o.position.x, o.position.z, p.position.x, p.position.z), proj.speed);
    aim_projectile(proj, .{p.position.x + mul16(p.external.x, time), p.position.y + mul16(p.up_velocity, time) - p.height + FIXED_ONE, p.position.z + mul16(p.external.z, time)});
}

// Lobbed to land on a point (0x25520): the time to get there at its speed, the pitch that
// climbs against gravity (120 units a second each second) for half of it, and a new speed
// over the distance plus the drop. Facing the way the object does. The original divides by
// the time unchecked; one thrown straight down here keeps its speed.
aim_projectile_arcing :: (proj: *Projectile, target: Fixed3) {
    o := world.objects[proj.object];
    distance := dist_approx(o.position.x, o.position.z, target.x, target.z);
    time := div16(distance, proj.speed);
    climb := mul16(time >> 1, 120 * FIXED_ONE);
    dy := o.position.y - target.y;
    pitch := vec2_to_angle(dy, distance) + get_arcsine(div16(climb, proj.speed));
    if time  proj.speed = div16(dy + distance, time);
    turn_projectile(proj, pitch, o.yaw);
}

// The heading from angles (0x4a7c4).
turn_projectile :: (proj: *Projectile, pitch: s32, yaw: s32) {
    o := world.objects[proj.object];
    o.roll = 0;
    o.pitch = cast,no_check(s16) pitch;
    o.yaw = cast,no_check(s16) yaw;
    sin_yaw, cos_yaw := sin_cos(yaw);
    sin_pitch, cos_pitch := sin_cos(pitch);
    set_projectile_heading(proj, sin_pitch, cos_pitch, sin_yaw, cos_yaw);
}

// The velocity along a heading (0x4a824), and a 3D object's matrix, its length along the
// heading scaled by the frame's time.
set_projectile_heading :: (proj: *Projectile, sin_pitch: Fixed, cos_pitch: Fixed, sin_yaw: Fixed, cos_yaw: Fixed) {
    proj.dir.x = sin_yaw;
    proj.dir.z = cos_yaw;
    proj.velocity.x = mul16(cos_pitch, mul16(sin_yaw, proj.speed));
    proj.velocity.z = mul16(cos_pitch, mul16(cos_yaw, proj.speed));
    proj.velocity.y = mul16(-sin_pitch, proj.speed);
    across := vec2_length(proj.velocity.x, proj.velocity.z);
    proj.dir.y = ifx across then div16(proj.velocity.y, across) else 0;
    o := world.objects[proj.object];
    if o.class == .MODEL {
        // 0x59dd0.
        dt := world.clock.dt;
        o.matrix_set = true;
        o.matrix = .[cos_yaw, mul16(sin_pitch, sin_yaw), mul16(mul16(cos_pitch, sin_yaw), dt),
                     0,       cos_pitch,                 mul16(-sin_pitch, dt),
                     -sin_yaw, mul16(sin_pitch, cos_yaw), mul16(mul16(cos_pitch, cos_yaw), dt)];
    }
}

// The push a projectile gives what it hits (0x4ab38): its force times its speed along its
// heading, and up only when it was coming down, twice over.
get_projectile_push :: (proj: *Projectile) -> Fixed3 {
    push := mul16(proj.speed, proj.force);
    result := Fixed3.{mul16(push, proj.dir.x), 0, mul16(push, proj.dir.z)};
    if proj.dir.y < 0  result.y = mul16(push, proj.dir.y) * 2;
    return result;
}

// The direction from an explosion to a point (0x4ba84).
get_explosion_push :: (at: Fixed3) -> Fixed3 {
    e := world.explosion_at;
    dx, dz, across := get_direction_and_length(at.x - e.x, at.z - e.z);
    out, up := get_direction_and_length(across, at.y - e.y);
    return .{mul16(out, dx), up, mul16(out, dz)};
}

// Moves a projectile by its delta (0x495b0): first through the level, then against the
// objects on its way. An object hit takes the damage; a wall hit sends the wall the INF's
// shoot event, and in a sector with no walls drawn the projectile just goes.
move_projectile :: (proj: *Projectile) -> Projectile_Hit {
    o := world.objects[proj.object];
    hit_level := move_through_level(proj);
    if find_hit_object(proj) {
        o.position.y = world.projectile_move.hit_y;
        move_object_along(proj.object, world.projectile_move.hit_x - o.position.x, world.projectile_move.hit_z - o.position.z);
        if proj.bounces != -1 {
            if proj.type == .PUNCH {
                m := *world.projectile_move;
                spawn_hit_effect(proj.hit_effect, o.sector, .{m.hit_x, m.hit_y, m.hit_z}, proj.exclude);
            }
            world.projectile_move.wall_hit = WALL_HIT_EXPLODE;
            target := world.projectile_move.hit_object;
            if target >= 0 && (world.objects[target].entity & ENTITY_PROJECTILE) {
                world.projectile_move.wall_hit = WALL_HIT_IGNORE;
                // A homing missile goes when a shot of another kind meets it.
                other := find_projectile(target);
                if other && other.type != proj.type && other.type == .HOMING_MISSILE {
                    world.projectile_move.wall_hit = WALL_HIT_EXPLODE;
                    other.duration = 0;
                }
            } else if proj.damage {
                world.actor_state.message_projectile = proj;
                send_object_message(target, .DAMAGE);
            }
            if world.projectile_move.wall_hit == {
                case WALL_HIT_IGNORE;
                case WALL_HIT_NO_EXPLOSION; return .SKY;
                case WALL_HIT_BOUNCE;
                    reflect_projectile(proj, world.projectile_move.reflect_angle);
                    return .NONE;
                case; return .SOLID;
            }
        } else {
            proj.speed = mul16(proj.speed, proj.horizontal_bounce);
            yaw := o.yaw + 0x1000;
            o.yaw = (get_angle_difference(o.yaw, yaw) + yaw) & ANGLE_MASK;
            vary_reflection(proj, o);
            proj.last_hit = -1;
            proj.exclude = -1;
            turn_projectile(proj, o.pitch, o.yaw);
            play_sound_at(proj.reflect_sound, o.position);
            proj.flags |= PROJECTILE_PASS_SOUND;
            proj.delta.x = mul16(FIXED_HALF, proj.dir.x);
            proj.delta.z = mul16(FIXED_HALF, proj.dir.z);
            move_object_along(proj.object, proj.delta.x, proj.delta.z);
            proj.delta = .{};
        }
    }
    m := *world.projectile_move;
    if !hit_level {
        o.position.y += proj.delta.y;
        move_object_along(proj.object, proj.delta.x, proj.delta.z);
        return .NONE;
    }
    o.position.y = m.next.y;
    move_object_along(proj.object, m.next.x - o.position.x, m.next.z - o.position.z);
    if !m.wall  return ifx m.water then Projectile_Hit.WATER else .SOLID;
    m.wall_hit = ifx world.level.sectors[m.sector].flags[0] & SECTOR_NO_WALLS then WALL_HIT_NO_EXPLOSION else WALL_HIT_EXPLODE;
    send_wall_shot(m.wall_sector, m.wall, o.entity, m.next);
    if m.wall_hit == {
        case WALL_HIT_IGNORE; #through;
        case WALL_HIT_NO_EXPLOSION; return .SKY;
        case WALL_HIT_BOUNCE;
            reflect_projectile(proj, m.reflect_angle);
            return .NONE;
    }
    return .SOLID;
}

Projectile_Assets :: struct {
    art: [PROJECTILE_ART.count] s32;
    sounds: [PROJECTILE_SOUNDS.count] Sound_Handle;
}

Projectile_Art :: struct {
    name: string;
    class: Object_Class;
}

PROJECTILE_ART :: Projectile_Art.[
    .{"WRBOLT.3DO",   .MODEL},     // 0: red bolts.
    .{"WGBOLT.3DO",   .MODEL},     // 1: green bolts.
    .{"WDET.FME",     .FRAME},     // 2: thermal detonator.
    .{"BULLET.FME",   .FRAME},     // 3
    .{"WEMISS.WAX",   .SPRITE},    // 4: plasma.
    .{"WSHELL.WAX",   .SPRITE},    // 5: mortar shell.
    .{"WMINE.FME",    .FRAME},     // 6: thrown mine.
    .{"WLMINE.FME",   .FRAME},     // 7: placed mine.
    .{"WPLASMA.WAX",  .SPRITE},    // 8: cannon.
    .{"WMSL.WAX",     .SPRITE},    // 9: missile.
    .{"WIDBALL.WAX",  .SPRITE},    // 10: probe droid.
    .{"WDT3MSL.WAX",  .SPRITE},    // 11: homing missile.
    .{"BOBABALL.WAX", .SPRITE},    // 12
];

Projectile_Sound :: struct {
    name: string;
    priority: s32;
}

PROJECTILE_SOUNDS :: Projectile_Sound.[
    .{"BOLTREF1.VOC", 4},          // 0: a bolt glancing off.
    .{"THERMAL1.VOC", 4},          // 1: a detonator bouncing.
    .{"BIGREFL1.VOC", 4},          // 2: plasma glancing off.
    .{"LASRBY.VOC",   0xC},        // 3: a bolt passing.
    .{"EMISBY.VOC",   0xC},        // 4: plasma passing.
    .{"ROCKET-1.VOC", 0xC},        // 5
    .{"TRACKER.VOC",  0xC},        // 6: a homing missile.
    .{"FIREBALL.VOC", 0xC},        // 7
    .{"BEEP-10.VOC",  0x77},       // 8: a mine set off.
];

PROJECTILE_SOUND_BEEP :: 8;

// What each type is made with (0x48794): art (-1 a spirit, unseen), how it moves, its
// damage and how it falls off (by falloff every falloff_delay ticks, to min_damage), the
// push it gives, speed, how much speed it keeps bouncing off walls and off floors, bounces
// in a sealed sector (-1 always), how far bounces turn off true, ticks until out of range,
// the effects where it bounces and where it ends, and its sounds (-1 none).
Projectile_Kind :: struct {
    art: s32;
    update: Projectile_Update;
    flags: u32;
    damage, min_damage, falloff: Fixed;
    falloff_delay: u32;
    force, speed, horizontal_bounce, vertical_bounce: Fixed;
    bounces, reflect_variation: s32;
    turn_rate: s16;
    duration: u32;
    reflect_effect, hit_effect: s32;
    flight, pass, reflect: s32;
}

KIND_LIT      :u32: 0x1;
KIND_EXPLODES :u32: 0x2;        // Its hit effect shows when it runs out of range too.

PROJECTILE_KINDS :: Projectile_Kind.[
    // PUNCH: gone at once; the fists set its effect.
    .{art = -1, update = .STRAIGHT, damage = 6 * FIXED_ONE, force = 0x51E, speed = 230 * FIXED_ONE,
      reflect_effect = -1, hit_effect = -1, flight = -1, pass = -1, reflect = -1},
    // PISTOL_BOLT
    .{art = 0, update = .STRAIGHT, flags = KIND_LIT, damage = 10 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = FIXED_ONE, falloff_delay = 14, force = 0x28F, speed = 250 * FIXED_ONE,
      horizontal_bounce = FIXED_ONE, vertical_bounce = FIXED_ONE, bounces = 3, reflect_variation = 9,
      duration = 0x1B4, reflect_effect = 0, hit_effect = 0, flight = -1, pass = 3, reflect = 0},
    // RIFLE_BOLT
    .{art = 0, update = .STRAIGHT, flags = KIND_LIT, damage = 10 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = 0xCCCC, falloff_delay = 14, force = 0x28F, speed = 250 * FIXED_ONE,
      horizontal_bounce = FIXED_ONE, vertical_bounce = FIXED_ONE, bounces = 3, reflect_variation = 9,
      duration = 0x246, reflect_effect = 0, hit_effect = 0, flight = -1, pass = 3, reflect = 0},
    // THERMAL_DETONATOR: the explosion does the damage.
    .{art = 2, update = .ARCING, flags = KIND_EXPLODES, force = 0x1999, speed = 80 * FIXED_ONE,
      horizontal_bounce = 0x7333, vertical_bounce = 0xE3D7, bounces = -1, duration = 0x1B4,
      reflect_effect = -1, hit_effect = 1, flight = -1, pass = -1, reflect = 1},
    // REPEATER: its falloff waits as long as its whole flight.
    .{art = 3, update = .STRAIGHT, flags = KIND_LIT, damage = 10 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = 0x4CCC, falloff_delay = 0x4CCC, force = 0x7AE, speed = 270 * FIXED_ONE, bounces = 3,
      reflect_variation = 9, duration = 0x246, reflect_effect = -1, hit_effect = 10, flight = -1,
      pass = 3, reflect = 0},
    // PLASMA
    .{art = 4, update = .STRAIGHT, flags = KIND_LIT, damage = 15 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = 0x9999, falloff_delay = 0x1D, force = 0xCCC, speed = 100 * FIXED_ONE,
      horizontal_bounce = 0xE666, vertical_bounce = 0xE666, bounces = 3, reflect_variation = 9,
      duration = 0x5B0, reflect_effect = -1, hit_effect = HIT_EFFECT_PLASMA, flight = -1, pass = 4,
      reflect = 2},
    // MORTAR: goes off only where it lands.
    .{art = 5, update = .ARCING, force = 0x3333, speed = 110 * FIXED_ONE, horizontal_bounce = 0x6666,
      vertical_bounce = 0x9999, duration = 0x246, reflect_effect = -1, hit_effect = 3, flight = -1,
      pass = -1, reflect = -1},
    // LAND_MINE: thrown to go off when its time is up.
    .{art = 6, update = .ARCING, flags = KIND_EXPLODES, force = 0x3333, bounces = -1, duration = 0x1B4,
      reflect_effect = -1, hit_effect = 11, flight = -1, pass = -1, reflect = -1},
    // LAND_MINE_PROXIMITY: thrown, armed once its time is up.
    .{art = 6, update = .ARCING, flags = KIND_EXPLODES, force = 0x3333, bounces = -1, duration = 0x1B4,
      reflect_effect = -1, hit_effect = 11, flight = -1, pass = -1, reflect = -1},
    // LAND_MINE_PLACED: the level's, waiting for the player.
    .{art = 7, update = .LAND_MINE, flags = KIND_EXPLODES, force = 0x3333, bounces = -1,
      reflect_effect = -1, hit_effect = 11, flight = -1, pass = -1, reflect = -1},
    // CONCUSSION
    .{art = -1, update = .STRAIGHT, force = 0xF5C, speed = 190 * FIXED_ONE, horizontal_bounce = 0xE666,
      vertical_bounce = 0xE666, duration = 0x2D8, reflect_effect = -1, hit_effect = HIT_EFFECT_CONCUSSION,
      flight = -1, pass = -1, reflect = -1},
    // CANNON
    .{art = 8, update = .STRAIGHT, flags = KIND_LIT, damage = 30 * FIXED_ONE, force = 0xF5C,
      speed = 100 * FIXED_ONE, horizontal_bounce = 0xE666, vertical_bounce = 0xE666, bounces = 3,
      reflect_variation = 0x12, duration = 0x246, reflect_effect = -1, hit_effect = HIT_EFFECT_CANNON,
      flight = -1, pass = 4, reflect = 2},
    // MISSILE
    .{art = 9, update = .STRAIGHT, force = FIXED_ONE, speed = 74 * FIXED_ONE, horizontal_bounce = 0xE666,
      vertical_bounce = 0xE666, duration = 0x3FB, reflect_effect = -1, hit_effect = 6, flight = 5,
      pass = -1, reflect = -1},
    // TURRET_BOLT
    .{art = 1, update = .STRAIGHT, flags = KIND_LIT, damage = 17 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = FIXED_ONE, falloff_delay = 14, force = 0x7AE, speed = 300 * FIXED_ONE,
      horizontal_bounce = FIXED_ONE, vertical_bounce = FIXED_ONE, bounces = 3, reflect_variation = 9,
      duration = 0x1B4, reflect_effect = 0, hit_effect = 0, flight = -1, pass = 3, reflect = 0},
    // REMOTE_BOLT: down to no damage after 14 ticks.
    .{art = 1, update = .STRAIGHT, flags = KIND_LIT, damage = FIXED_ONE, falloff = FIXED_ONE,
      falloff_delay = 14, force = 0x28F, speed = 300 * FIXED_ONE, horizontal_bounce = FIXED_ONE,
      vertical_bounce = FIXED_ONE, bounces = 3, reflect_variation = 9, duration = 0x1B4,
      reflect_effect = 0, hit_effect = 0, flight = -1, pass = 3, reflect = 0},
    // BARREL: unseen and still, its explosion at once.
    .{art = -1, update = .STRAIGHT, flags = KIND_EXPLODES, reflect_effect = -1, hit_effect = 12,
      flight = -1, pass = -1, reflect = -1},
    // HOMING_MISSILE: can be aimed at, and shot down. The original gives it 58, but it's the
    // one projectile with a width, and its object search meets the missile itself: each frame
    // it's put back a unit, so it flies at 58 less the frame rate, about half at the rates of
    // 1995. Here it skips itself, at the speed players saw then.
    .{art = 11, update = .HOMING, flags = KIND_EXPLODES, force = FIXED_ONE, speed = 29 * FIXED_ONE,
      horizontal_bounce = 0xE666, vertical_bounce = 0xE666, turn_rate = 0x1C7, duration = 0x5B0,
      reflect_effect = -1, hit_effect = 6, flight = 6, pass = -1, reflect = -1},
    // PROBE
    .{art = 10, update = .STRAIGHT, flags = KIND_LIT, damage = 10 * FIXED_ONE, min_damage = FIXED_ONE,
      falloff = FIXED_ONE, falloff_delay = 14, force = 0xA3D, speed = 100 * FIXED_ONE,
      horizontal_bounce = 0xE666, vertical_bounce = 0xE666, bounces = 3, reflect_variation = 9,
      duration = 0x48D, reflect_effect = -1, hit_effect = HIT_EFFECT_PLASMA, flight = -1, pass = 4,
      reflect = 2},
    // BOBA_FETT_BALL
    .{art = 12, update = .STRAIGHT, force = FIXED_ONE, speed = 90 * FIXED_ONE, horizontal_bounce = 0xE666,
      vertical_bounce = 0xE666, duration = 0x5B0, reflect_effect = -1, hit_effect = 17, flight = -1,
      pass = 7, reflect = -1},
];

// The hit effects by kind (0x4b110): sprite, push, damage, its range, the range it wakes
// enemies in, and the sound.
Hit_Effect_Data :: struct {
    art: string;
    force, damage, range, wake_range: s32;
    sound: string;
    priority: s32;
}

HIT_EFFECTS :: Hit_Effect_Data.[
    .{"EXPTINY.WAX",  0,   0,  0, 40, "EX-TINY1.VOC", 1},      // Blaster puff.
    .{"DETEXP.WAX",  50,  60, 30, 50, "EX-SMALL.VOC", 0x6B},   // Thermal detonator.
    .{"EMISEXP.WAX",  0,   0,  0, 40, "EX-TINY1.VOC", 1},      // Plasma puff.
    .{"MORTEXP.WAX", 35,  50, 40, 60, "EX-MED1.VOC", 0x73},    // Mortar.
    .{"CONCEXP.WAX", 30,  30, 25, 60, "EX-LRG1.VOC", 0x73},    // Concussion.
    .{"",            30,  30, 25, 60, "EX-LRG1.VOC", 0x73},    // Concussion, second stage.
    .{"MISSEXP.WAX", 70,  70, 40, 70, "EX-MED1.VOC", 0x73},    // Missile.
    .{"MISSEXP.WAX", 50,  25, 40, 70, "EX-MED1.VOC", 0x73},    // Missile, weaker.
    .{"",             0,   0,  0, 10, "PUNCH.VOC", 4},         // Punch.
    .{"PLASEXP.WAX",  0,   0,  0, 50, "EX-MED1.VOC", 1},       // Cannon puff.
    .{"BULLEXP.WAX",  0,   0,  0, 50, "EX-TINY1.VOC", 1},      // Repeater puff.
    .{"MINEEXP.WAX", 80,  90, 45, 90, "EX-LRG1.VOC", 0x73},    // Land mine.
    .{"",           120,  60, 40, 60, "EX-MED1.VOC", 0x4C},    // Barrel.
    .{"",            60,  40, 20, 60, "", 0},                   // Unseen, unheard.
    .{"SPLASH.WAX",   0,   0,  0, 40, "SWIM-IN.VOC", 0xC},     // Splash.
    .{"GENEXP.WAX",  30,  35, 30, 50, "EX-MED1.VOC", 0x73},    // 35 damage.
    .{"GENEXP.WAX",   0,   0,  0, 50, "EX-MED1.VOC", 0x73},    // No damage.
    .{"GENEXP.WAX",  20,  25, 20, 50, "EX-MED1.VOC", 0x73},    // 25 damage.
];

// The state of a projectile's move (0xfed4c, 0xfee4c-0xfeeac).
Projectile_Move :: struct {
    next: Fixed3;               // Where it gets to.
    sector: s32;                // The sector it's in there.
    path: [32] s32;             // The sectors it went through.
    path_count: s32;
    wall: *Wall;                // The wall it hit,
    wall_sector: s32;           // in this sector.
    water: bool;
    wall_hit: s32;
    reflect_angle: s32;
    hit_object: s32;            // OBJECT_IS_PLAYER for the player.
    hit_x, hit_y, hit_z: Fixed; // Where it met the object.
}

#scope_file

// Moves an object by (dx, dz) through any openings, its y left alone (0x8a538): it stays
// where it was if the path leaves the level.
move_object_along :: (index: s32, dx: Fixed, dz: Fixed) {
    o := world.objects[index];
    x1, z1 := o.position.x + dx, o.position.z + dz;
    sector := o.sector;
    if dx || dz {
        wall, in_sector := find_path_wall(sector, o.position.x, o.position.z, x1, z1);
        while wall {
            if wall.adjoin < 0 return;
            sector = wall.adjoin;
            wall, in_sector = find_next_path_wall(sector);
        }
    }
    o.position.x, o.position.z = x1, z1;
    if sector != o.sector  change_object_sector(index, sector);
}

// The move through the level (0x49d50): true when it stops at a wall, the floor or the
// ceiling, with where in world.projectile_move. Passing an opening needs the whole move in
// it; a thermal detonator's top too. Bouncing ones turn there instead and go on next frame.
move_through_level :: (proj: *Projectile) -> bool {
    o := world.objects[proj.object];
    m := *world.projectile_move;
    m.wall = null;
    m.water = false;
    m.sector = o.sector;
    m.path[0] = o.sector;
    m.path_count = 1;
    m.next = .{o.position.x + proj.delta.x, o.position.y + proj.delta.y, o.position.z + proj.delta.z};
    floor, ceiling: Fixed;
    hit_floor, hit_ceiling: bool;
    wall, in_sector := find_path_wall(m.sector, o.position.x, o.position.z, m.next.x, m.next.z);
    while wall {
        top, bottom: Fixed;
        if wall.adjoin >= 0 && !(wall.flags[2] & WALL_NO_SHOOT) {
            top, bottom = get_opening(in_sector, wall);
            y1 := ifx proj.type == .THERMAL_DETONATOR then m.next.y - o.height else m.next.y;
            if o.position.y <= bottom && top <= o.position.y && m.next.y <= bottom && top <= y1 {
                m.sector = wall.adjoin;
                add_to_path(m, m.sector);
                wall, in_sector = find_next_path_wall(m.sector);
                continue;
            }
        } else {
            top, bottom = FIXED_INFINITY, -FIXED_INFINITY;
        }
        m.next.x, m.next.z = get_path_hit();
        across := vec2_length(m.next.x - o.position.x, m.next.z - o.position.z);
        y1 := o.position.y + mul16(across, proj.dir.y);
        here := *world.level.sectors[m.sector];
        floor, ceiling = get_floor_and_ceiling(here, o.position.y);
        if here.second_altitude - 1 >= 0  floor = here.floor.altitude;
        y := floor;
        if y1 <= floor {
            y = y1;
            if y1 < ceiling  y = ceiling;
        }
        top_y := ifx proj.type == .THERMAL_DETONATOR then y - o.height else y;
        if bottom < y || top_y < top {
            // The wall: back off it a unit and a half.
            m.next.x -= mul16(0x18000, proj.dir.x);
            m.next.z -= mul16(0x18000, proj.dir.z);
            m.next.y = y;
            proj.delta = .{m.next.x - o.position.x, m.next.y - o.position.y, m.next.z - o.position.z};
            if proj.bounces == -1 {
                if m.next.y < here.ceiling.altitude {
                    m.wall, m.wall_sector = wall, in_sector;
                    return true;
                }
                proj.speed = mul16(proj.speed, proj.horizontal_bounce);
                o.pitch = get_angle_difference(o.pitch, 0) & ANGLE_MASK;
                bounce_off_wall(proj, o, wall.angle);
                return false;
            }
            if here.flags[0] & SECTOR_MAG_SEAL {
                if m.next.y < here.ceiling.altitude {
                    m.wall, m.wall_sector = wall, in_sector;
                    return true;
                }
                count := proj.bounces;
                proj.bounces -= 1;
                if count {
                    spawn_hit_effect(proj.reflect_effect, m.sector, m.next, proj.exclude);
                    bounce_off_wall(proj, o, wall.angle);
                    return false;
                }
            }
            m.wall, m.wall_sector = wall, in_sector;
            return true;
        }
        if floor <= y1 { hit_floor = true; break; }
        if y1 <= ceiling { hit_ceiling = true; break; }
        m.sector = wall.adjoin;
        add_to_path(m, m.sector);
        wall, in_sector = find_next_path_wall(m.sector);
    }
    if !hit_floor && !hit_ceiling {
        here := *world.level.sectors[m.sector];
        floor, ceiling = get_floor_and_ceiling(here, o.position.y);
        if here.second_altitude - 1 >= 0  floor = here.floor.altitude;
        if floor < m.next.y        hit_floor = true;
        else if m.next.y < ceiling hit_ceiling = true;
        else return false;
    }
    surface := ifx hit_floor then floor else ceiling;
    u := div16(surface - o.position.y, proj.delta.y);
    m.next = .{o.position.x + mul16(proj.delta.x, u), surface, o.position.z + mul16(proj.delta.z, u)};
    if hit_floor && world.level.sectors[m.sector].second_altitude > 0 {
        m.water = true;
        return true;
    }
    if proj.type == .THERMAL_DETONATOR && abs(proj.speed) > 7 * FIXED_ONE  play_sound_at(proj.reflect_sound, o.position);
    if proj.bounces == -1 {
        o.pitch = cast,no_check(s16) -o.pitch;
        proj.last_hit = -1;
        proj.exclude = -1;
        proj.speed = mul16(proj.speed, proj.vertical_bounce);
        turn_projectile(proj, o.pitch, o.yaw);
        settle_bounce(proj, o, m);
        return false;
    }
    if world.level.sectors[m.sector].flags[0] & SECTOR_MAG_SEAL {
        count := proj.bounces;
        proj.bounces -= 1;
        if count {
            spawn_hit_effect(proj.reflect_effect, m.sector, m.next, proj.exclude);
            o.pitch = cast,no_check(s16) -o.pitch;
            vary_reflection(proj, o);
            proj.last_hit = -1;
            proj.exclude = -1;
            turn_projectile(proj, o.pitch, o.yaw);
            play_sound_at(proj.reflect_sound, o.position);
            settle_bounce(proj, o, m);
            return false;
        }
    }
    return true;
}

add_to_path :: (m: *Projectile_Move, sector: s32) {
    if m.path_count < m.path.count {
        m.path[m.path_count] = sector;
        m.path_count += 1;
    }
}

// Turned off a wall like a mirror, then moved to where it met it.
bounce_off_wall :: (proj: *Projectile, o: *Object, angle: s32) {
    o.yaw = (get_angle_difference(o.yaw, angle) + angle) & ANGLE_MASK;
    vary_reflection(proj, o);
    proj.last_hit = -1;
    proj.exclude = -1;
    turn_projectile(proj, o.pitch, o.yaw);
    play_sound_at(proj.reflect_sound, o.position);
    proj.flags |= PROJECTILE_PASS_SOUND;
    settle_bounce(proj, o, *world.projectile_move);
}

settle_bounce :: (proj: *Projectile, o: *Object, m: *Projectile_Move) {
    o.position.y = m.next.y;
    move_object_along(proj.object, proj.delta.x, proj.delta.z);
    m.sector = o.sector;
    proj.delta = .{};
}

// A little off a true reflection, in whole angle units.
vary_reflection :: (proj: *Projectile, o: *Object) {
    v := proj.reflect_variation;
    if !v return;
    o.yaw = cast,no_check(s16) (o.yaw + fixed_random(v * 2) - v);
    o.pitch = cast,no_check(s16) (o.pitch + fixed_random(v * 2) - v);
}

// Turned back from what it hit, toward a reflection angle (0x495b0).
reflect_projectile :: (proj: *Projectile, angle: s32) {
    o := world.objects[proj.object];
    o.yaw = cast,no_check(s16) ((get_angle_difference(o.yaw, cast,no_check(s16) angle) + angle) & ANGLE_MASK);
    vary_reflection(proj, o);
    proj.last_hit = -1;
    proj.exclude = -1;
    turn_projectile(proj, o.pitch, o.yaw);
    play_sound_at(proj.reflect_sound, o.position);
    proj.flags |= PROJECTILE_PASS_SOUND;
}

// The opening in a wall a projectile can pass (0x575fc): from the higher ceiling of its two
// sectors to the lower floor, skies and pits 100 units off.
get_opening :: (sector: s32, wall: *Wall) -> top: Fixed, bottom: Fixed {
    here := *world.level.sectors[sector];
    next := *world.level.sectors[wall.adjoin];
    here_floor, here_ceiling := get_flat_heights(here);
    next_floor, next_ceiling := get_flat_heights(next);
    top := ifx here_ceiling <= next_ceiling then next_ceiling else here_ceiling;
    bottom := ifx here_floor >= next_floor then next_floor else here_floor;
    return top, bottom;
}

get_flat_heights :: (sector: *Sector) -> floor: Fixed, ceiling: Fixed {
    floor, ceiling := sector.floor.altitude, sector.ceiling.altitude;
    if sector.flags[0] & SECTOR_PIT       floor += SKY_DEPTH;
    if sector.flags[0] & SECTOR_EXTERIOR  ceiling -= SKY_DEPTH;
    return floor, ceiling;
}

// The first object a projectile's path meets (0x4a668, 0x5bd78): the sectors it went
// through from the last, each object in turn other than the one it last hit, with a width,
// at a height the path spans, near enough across the path and not yet passed. The original
// keeps the player among its sector's objects; here it's looked at after them. The original
// doesn't pass over the projectile's own object either (see HOMING_MISSILE); here it does.
find_hit_object :: (proj: *Projectile) -> bool {
    if !proj.speed return false;
    o := world.objects[proj.object];
    m := *world.projectile_move;
    reach := mul16(proj.speed, world.clock.dt);
    y0, y1 := o.position.y, m.next.y;
    max_y, min_y := max(y0, y1), min(y0, y1);
    overlap: Fixed;
    hit: s32 = -1;
    while m.path_count > 0 && hit == -1 {
        m.path_count -= 1;
        sector := m.path[m.path_count];
        for index: walk_sector(sector) {
            t := world.objects[index];
            if index == proj.object || index == proj.last_hit || !t.width continue;
            hit_on, along := meets_path(o.position, proj.dir, reach, min_y, max_y, t.position, t.width, t.height);
            if hit_on { hit = cast(s32) index; overlap = along - t.width; break; }
        }
        p := *world.player;
        if hit == -1 && p.sector == sector && proj.last_hit != OBJECT_IS_PLAYER {
            hit_on, along := meets_path(o.position, proj.dir, reach, min_y, max_y, p.position, p.width, p.height);
            if hit_on { hit = OBJECT_IS_PLAYER; overlap = along - p.width; }
        }
    }
    if hit == -1 return false;
    m.hit_object = hit;
    m.hit_x = o.position.x + mul16(proj.dir.x, overlap);
    m.hit_z = o.position.z + mul16(proj.dir.z, overlap);
    m.hit_y = o.position.y + mul16(proj.dir.y, overlap);
    sector, floor, ceiling := find_move_sector(o.sector, o.position.x, o.position.z, m.hit_x, m.hit_z);
    if sector < 0 return false;
    s := *world.level.sectors[sector];
    if m.hit_y < s.ceiling.altitude  m.hit_y = s.ceiling.altitude;
    if s.floor.altitude < m.hit_y    m.hit_y = s.floor.altitude;
    if proj.type == .CONCUSSION  proj.hit_effect = 5;
    return true;
}

meets_path :: (from: Fixed3, dir: Fixed3, reach: Fixed, min_y: Fixed, max_y: Fixed, at: Fixed3, width: Fixed, height: Fixed) -> bool, Fixed {
    if height >= 0 {
        if at.y < min_y || max_y < at.y - height return false, 0;
    } else {
        if max_y < at.y || at.y - height < min_y return false, 0;
    }
    dx := at.x - from.x;
    dz := at.z - from.z;
    across := mul16(dx, dir.z) - mul16(dz, dir.x);
    if abs(across) > width return false, 0;
    along := mul16(dx, dir.x) + mul16(dz, dir.z);
    if reach + width < along || along < -width return false, 0;
    return true, along;
}

#scope_module

// The sector the straight path from a point reaches (0x5bbdc), -1 if it leaves the level.
find_move_sector :: (sector: s32, x0: Fixed, z0: Fixed, x1: Fixed, z1: Fixed) -> s32, Fixed, Fixed {
    current := sector;
    if x0 != x1 || z0 != z1 {
        wall, in_sector := find_path_wall(sector, x0, z0, x1, z1);
        while wall {
            if wall.adjoin < 0 return -1, 0, 0;
            current = wall.adjoin;
            wall, in_sector = find_next_path_wall(current);
        }
    }
    return current, 0, 0;
}

// A hit effect at a place (0x4b854): queued, and its task woken to deal it out in its turn.
spawn_hit_effect :: (type: s32, sector: s32, at: Fixed3, exclude: s32) {
    if type < 0 return;
    array_add(*world.hit_queue, .{type, sector, at, exclude});
}

Queued_Hit :: struct {
    type: s32;
    sector: s32;
    at: Fixed3;
    exclude: s32;
}

// The hit effects' task (0x4b890): each queued effect in turn, those queued meanwhile too:
// its sprite played once, at full light but for the splash; its sound; for explosions,
// damage to what's in range and the INF's explosion event around; and the enemies near it
// woken. Plasma and cannon puffs show at most five at a time; a concussion's goes to the
// floor.
update_hit_effects :: () {
    while world.hit_queue {
        h := world.hit_queue[0];
        array_ordered_remove_by_index(*world.hit_queue, 0);
        if h.type < world.hit_effects.count  deal_hit_effect(h.type, h.sector, h.at, h.exclude);
    }
}

deal_hit_effect :: (type: s32, sector: s32, at_in: Fixed3, exclude: s32) {
    e := *world.hit_effects[type];
    at := at_in;
    puff := type == HIT_EFFECT_PLASMA || type == HIT_EFFECT_CANNON;
    if e.art >= 0 && !(puff && world.effect_puffs > 4) {
        if puff  world.effect_puffs += 1;
        if type == HIT_EFFECT_CONCUSSION || type == HIT_EFFECT_CONCUSSION_2 {
            at.y = get_floor_and_ceiling(*world.level.sectors[sector], at.y);
        }
        index := add_object(.SPRITE, e.art, at, sector);
        o := world.objects[index];
        o.lit = type != HIT_EFFECT_SPLASH;
        start_sprite_animation(index, loops = 1);
        o.sprite_anim.puff = puff;
    }
    if e.sound  play_sound_at(e.sound, at);
    if e.range {
        world.explosion_at = at;
        world.explosion_type = type;
        deal_explosion(sector, e.range, at, exclude);
        if type != HIT_EFFECT_PUNCH  send_explosion_event(sector, at, e.range / 8);
    }
    if e.wake_range  wake_actors_in_range(sector, e.wake_range, at, exclude);
}

// The explosion's damage to what's within its range of the blast (0x5c66c): enemies,
// scenery, mines and the player, in reach of a line from the blast to their feet or their
// top that no wall stops (nor one shots don't pass). As in the original, the blast's own
// sector's bounds and heights are tested for every sector looked through, so once those
// pass it looks at all of them.
deal_explosion :: (start: s32, range: Fixed, at: Fixed3, exclude: s32) {
    first := *world.level.sectors[start];
    if at.x - range > first.bounds_max.x || first.bounds_min.x > at.x + range return;
    if at.z - range > first.bounds_max.z || first.bounds_min.z > at.z + range return;
    floor, ceiling := get_floor_and_ceiling(first, at.y);
    if at.y - range > floor || ceiling > at.y + range return;
    MASK :: ENTITY_PLAYER | ENTITY_LANDMINE_WEAPON | ENTITY_LANDMINE | ENTITY_SCENERY | ENTITY_AI_ACTOR;
    for sector_index: 0..world.level.sectors.count-1 {
        // A message may free an object or move it.
        for index: walk_sector(xx sector_index, live = true) {
            if index == exclude continue;
            o := world.objects[index];
            if !o.used || o.sector != sector_index || !(o.entity & MASK) continue;
            if !is_in_blast(start, at, range, o.sector, o.position, o.height) continue;
            explode_object(index, o.entity, o.position);
        }
        p := *world.player;
        if p.sector == sector_index && exclude != OBJECT_IS_PLAYER && is_in_blast(start, at, range, p.sector, p.position, p.height) {
            explode_object(OBJECT_IS_PLAYER, ENTITY_PLAYER, p.position);
        }
    }
}

is_in_blast :: (start: s32, at: Fixed3, range: Fixed, sector: s32, position: Fixed3, height: Fixed) -> bool {
    if position.x < at.x - range || position.x > at.x + range return false;
    if position.z < at.z - range || position.z > at.z + range return false;
    if position.y < at.y - range || position.y > at.y + range return false;
    if can_line_reach(start, sector, at, position, WALL_NO_SHOOT) return true;
    top := Fixed3.{position.x, position.y - height, position.z};
    return can_line_reach(start, sector, at, top, WALL_NO_SHOOT);
}

// What the explosion does to one thing (0x335d0): damage and push falling off with the
// quick distance from the blast, sent as the explosion message; a concussion's damage is
// whole, with a burst of its own at the thing's feet. A mine within 10 units is set off.
explode_object :: (index: s32, entity: u32, position: Fixed3) {
    e := *world.hit_effects[world.explosion_type];
    at := world.explosion_at;
    dy := abs(at.y - position.y);
    distance := dist_approx(position.x, position.z, at.x, at.z);
    if !(entity & (ENTITY_LANDMINE | ENTITY_LANDMINE_WEAPON)) {
        left := e.range - (distance + dy);
        if left < 0  left = 0;
        share := div16(left, e.range);
        s := *world.actor_state;
        if world.explosion_type == HIT_EFFECT_CONCUSSION || world.explosion_type == HIT_EFFECT_CONCUSSION_2 {
            burst := *world.hit_effects[HIT_EFFECT_CONCUSSION];
            sector := ifx index == OBJECT_IS_PLAYER then world.player.sector else world.objects[index].sector;
            floor := get_floor_and_ceiling(*world.level.sectors[sector], at.y);
            b := add_object(.SPRITE, burst.art, .{position.x, floor, position.z}, sector);
            world.objects[b].lit = true;
            start_sprite_animation(b, loops = 1);
            play_sound_at(burst.sound, world.objects[b].position);
            s.message_damage = e.damage;
        } else {
            s.message_damage = mul16(share, e.damage);
        }
        s.message_force = mul16(share, e.force);
        send_object_message(index, .EXPLOSION);
    } else if distance + dy < 10 * FIXED_ONE {
        mine := find_projectile(index);
        if mine  arm_mine(mine, ifx entity & ENTITY_LANDMINE then cast(u32) 0x57 else 0x91);
    }
}

// The INF's explosion event to the blast's sector, then to every sector a cylinder of the
// given radius at the blast reaches into, the blast's own again first (0x5ce74).
send_explosion_event :: (sector: s32, at: Fixed3, radius: Fixed) {
    send_explosion(sector);
    c: Collision;
    c.dst = .{at.x, at.z};
    c.width = radius;
    for_each_sector_reached(*c, sector, (c: *Collision, sector: s32) -> bool {
        send_explosion(sector);
        return true;
    });
}

// Whether something of the entities given is within range of a point and reached from it
// along the ground (0x5cbc8): through openings at least half a unit high, into its sector.
// The start sector's bounds and heights stand for every sector, as in the explosion.
is_anything_in_reach :: (start: s32, range: Fixed, origin: Fixed3, exclude: s32, mask: u32) -> bool {
    first := *world.level.sectors[start];
    if origin.x - range > first.bounds_max.x || first.bounds_min.x > origin.x + range return false;
    if origin.z - range > first.bounds_max.z || first.bounds_min.z > origin.z + range return false;
    floor, ceiling := get_floor_and_ceiling(first, origin.y);
    if origin.y - range > floor || ceiling > origin.y + range return false;
    for sector_index: 0..world.level.sectors.count-1 {
        for index: walk_sector(xx sector_index) {
            if index == exclude continue;
            o := world.objects[index];
            if (o.entity & mask) && is_reached(start, range, origin, o.sector, o.position) return true;
        }
        p := *world.player;
        if (mask & ENTITY_PLAYER) && p.sector == sector_index && is_reached(start, range, origin, p.sector, p.position) return true;
    }
    return false;
}

is_reached :: (start: s32, range: Fixed, origin: Fixed3, sector: s32, p: Fixed3) -> bool {
    if p.x < origin.x - range || p.x > origin.x + range return false;
    if p.z < origin.z - range || p.z > origin.z + range return false;
    if p.y < origin.y - range || p.y > origin.y + range return false;
    if p.x == origin.x && p.z == origin.z  return start == sector;
    wall, here := find_path_wall(start, origin.x, origin.z, p.x, p.z);
    while wall && here != sector {
        if wall.adjoin < 0 return false;
        here = wall.adjoin;
        next := *world.level.sectors[here];
        if next.floor.altitude - next.ceiling.altitude < 0x8000 break;
        wall, here = find_next_path_wall(here);
    }
    return here == sector;
}

// A message to the player (0x2aac4): a projectile's push and damage to the shields, or an
// explosion's. Invincible, a projectile glances off instead.
player_message :: (message: Actor_Message) {
    p := *world.player;
    s := *world.player_state;
    if message == .DAMAGE {
        proj := world.actor_state.message_projectile;
        push := get_projectile_push(proj);
        p.external.x += push.x;
        p.tick_up_velocity += push.y;
        p.external.z += push.z;
        if s.invincible == 0 {
            apply_damage(0, proj.damage, true);
        } else {
            o := world.objects[proj.object];
            world.projectile_move.wall_hit = WALL_HIT_BOUNCE;
            world.projectile_move.reflect_angle = vec2_to_angle(o.position.x - p.position.x, o.position.z - p.position.z) + 0xFFF;
        }
    } else if message == .EXPLOSION {
        dir := get_explosion_push(.{p.position.x, p.position.y - p.height, p.position.z});
        force := world.actor_state.message_force;
        p.external.x += mul16(force, dir.x);
        p.tick_up_velocity += mul16(force, dir.y);
        p.external.z += mul16(force, dir.z);
        if s.invincible == 0 {
            damage := world.actor_state.message_damage;
            if world.explosion_type == HIT_EFFECT_THERMAL_DETONATOR  damage = damage >> 1;
            apply_damage(0, damage, true);
        }
    }
}

// The items' art, loaded with the level (0x30cxx) for those the game makes itself.
load_item_art :: () {
    for ITEM_ART {
        wax := ends_with(it, ".WAX");
        world.item_art[it_index] = ifx wax then find_or_load_sprite(it) else find_or_load_frame(it);
    }
}

// An item's object (0x3194b): its sprite or frame, made a pickup.
create_item :: (item: s32, sector: s32, at: Fixed3) -> s32 {
    wax := ends_with(ITEM_ART[item], ".WAX");
    index := add_object(ifx wax then Object_Class.SPRITE else .FRAME, world.item_art[item], at, sector);
    o := world.objects[index];
    set_object_size(o);
    make_pickup(o, item);
    if wax  start_sprite_animation(index);
    return index;
}
