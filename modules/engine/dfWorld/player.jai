// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The player, as DARK.EXE's player task moves it, in its 16.16 math.
//
// Some of it runs on every tick of the game's 145.65 Hz timer, in the original's timer
// interrupt (0x2f9ec): turning by the keys, and gravity. The rest runs once a frame
// (0x2ab28): the controls (0x2ad50, keyboard 0x2b1a8) and the physics (0x2d17c), which
// moves the player through collision.jai, lands it, crouches and squashes its eye, and
// bobs its head.
//
// Angles are the original's, 16384 to a turn; yaw 0 faces +z and turns clockwise seen from
// above. Positions are the feet, y down; "height" is the eye's height over the feet.

Player :: struct {
    position: Fixed3;
    sector:   s32 = -1;             // The sector its object is in.
    floor_sector: s32 = -1;         // The sector whose floor it last stood over, from collision.
    width:    Fixed = PLAYER_WIDTH;
    height:   Fixed = PLAYER_HEIGHT;
    step:     Fixed = PLAYER_STEP;

    yaw:      s32;                  // The controls' yaw: keys turn it every tick.
    object_yaw: s32;                // The yaw the object has: the controls' at the end of a frame.
    pitch, roll: s32;

    // The vertical motion. y and its speed go on every tick under gravity; the frame then
    // takes them as the player's height and speed and lands or stops it.
    y:           Fixed;
    tick_up_velocity: Fixed;        // Down is positive.
    up_velocity: Fixed;
    move_y:      Fixed;             // How far the ticks moved it since the last frame.

    velocity: Fixed2;               // Units a second.
    external: Fixed2;               // Given by moving floors.
    move: Fixed2;                   // This frame's move.
    forward, strafe: Fixed;         // This frame's push, scaled by the frame's time.
    yaw_speed: Fixed;               // Given by turning floors.
    run, slow, jump_scale, on_moving_surface: s32;     // Shifts.
    crouch_speed: Fixed;
    rise_speed:   Fixed = -0x84000; // The crouch speed when not crouching: the eye rises 8.25/s.
    max_move: Fixed = 32 * FIXED_ONE;
    min_eye:  Fixed = 2 * FIXED_ONE;

    on_floor, jump_held, in_water: bool;
    fallen: Fixed;                  // The farthest it has been over the floor since standing.
    land_squash: Fixed;             // The eye's drop after a landing, units a second.
    land_velocity: Fixed;           // The speed it landed at.
    slide_wall: *Wall;              // The wall it last slid along.

    speed_average: Fixed;           // For the head bob.
    bob: Fixed;                     // The camera's offset in y.
    weapon_wave: Fixed;

    frozen: bool = true;            // Until the first frame: the ticks leave it alone.
    use_held: bool;
    last_tick: s32;                 // The game tick of its last frame.
}

world_get_player :: () -> *Player { return *world.player; }

// Puts the player's feet at p, in the sector holding it; below the floor, on the floor.
// False (and nothing moved) when no sector holds it.
world_place_player :: (p: Vector3) -> bool {
    at := Fixed3.{float_to_fixed(p.x), float_to_fixed(p.y), float_to_fixed(p.z)};
    sector := level_find_sector(*world.level, at);
    if sector < 0 return false;
    player := *world.player;
    player.position = at;
    floor, _ := get_floor_and_ceiling(*world.level.sectors[sector], at.y);
    player.position.y = min(at.y, floor);
    player.y = player.position.y;
    player.sector = sector;
    player.floor_sector = sector;
    player.up_velocity, player.tick_up_velocity = 0, 0;
    return true;
}

// The camera: where the eye is, the sector it's in, yaw and pitch in angle units. The eye
// is over the feet by the height, less the bob; its sector is the player object's, as the
// original's camera takes it.
world_get_camera :: () -> Vector3, s32, float, float {
    p := *world.player;
    eye := Vector3.{fixed_to_float(p.position.x), fixed_to_float(p.position.y + p.bob - p.height), fixed_to_float(p.position.z)};
    return eye, p.sector, cast(float) p.object_yaw, cast(float) p.pitch;
}

#scope_module

PLAYER_WIDTH  :Fixed: 0x1CCCC;      // 1.8
PLAYER_HEIGHT :Fixed: 0x5CCCC;      // 5.8
PLAYER_STEP   :Fixed: 0x38000;      // 3.5
NO_STEP_LIMIT :Fixed: 0x270F0000;   // 9999, with the height check off.
BUG_SIZE      :Fixed: 0x4CCC;       // 0.3: insect mode's width and least eye height.

start_player :: () {
    p := *world.player;
    p.* = .{};
    for * world.level_objects.objects {
        // Usually a SPIRIT, but any class can be the player (FUELSTAT's is a 3D object).
        if !has_logic(it, "PLAYER") continue;
        p.position = it.position;
        p.yaw = it.yaw & ANGLE_MASK;
        break;
    }
    p.sector = level_find_sector(*world.level, p.position);
    if p.sector < 0 && world.level.sectors {
        // No start found: the middle of the first sector, on its floor.
        s := *world.level.sectors[0];
        p.position = .{(s.bounds_min.x + s.bounds_max.x) / 2, s.floor.altitude, (s.bounds_min.z + s.bounds_max.z) / 2};
        p.sector = 0;
    }
    // Starts are placed in the air and fall to the floor, as in the original: some levels
    // count on the landing (Secret Base's bars open on it).
    if p.sector >= 0 {
        floor, _ := get_floor_and_ceiling(*world.level.sectors[p.sector], p.position.y);
        p.position.y = min(p.position.y, floor);
    }
    p.object_yaw = p.yaw;
    p.y = p.position.y;
    p.floor_sector = p.sector;
}

// One tick of the game's timer (0x2f9ec).
tick_player :: (input: World_Input) {
    p := *world.player;
    if p.sector < 0 || p.frozen return;
    if !world.player_state.dying {
        turn := (TICK_TURN << p.run) >> p.slow;
        if input.turn_right  p.yaw += turn;
        if input.turn_left   p.yaw -= turn;
    }
    v := p.tick_up_velocity + TICK_GRAVITY;
    p.tick_up_velocity = v;
    // y + v / 145.65, by shifts.
    p.y += (v >> 15) + ((v >> 7) - (v >> 10));
}

// One frame of the player task (0x2ab28): the controls, the physics, the battery, and dying.
update_player :: (input: World_Input) {
    p := *world.player;
    if p.sector < 0 return;
    s := *world.player_state;
    if p.frozen {
        p.frozen = false;
        safe := find_safe(p.sector);
        if safe { s.safe = safe.*; s.has_safe = true; }
    }
    read_controls(p, input);
    update_physics(p);
    update_battery();
    // The use key acts once a press (0x2e418).
    if input.use && !p.use_held  use_key(p);
    p.use_held = input.use;
    pass_fire_keys(input.fire, input.fire_secondary);
    if !s.dying  pass_weapon_keys(input.weapon_keys);
    update_screen_effects();
    if s.dying  update_dying(p, input);
    p.last_tick = world.clock.frame_tick;
}

PITCH_LIMIT     :s32: 0x7FF;
MOUSE_TURN      :: 8.0;             // Angle units a mouse count.

#scope_file

TICK_TURN    :s32: 34;              // Angle units a tick turning by the keys.
TICK_GRAVITY :Fixed: 0x107A5;       // 150 units/s/s over 145.65 ticks.

FORWARD_SPEED   :Fixed: 256 * FIXED_ONE;
STRAFE_SPEED    :Fixed: 192 * FIXED_ONE;
CROUCH_SPEED    :Fixed: 0xB6664;    // 11.4
JUMP_SPEED      :Fixed: -0x2B8000;  // -43.5
KEY_PITCH_SPEED :Fixed: 0xD55;      // Angle units a second (3413).

FRICTION        :Fixed: 0xF999;     // 0.975 a tick.
FRICTION_AIR    :Fixed: 0xFEF9;
FRICTION_ICE    :Fixed: 0xFFBE;
FRICTION_CLEATS :Fixed: 0xF333;     // On snow, or wearing cleats.
ICE_PUSH        :Fixed: 0x11EB;     // What's left of a push on ice.
STOP_SPEED      :Fixed: FIXED_HALF;

LAND_SPEED_KNEE   :Fixed: 60 * FIXED_ONE;
LAND_SQUASH_MAX   :Fixed: 1000 * FIXED_ONE;
FALL_DAMAGE_SPEED :Fixed: 107 * FIXED_ONE;
WATER_MAX_MOVE    :Fixed: 25 * FIXED_ONE;
DRY_MAX_MOVE      :Fixed: 32 * FIXED_ONE;
BOB_HEIGHT        :Fixed: 0xC000;   // 0.75
BOB_WATER         :Fixed: 0x3000;

// The frame's controls (0x2ad50, 0x2b1a8): pushes scaled by the frame's time, run and
// walk shifts, crouching and jumping on the floor, looking up and down.
read_controls :: (p: *Player, input: World_Input) {
    dt := world.clock.dt;
    p.yaw_speed = 0;
    p.forward, p.strafe = 0, 0;
    p.slow, p.run, p.jump_scale = 0, 0, 0;
    if world.player_state.dying return;
    p.crouch_speed = p.rise_speed;

    push := mul16(dt, FORWARD_SPEED);
    if input.forward  p.forward = max(p.forward, push);
    if input.back     p.forward = min(p.forward, -push);
    if input.run   p.run |= 1;
    if input.walk  p.slow |= 1;
    if input.crouch && p.on_floor  p.crouch_speed = (CROUCH_SPEED << p.run) >> p.slow;
    if input.jump {
        if p.on_floor && !p.jump_held {
            play_player_sound(.JUMP);
            p.up_velocity = JUMP_SPEED << p.jump_scale;
            p.tick_up_velocity = p.up_velocity;
            p.jump_held = true;
        }
    } else {
        p.jump_held = false;
    }
    look := (mul16(dt, KEY_PITCH_SPEED) << p.run) >> p.slow;
    if input.look_up    p.pitch = clamp(p.pitch + look, -PITCH_LIMIT, PITCH_LIMIT);
    if input.look_down  p.pitch = clamp(p.pitch - look, -PITCH_LIMIT, PITCH_LIMIT);
    if input.center_view { p.pitch = 0; p.roll = 0; }
    side := mul16(dt, STRAFE_SPEED);
    if input.right  p.strafe = max(p.strafe, side);
    if input.left   p.strafe = min(p.strafe, -side);

    // The mouse turns and looks by its motion. (The original's mouse look set the pitch from
    // the mouse's position; that and its scale are the host's here.)
    mouse_turn := cast(float) input.mouse_x * MOUSE_TURN + mouse_rest.x;
    turn := cast(s32) mouse_turn;
    mouse_rest.x = mouse_turn - turn;
    p.yaw += turn;
    if input.mouse_y != 0 {
        d := input.mouse_y * MOUSE_TURN;
        d = atan(d / PITCH_LIMIT * PI) / PI * PITCH_LIMIT + mouse_rest.y;
        look := cast(s32) d;
        mouse_rest.y = d - look;
        p.pitch = clamp(p.pitch - look, -PITCH_LIMIT, PITCH_LIMIT);
    }

    // In the air the push all but goes.
    if p.up_velocity != 0 {
        p.forward >>= 8;
        p.strafe >>= 8;
    }
}

mouse_rest: Vector2;

update_physics :: (p: *Player) {
    dt := world.clock.dt;
    start_sector := p.sector;
    p.in_water = false;
    floor_sector := *world.level.sectors[p.floor_sector];

    friction: Fixed;
    if p.up_velocity == 0 {
        flags := floor_sector.flags[0];
        if (flags & SECTOR_ICE) && !world.player_state.cleats_on {
            friction = FRICTION_ICE;
            p.run = 0;
        } else if (flags & SECTOR_SNOW) || world.player_state.cleats_on {
            friction = FRICTION_CLEATS;
        } else {
            friction = FRICTION;
            if floor_sector.second_altitude - 1 >= 0 {
                p.run = 0;
                p.in_water = true;
            }
        }
    } else {
        friction = FRICTION_AIR;
    }
    // Friction, once for each tick since the last frame, at most 145.
    ticks := min(world.clock.frame_tick - p.last_tick, 145);
    if p.velocity.x || p.velocity.z {
        for 1..ticks  p.velocity = .{mul16(p.velocity.x, friction), mul16(p.velocity.z, friction)};
        if dist_approx(0, 0, p.velocity.x, p.velocity.z) < STOP_SPEED  p.velocity = .{};
    }

    // A moving floor under the player carries it (scrolling floors, walls moving): water's
    // surface less. The original adds the second elevator's angular speed to z, not its z
    // (always 0, as nothing in Dark Forces turns that way).
    p.on_moving_surface = 0;
    first := true;
    if p.position.y == floor_sector.floor.altitude || floor_sector.floor.altitude + floor_sector.second_altitude == p.position.y {
        for l: world.inf.sector_links[p.floor_sector] {
            link := *world.inf.links[l];
            if link.type != .ELEVATOR || !link.alive continue;
            e := *world.inf.elevators[link.target];
            on := ifx p.position.y == floor_sector.floor.altitude then (e.flags & ELEVATOR_MOVES_FLOOR) else (e.flags & ELEVATOR_MOVES_SECOND);
            if !on continue;
            v := get_elevator_velocity(e);
            if floor_sector.second_altitude != 0 && floor_sector.second_altitude >= 0 {
                v = .{mul16(v.x, 0xCCCC), mul16(v.z, 0xCCCC)};
            }
            if v.x || v.z {
                p.on_moving_surface = 1;
                if first {
                    p.external = v;
                    first = false;
                } else {
                    p.external.x += v.x;
                }
            }
        }
    }

    if p.forward || p.strafe {
        if (world.level.sectors[p.sector].flags[0] & SECTOR_ICE) && !world.player_state.cleats_on {
            p.forward = mul16(p.forward, ICE_PUSH);
            p.strafe = mul16(p.strafe, ICE_PUSH);
        }
        forward := (((p.forward << p.run) >> p.slow) >> p.on_moving_surface) << p.jump_scale;
        add_move_from_angle(*p.velocity.x, *p.velocity.z, p.object_yaw, forward);
        strafe := ((p.strafe << p.run) >> p.slow) >> p.on_moving_surface;
        add_move_from_angle(*p.velocity.x, *p.velocity.z, cast,no_check(s16) (p.object_yaw + 0xFFF), strafe);
        limit_vector_length(*p.velocity.x, *p.velocity.z, p.max_move);
    }
    vx := (((p.velocity.x << p.run) >> p.slow) >> p.on_moving_surface) << p.jump_scale;
    vz := (((p.velocity.z << p.run) >> p.slow) >> p.on_moving_surface) << p.jump_scale;
    p.move = .{mul16(vx, dt) + mul16(p.external.x, dt), mul16(vz, dt) + mul16(p.external.z, dt)};
    // LAPOGO takes the step height off, LABUG makes the player small (0x2d17c).
    p.step = ifx cheats.height_check then PLAYER_STEP else NO_STEP_LIMIT;
    p.width = ifx cheats.bug then BUG_SIZE else PLAYER_WIDTH;

    // Up to four tries, each sliding along what the last hit.
    c := *world.collision;
    moved, collided := false, false;
    slide: Fixed2;
    p.slide_wall = null;
    for 1..4 {
        if collide_player_move(c, p, *p.move) {
            // The original tests the vertical move here, not the move along z.
            if p.move.x || p.move_y  moved = true;
            break;
        }
        collided = true;
        if !c.responds break;
        if c.wall  p.slide_wall = c.wall;
        slide = c.response_dir;
    }
    if moved {
        if collided {
            along := mul16(p.velocity.x, slide.x) + mul16(p.velocity.z, slide.z);
            p.velocity = .{mul16(along, slide.x), mul16(along, slide.z)};
            if p.external.x || p.external.z {
                along = mul16(p.external.x, slide.x) + mul16(p.external.z, slide.z);
                p.external = .{mul16(along, slide.x), mul16(along, slide.z)};
            }
        }
        moved = move_player_along_path(p, p.move);
        if moved  on_player_moved(p);
    }
    if !moved {
        c.dst = .{p.position.x, p.position.z};
        search_collision(c, p.sector);
        p.velocity, p.move = .{}, .{};
    }
    p.floor_sector = c.floor_sector;
    floor_sector = *world.level.sectors[p.floor_sector];

    if p.external.x || p.external.z {
        for 1..ticks  p.external = .{mul16(p.external.x, FRICTION), mul16(p.external.z, FRICTION)};
        if dist_approx(0, 0, p.external.x, p.external.z) < STOP_SPEED  p.external = .{};
    }

    // A wall of its sector moved or turned: the sector holding the player is found again.
    if world.inf.player_walls_moved {
        world.inf.player_walls_moved = false;
        sector := level_find_sector(*world.level, p.position);
        if sector >= 0 && sector != p.sector  change_player_sector(p, sector);
    }

    if p.sector != start_sector  on_player_entered_sector(p, start_sector);

    p.object_yaw = p.yaw & ANGLE_MASK;
    if p.yaw_speed {
        p.yaw_speed = mul16(p.yaw_speed, dt);
        p.object_yaw = cast,no_check(s16) (p.object_yaw + ((p.yaw_speed << p.run) >> p.slow));
    }

    // A long way to fall: a scream (the floor under the sector it last stood over).
    s := *world.player_state;
    under, _ := get_floor_and_ceiling(floor_sector, p.position.y);
    if under - p.position.y > 55 * FIXED_ONE && p.tick_up_velocity > 60 * FIXED_ONE && !s.scream && !s.dying {
        s.scream = play_player_sound(.FALL);
    }

    // Falling and landing. The ticks have moved y and its speed; the frame takes them.
    lowest, highest := c.lowest_floor, c.highest_ceiling;
    p.up_velocity = p.tick_up_velocity;
    p.move_y = p.y - p.position.y;
    p.position.y = p.y;
    if p.y < lowest {
        if p.y - p.height - FIXED_ONE < highest {
            // The head meets the ceiling.
            p.tick_up_velocity = max(p.tick_up_velocity, 0);
            p.y = min(highest + p.height + FIXED_ONE, lowest);
            p.up_velocity = p.tick_up_velocity;
            p.position.y = p.y;
        }
    } else {
        if s.scream { stop_sound(s.scream); s.scream = 0; }
        if p.fallen == 0 {
            // A step up: the feet go up, the eye stays where it was and rises after.
            if p.move_y < p.position.y - lowest  p.height += (c.bot - p.position.y) + p.move_y;
        } else {
            landed_in := *world.level.sectors[c.floor_sector];
            if landed_in.second_altitude - 1 >= 0  play_player_sound(.SPLASH);
            else if p.fallen > 4 * FIXED_ONE        play_player_sound(.LAND);
            send_landed(c.floor_sector);
            v := p.up_velocity;
            p.land_squash = v >> 2;
            if v >= LAND_SPEED_KNEE  p.land_squash -= (v - LAND_SPEED_KNEE) >> 3;
            if p.land_squash > LAND_SQUASH_MAX - 1  p.land_squash = LAND_SQUASH_MAX;
            p.land_velocity = v;
        }
        p.y = lowest;
        p.position.y = lowest;
        p.up_velocity = p.tick_up_velocity;
        if p.tick_up_velocity > 0 {
            p.up_velocity, p.tick_up_velocity = 0, 0;
        }
    }

    // The eye: crouching or rising, squashed after a landing, kept off the ceiling.
    p.height -= mul16(p.crouch_speed, dt);
    if p.land_squash {
        p.height -= mul16(p.land_squash, dt);
        p.land_squash = max(p.land_squash - mul16(dt, 20 * FIXED_ONE), 0);
    } else {
        p.land_velocity = 0;
    }
    room := max(p.position.y - highest, 0);
    room -= min(room, FIXED_ONE);
    room = min(room, PLAYER_HEIGHT);
    min_eye := ifx cheats.bug then BUG_SIZE else p.min_eye;
    second := world.level.sectors[p.sector].second_altitude;
    lowest_eye := ifx second < 0 then 0 else second + 0x4000;
    lowest_eye = max(lowest_eye, min_eye);
    if p.height < lowest_eye {
        if p.land_squash && p.land_velocity > FALL_DAMAGE_SPEED {
            on_player_fall_damage(p, (p.land_velocity - FALL_DAMAGE_SPEED) * 2);
            p.land_velocity = 0;
        }
        p.height = lowest_eye;
    }
    if room < p.height  p.height = room;
    if p.height < min_eye {
        if !s.crush_sound  s.crush_sound = play_player_sound(.CRUSH);
        on_player_crushed(p);
        p.height = lowest_eye;
    } else if s.crush_sound {
        stop_sound(s.crush_sound);
        s.crush_sound = 0;
    }
    // Not as an insect: it keeps the last.
    if !cheats.bug  p.max_move = (ifx p.in_water then WATER_MAX_MOVE else DRY_MAX_MOVE) - (PLAYER_HEIGHT - p.height) * 4;

    // The head bob, by the walking speed: a cosine of the tick, and a slower sway for the
    // weapon.
    speed := dist_approx(0, 0, p.velocity.x, p.velocity.z);
    if !moved  speed = 0;
    if (floor_sector.flags[0] & SECTOR_ICE) && !world.player_state.cleats_on  speed = 0;
    if speed != p.speed_average {
        change := speed - p.speed_average;
        limit := mul16(dt, 32 * FIXED_ONE);
        change = clamp(change, -limit, limit);
        p.speed_average += change;
    }
    tick := world.clock.tick;
    _, cosine := sin_cos(tick << 7);
    fraction := div16(p.speed_average, 32 * FIXED_ONE);
    p.bob = mul16(fraction, mul16(cosine, BOB_HEIGHT));
    _, cosine = sin_cos(tick << 6);
    p.weapon_wave = mul16(fraction, cosine) >> 12;
    if floor_sector.second_altitude - 1 >= 0 && (p.external.x || p.external.z) {
        _, cosine = sin_cos(tick << 4);
        p.bob += mul16(cosine, BOB_WATER);
    }

    if lowest == p.position.y {
        p.on_floor = true;
        p.fallen = 0;
    } else {
        p.on_floor = false;
    }
    apply_floor_damage(p);

    // The feet between the floor and ceiling found, the eye between the sector's.
    if lowest < p.position.y {
        p.y = lowest;
        p.position.y = lowest;
    }
    if p.position.y < highest {
        p.y = highest;
        p.position.y = highest;
    }
    eye_top := p.position.y - c.ext_ceiling;
    eye_bottom := p.position.y - (c.ext_floor - 0x4000);
    if eye_top < p.height - p.bob  p.height = eye_top + p.bob;
    if p.height - p.bob < eye_bottom  p.height = eye_bottom + p.bob;

    p.fallen = max(lowest - p.position.y, p.fallen);
}

#scope_module

change_player_sector :: (p: *Player, sector: s32) {
    from := p.sector;
    p.sector = sector;
    if from != sector  send_sector_events(from, sector);
}

on_wall_crossed :: (wall: *Wall, sector: s32) {
    send_wall_crossed(sector, xx (wall - world.level.sectors[sector].walls.data));
}

on_player_fall_damage :: (p: *Player, damage: Fixed) {
    apply_damage(damage, 0, false);
}

on_player_crushed :: (p: *Player) {
    apply_damage(0, mul16(world.clock.dt, 10 * FIXED_ONE), false);
    send_crush(*world.collision, p);
}

play_player_sound :: (sound: Player_Sound) -> Sound_Instance {
    return play_sound(world.player_sounds[sound]);
}

// The player's sounds and their priorities (0x29480).
register_player_sounds :: () {
    NAMES :: string.["JUMP-1.VOC", "LAND-1.VOC", "SWIM-IN.VOC", "FALL.VOC", "CRUSH.VOC", "HEALTH1.VOC", "KYLEDIE1.VOC", "SHIELD1.VOC",
                     "GOGGLES1.VOC", "GOGGLES2.VOC", "MASK1.VOC", "MASK2.VOC", "CHOKE.VOC"];
    PRIORITIES :: s32.[0x7B, 0x7B, 0x7B, 0x50, 0x7B, 0x7B, 0x7F, 0x54, 0x48, 0x48, 0x48, 0x48, 0x48];
    for NAMES  world.player_sounds[it_index] = register_sound(it, PRIORITIES[it_index]);
}

#scope_file

float_to_fixed :: (f: float) -> Fixed { return cast(Fixed) (f * 65536.0); }
