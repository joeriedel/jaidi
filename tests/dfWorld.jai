// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Levels played without a screen: a retail level loaded, input given frame by frame on the
// fixed two-tick step, and the results checked. Every frame also checks what must always
// hold (check_world): the player is inside the sector it's counted in, between its floor and
// ceiling, with health in range.

secbase_start_bars_open_on_landing :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    // The start drops the player to the floor; the landing opens the bars ahead, and walking
    // on goes through them into the corridor.
    face(180);
    if !run(150, .{forward = true}) return;
    p := world_get_player();
    check(p.sector == 172, "through the bars: in sector %, at %", p.sector, at(p));
} @test

// Out of Secret Base's front door into the open: crossing into sector 196 must stick (the
// path walk once crossed straight back through the opening's other side).
secbase_walk_into_the_open :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(237.8, 4, 218.34, 166) return;
    if !run(150, .{forward = true}) return;
    p := world_get_player();
    check(p.sector == 196, "out in the open: in sector %, at %", p.sector, at(p));
    if !place(235, 4, 200, 290) return;
    run(300, .{forward = true});
} @test

// A frame runs the tasks in the order the original's scheduler takes its task tree: the
// player, the ring's other tasks in the order made (LOGIC: UPDATE's first in Secret Base's
// O file), then the level task's children, its objects' last made first (five mousebots and
// Kyle's ship's path), then the init's in reverse, the weapon last, then the main loop.
secbase_task_order :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    order := world_get_task_order();
    expected := Task_Kind.[.PLAYER, .UPDATE_LOGICS, .SPRITE_ANIMATIONS, .ROOT, .MOUSEBOT, .MOUSEBOT, .VUE,
        .MOUSEBOT, .MOUSEBOT, .MOUSEBOT, .MUSIC, .HIT_EFFECTS, .FREE_MOVES, .ACTORS, .TRIGGERS, .TELEPORTERS,
        .PICKUPS, .ELEVATORS, .PROJECTILES, .WEAPON, .TEXTURES, .LEVEL, .MAIN];
    same := order.count == expected.count;
    for expected  if same && order[it_index] != it  same = false;
    check(same, "the frame's order is %", order);
} @test

// A sector's objects are slots (0x59ec4): a punch that runs out empties its slot, and the
// next object into the sector takes it, ahead of a mine that came in after the punch.
secbase_sector_slot_reused :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(162.5, -0.07, 332, 270) return;
    at := Fixed3.{255 * FIXED_ONE, -FIXED_ONE, 243 * FIXED_ONE};
    punch := launch(.PUNCH, at, 0, 0);
    mine := launch(.LAND_MINE_PLACED, at, 0, 0);
    if !check(punch >= 0 && mine >= 0, "nothing launched") return;
    sector := world_get_objects()[punch].sector;
    find_slot :: (sector: s32, object: s32) -> int {
        for world_get_sector_slots(sector)  if it == object return it_index;
        return -1;
    }
    punch_slot := find_slot(sector, punch);
    mine_slot := find_slot(sector, mine);
    if !check(punch_slot >= 0 && punch_slot < mine_slot, "the punch in slot %, the mine in %", punch_slot, mine_slot) return;
    for 1..60 {
        if !is_projectile(punch) break;
        if !run(1, .{}) return;
    }
    if !check(!is_projectile(punch) && is_projectile(mine), "the punch is still there, or the mine isn't") return;
    second := launch(.LAND_MINE_PLACED, at, 0, 0);
    check(find_slot(sector, second) == punch_slot, "the second mine is in slot %, not the punch's %", find_slot(sector, second), punch_slot);
} @test

// Test Base's ship takes off along its VUE path one frame every 9 ticks, as in the
// original; Enhanced Mode draws it between its frames by the clock, so the drawn ship moves
// in steps smaller than the path's while the logic keeps the original's frames.
testbase_ship_drawn_between_frames :: () {
    skip_without_dark();
    if !start_level("TESTBASE") return;
    defer world_unload();
    ship := find_object_with_logic("KEY");
    if !check(ship >= 0, "no ship") return;
    o := world_get_objects()[ship];
    distance :: (a: Fixed3, b: Fixed3) -> Fixed { return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z); }
    between := 0;
    path_step, drawn_step: Fixed;
    last_path, last_drawn: Fixed3;
    for 1..300 {
        if !run(1, .{}) return;
        moving, drawn := world_get_vue_in_between(ship);
        if !moving continue;
        if !is_same_place(drawn, o.position)  between += 1;
        if it > 1 {
            path_step = max(path_step, distance(o.position, last_path));
            drawn_step = max(drawn_step, distance(drawn, last_drawn));
        }
        last_path, last_drawn = o.position, drawn;
    }
    if !check(between > 0 && path_step > 0, "never drawn between frames (% times), the path's step %", between, path_step / 65536.0) return;
    check(drawn_step < path_step, "the drawn ship's biggest step is %, the path's %", drawn_step / 65536.0, path_step / 65536.0);
} @test

// The switch beside the front door opens it: it rises 12.5 units.
secbase_switch_opens_front_door :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(255, -0.07, 243, 180) return;
    if !run(5, .{}) return;
    if !run(1, .{use = true}) return;
    if !run(200, .{}) return;
    level := world_get_level();
    door := find_sector_named(level, "frontdoor");
    if !check(door >= 0, "no frontdoor sector")  return;
    s := *level.sectors[door];
    check(s.floor.altitude - s.ceiling.altitude == 0xC8000, "the front door is % units open", (s.floor.altitude - s.ceiling.altitude) / 65536.0);
} @test

// A door closing over a thrown mine clears it away and shuts, rather than turning back:
// corpses, pickups that can go and these mines don't hold an elevator up (0x5cf44). The
// front door starts closing about 820 frames after its switch; the mine is thrown into it
// a little before, so it isn't armed yet.
secbase_door_closes_over_mine :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(255, -0.07, 243, 180) return;
    if !run(5, .{}) return;
    if !run(1, .{use = true}) return;
    if !run(700, .{}) return;
    level := world_get_level();
    door := find_sector_named(level, "frontdoor");
    s := *level.sectors[door];
    mine := launch(.LAND_MINE_PROXIMITY, .{238 * FIXED_ONE, -FIXED_ONE, 230 * FIXED_ONE}, 0, 90);
    if !place(162.5, -0.07, 332, 270) return;
    if !run(60, .{}) return;
    o := world_get_objects()[mine];
    if !check(is_projectile(mine) && o.sector == door, "the mine isn't in the doorway: sector %, at (%, %, %)", o.sector, o.position.x / 65536.0, o.position.y / 65536.0, o.position.z / 65536.0) return;
    if !run(200, .{}) return;
    check(s.floor.altitude == s.ceiling.altitude, "the door is % units open", (s.floor.altitude - s.ceiling.altitude) / 65536.0);
    check(!is_projectile(mine), "the mine is still there");
} @test

// The lift's switch carries the player up to its top stop.
secbase_lift_carries_player :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(162.5, -0.07, 332, 270) return;
    if !run(5, .{}) return;
    if !run(1, .{use = true}) return;
    if !run(250, .{}) return;
    p := world_get_player();
    check(p.position.y == -20 * FIXED_ONE && p.sector == 81, "on the lift at %, sector %", at(p), p.sector);
} @test

// The detention center's shuttle, a sliding wall elevator, carries what stands on its deck,
// a trooper and a 3D model, as far as its walls go (0x5c3c4).
dtention_shuttle_carries_objects :: () {
    skip_without_dark();
    if !start_level("DTENTION") return;
    defer world_unload();
    level := world_get_level();
    shuttle := find_sector_named(level, "shuttle");
    if !check(shuttle >= 0, "no shuttle sector") return;
    s := *level.sectors[shuttle];
    deck := s.floor.altitude + s.second_altitude;
    carried: [..] s32;
    starts: [..] Fixed3;
    for world_get_objects()  if it.used && it.sector == shuttle && it.position.y == deck {
        array_add(*carried, xx it_index);
        array_add(*starts, it.position);
    }
    if !check(carried.count == 2, "% objects on the shuttle's deck", carried.count) return;
    v0 := s.vertices[s.walls[0].left];
    world_send_inf_message(shuttle, .NEXT_STOP);
    if !run(900, .{}) return;
    v1 := s.vertices[s.walls[0].left];
    dx, dz := v1.x - v0.x, v1.z - v0.z;
    if !check(dx != 0 || dz != 0, "the shuttle didn't move") return;
    for carried {
        o := world_get_objects()[it];
        mx, mz := o.position.x - starts[it_index].x, o.position.z - starts[it_index].z;
        check(mx == dx && mz == dz, "object % moved (%, %), the shuttle (%, %)", it, mx / 65536.0, mz / 65536.0, dx / 65536.0, dz / 65536.0);
    }
} @test

// The security base's spinner turns half round, and a mine lying on it goes with it, about
// the center, turned itself (0x5c29c).
secbase_spinner_turns_mine :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(255, -0.07, 243, 180) return;
    level := world_get_level();
    spinner := find_sector_named(level, "spinner");
    if !check(spinner >= 0, "no spinner sector") return;
    s := *level.sectors[spinner];
    at := Fixed3.{0, s.floor.altitude - FIXED_ONE, 0};
    for r: 2..30 {
        at.x, at.z = cast(s32) (350 + r) * FIXED_ONE, 350 * FIXED_ONE;
        if level_find_sector(level, at) == spinner break;
    }
    if !check(level_find_sector(level, at) == spinner, "no place on the spinner") return;
    mine := launch(.LAND_MINE_PLACED, at, -90, 0);
    if !run(30, .{}) return;
    o := world_get_objects()[mine];
    if !check(o.sector == spinner && o.position.y == s.floor.altitude, "the mine lies in sector % at y %", o.sector, o.position.y / 65536.0) return;
    start, yaw := o.position, o.yaw;
    world_send_inf_message(spinner, .NEXT_STOP);
    w0 := s.vertices[s.walls[0].left];
    if !run(300, .{}) return;
    // The walls turn by whole steps, rounded, and needn't come to the stop's angle exactly.
    w1 := s.vertices[s.walls[0].left];
    wall_turn := atan2(w1.z / 65536.0 - 350, w1.x / 65536.0 - 350) - atan2(w0.z / 65536.0 - 350, w0.x / 65536.0 - 350);
    wall_steps := (cast(s32) (wall_turn / TAU * 16384 + 16384.5)) & 0x3FFF;
    turned := (yaw - o.yaw) & 0x3FFF;
    check(abs(turned - wall_steps) <= 1, "the mine turned % (of 16384), the walls %", turned, wall_steps);
    ex, ez := 700 * FIXED_ONE - start.x, 700 * FIXED_ONE - start.z;
    check(abs(o.position.x - ex) < FIXED_ONE / 8 && abs(o.position.z - ez) < FIXED_ONE / 8, "the mine is at (%, %), was at (%, %)", o.position.x / 65536.0, o.position.z / 65536.0, start.x / 65536.0, start.z / 65536.0);
    check(o.sector == spinner, "the mine is in sector %", o.sector);
} @test

// LOGIC: UPDATE spins the security base's 3D object at D_YAW: 50, read as 2275 angle units
// a second (50 x 45.5111, truncated): 31 a frame on the fixed two-tick step.
secbase_update_spins :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    spinning: *Object;
    for world_get_objects()  if it.used && it.update.on  spinning = it;
    if !check(spinning != null, "no UPDATE object") return;
    check(spinning.update.yaw_rate == 2275, "D_YAW: 50 read as %", spinning.update.yaw_rate);
    check(!(spinning.flags & OBJECT_MOVABLE), "an UPDATE object is left movable");
    yaw, pitch := spinning.yaw, spinning.pitch;
    if !run(100, .{}) return;
    check(((spinning.yaw - yaw) & 0x3FFF) == 3100, "it turned %", (spinning.yaw - yaw) & 0x3FFF);
    check(spinning.pitch == pitch, "it pitched");
} @test

// RAMSHED's D_ROLL: 999 doesn't fit 16 bits: 45465 becomes -20071, so its two 3D objects
// roll backward, as in the original.
ramshed_update_roll_wraps :: () {
    skip_without_dark();
    if !start_level("RAMSHED") return;
    defer world_unload();
    count := 0;
    for world_get_objects()  if it.used && it.update.on && it.update.roll_rate {
        check(it.update.roll_rate == -20071, "D_ROLL: 999 read as %", it.update.roll_rate);
        count += 1;
    }
    check(count == 2, "% rolling objects", count);
} @test

// A 65-unit fall: landing at about 140 units a second costs 2 x (speed - 107).
secbase_fall_damage :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(312.9, -45, 332.2, 0) return;
    if !run(120, .{}) return;
    a := world_get_agent();
    check(a.health == 33, "health after the fall: %", a.health);
} @test

// An energy pack gives 15, and is gone.
secbase_energy_pickup :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    energy := world_get_agent().ammo[0];
    if !place(269.21, -2, 341.05, 180) return;
    if !run(10, .{forward = true}) return;
    check(world_get_agent().ammo[0] == energy + 15, "energy % after the pack, was %", world_get_agent().ammo[0], energy);
} @test

// Test Base's start: the INF wakes Kyle's ship after two seconds and it takes off along
// WEAPON_T, about six seconds, while the player stands.
testbase_ship_takes_off :: () {
    skip_without_dark();
    if !start_level("TESTBASE") return;
    defer world_unload();
    ship := find_object_with_logic("KEY");
    if !check(ship >= 0, "no ship") return;
    start := world_get_objects()[ship].position;
    if !run(100, .{}) return;
    check(is_same_place(world_get_objects()[ship].position, start), "the ship moved before it was woken");
    if !run(700, .{}) return;
    p := world_get_objects()[ship].position;
    d := (p.x - start.x) / 65536.0;
    check(d > 100, "the ship is at (%, %, %), from (%, %, %)", p.x / 65536.0, p.y / 65536.0, p.z / 65536.0, start.x / 65536.0, start.y / 65536.0, start.z / 65536.0);
} @test

// Secret Base's ship waits, paused, for the end of the level.
secbase_ship_waits :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    ship := find_object_with_logic("KEY");
    if !check(ship >= 0, "no ship") return;
    start := world_get_objects()[ship].position;
    if !run(600, .{}) return;
    check(is_same_place(world_get_objects()[ship].position, start), "the ship moved");
} @test

// What an agent takes into a mission goes in and comes back out in the agent file's bytes.
agent_inventory_round_trip :: () {
    record := agent_get_blank_record();
    items, stats := record.items[0], record.stats[0];
    items[Agent_Items.RED_KEY] = 0xFF;
    items[Agent_Items.LIVES] = 5;
    stats[2] = 40;
    world_set_agent_inventory(items, stats);
    a := world_get_agent();
    check(a.items[1] == 0xFF && a.items[8] == 0xFF && a.lives == 5 && a.ammo[2] == 40 && a.battery == 0x20000, "agent %", a.*);
    back_items, back_stats := world_get_agent_inventory();
    check(memcmp(back_items.data, items.data, 32) == 0 && memcmp(back_stats.data, stats.data, 40) == 0, "came back as % and %", back_items, back_stats);
} @test

// Every level, walking straight from its start in eight directions, the world checked every
// frame. Doors and lifts opened on one walk stay as they are for the next.
every_level_walks :: () {
    skip_without_dark();
    LEVELS :: string.["SECBASE", "TALAY", "SEWERS", "TESTBASE", "GROMAS", "DTENTION", "RAMSHED",
                      "ROBOTICS", "NARSHADA", "JABSHIP", "IMPCITY", "FUELSTAT", "EXECUTOR", "ARC"];
    // Jabba's ship takes the agent's inventory.
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    for name: LEVELS {
        if !start_level(name) return;
        defer world_unload();
        if !run(60, .{}) continue;          // Fall to the floor first.
        start := world_get_player().position;
        for heading: 0..7 {
            if !place(start.x / 65536.0, start.y / 65536.0, start.z / 65536.0, heading * 45.0) break;
            if !run(30, .{}) break;         // Stand until the last walk's speed is gone.
            if !run(240, .{forward = true, run = true}) {
                print("    (% walking at % degrees)\n", name, heading * 45);
                break;
            }
        }
    }
} @test

// The officer behind the consoles sees the player across the room, wakes, calls for the
// fight music, walks and fires; his pistol bolts take 10 off the shields.
secbase_officer_shoots :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    officer := find_object_with_logic("I_OFFICER");
    actor := world_get_actor(xx officer);
    if !check(actor != null, "the officer has no actor") return;
    if !check(world_is_actor_idle(actor), "the officer starts awake") return;
    fired, alerted := false, false;
    for 1..300 {
        if !run(1, .{}) return;
        if world_get_projectile_count()  fired = true;
        for world_take_music_events()  if it.kind == .FIGHT  alerted = true;
    }
    check(!world_is_actor_idle(actor), "the officer didn't wake");
    check(alerted, "no alert for the fight music");
    check(fired, "the officer didn't fire");
    shields := world_get_agent().shields;
    check(shields < 100 && shields % 10 == 0, "shields after his shots: %", shields);
} @test

// One pistol bolt kills the officer: he dies where he stands, leaving his corpse and the
// energy he carried.
secbase_pistol_kills_officer :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    officer := find_object_with_logic("I_OFFICER");
    ammo := world_get_agent().ammo[0];
    if !run(2, .{fire = true}) return;
    if !run(150, .{}) return;
    check(world_get_agent().ammo[0] == ammo - 1, "energy % after one shot, from %", world_get_agent().ammo[0], ammo);
    check(world_get_actor(xx officer) == null, "the officer is still there");
    corpse, energy: *Object;
    for world_get_objects() {
        if !it.used || it.sector < 0 continue;
        if it.entity & ENTITY_CORPSE  corpse = it;
    }
    if !check(corpse != null, "no corpse") return;
    for world_get_objects() {
        if !it.used || it.sector < 0 || it.item != 11 continue;
        if abs(it.position.x - corpse.position.x) <= 2 * FIXED_ONE && abs(it.position.z - corpse.position.z) <= 2 * FIXED_ONE  energy = it;
    }
    check(energy != null, "no energy dropped by the corpse");
} @test

// Switching weapons as the original: the number key lowers the pistol over ten steps and
// raises the rifle; Backspace goes back; F10 and F9 step through what the agent has; F8
// holsters, and fire held brings the weapon back up and fires it once it's up (a press let go
// during the raise doesn't fire, as in the original).
secbase_weapon_switching :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    a := world_get_agent();
    a.items[Item_Slot.RIFLE] = -1;
    if !run(2, .{}) return;
    if !check(world_get_weapon() == WEAPON_PISTOL, "weapon % at the start", world_get_weapon()) return;

    if !run(1, number_key(3)) return;
    if !run(6, .{}) return;
    x, y := world_get_weapon_offset();
    check(world_get_weapon() == WEAPON_PISTOL && y > 0 && y < 40, "weapon % lowered to % six frames in", world_get_weapon(), y);
    if !run(20, .{}) return;
    x, y = world_get_weapon_offset();
    check(world_get_weapon() == WEAPON_RIFLE && x == 0 && y == 0, "weapon % at (%, %) after the switch", world_get_weapon(), x, y);

    world_swap_weapon();
    if !run(25, .{}) return;
    check(world_get_weapon() == WEAPON_PISTOL, "weapon % after Backspace", world_get_weapon());
    world_cycle_weapon(1);
    if !run(25, .{}) return;
    check(world_get_weapon() == WEAPON_RIFLE, "weapon % after F10", world_get_weapon());
    world_cycle_weapon(-1);
    if !run(25, .{}) return;
    check(world_get_weapon() == WEAPON_PISTOL, "weapon % after F9", world_get_weapon());

    world_holster_weapon();
    if !run(15, .{}) return;
    check(world_is_weapon_holstered(), "not holstered after F8");
    energy := a.ammo[Ammo.ENERGY];
    if !run(6, .{fire = true}) return;
    check(!world_is_weapon_holstered() && a.ammo[Ammo.ENERGY] == energy, "fire while holstered: holstered %, energy % from %", world_is_weapon_holstered(), a.ammo[Ammo.ENERGY], energy);
    if !run(10, .{fire = true}) return;
    check(a.ammo[Ammo.ENERGY] == energy - 1, "energy % once raised, from %", a.ammo[Ammo.ENERGY], energy);
} @test

// The rifle kills an officer with one shot, for two of energy.
secbase_rifle_kills_officer :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    world_give_weapon(WEAPON_RIFLE);
    officer := find_object_with_logic("I_OFFICER");
    energy := world_get_agent().ammo[Ammo.ENERGY];
    if !run(2, .{fire = true}) return;
    if !run(150, .{}) return;
    check(world_get_agent().ammo[Ammo.ENERGY] == energy - 2, "energy % after one shot, from %", world_get_agent().ammo[Ammo.ENERGY], energy);
    check(world_get_actor(xx officer) == null, "the officer is still there");
} @test

// A level left from the tools keeps the weapon in hand for the next, as a mission's end does.
next_level_starts_with_the_weapon_kept :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    world_give_weapon(WEAPON_RIFLE);
    if !run(60, .{}) { world_unload(); return; }
    world_keep_weapon();
    world_unload();
    if !start_level("TALAY") return;
    defer world_unload();
    if !run(60, .{}) return;
    check(world_get_weapon() == WEAPON_RIFLE, "weapon % in hand at the next start", world_get_weapon());
} @test

// The fists: three punches spread across the view, after the arm is drawn back; an officer
// in front is hurt.
secbase_fists_punch_officer :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    officer := find_object_with_logic("I_OFFICER");
    o := world_get_objects()[officer];
    if !place(o.position.x / 65536.0, o.position.y / 65536.0, o.position.z / 65536.0 - 4, 0) return;
    world_give_weapon(WEAPON_FIST);
    actor := world_get_actor(xx officer);
    if !check(actor != null, "no officer") return;
    hp := world_get_actor_hp(actor);
    if !run(2, .{fire = true}) return;
    if !run(10, .{}) return;
    actor = world_get_actor(xx officer);
    check(!actor || world_get_actor_hp(actor) < hp, "the officer's health % after a punch, from %", ifx actor then world_get_actor_hp(actor) else 0, hp);
} @test

// Out of energy with auto-switching on (Alt+F8): the pistol clicks, then the best weapon with
// ammo comes up, the fists with nothing else; off, the pistol stays.
secbase_weapon_auto_switch :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    a := world_get_agent();
    for * a.ammo  it.* = 0;
    if !run(2, .{fire = true}) return;
    if !run(40, .{}) return;
    check(world_get_weapon() == WEAPON_PISTOL, "weapon % with auto-switching off", world_get_weapon());
    world_toggle_weapon_auto_switch();
    defer world_toggle_weapon_auto_switch();
    if !run(2, .{fire = true}) return;
    if !run(40, .{}) return;
    check(world_get_weapon() == WEAPON_FIST, "weapon % with auto-switching on", world_get_weapon());
} @test

// Every weapon's fire as the original's takes its ammo: one press of each, primary and
// secondary.
secbase_weapons_take_ammo :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    a := world_get_agent();
    Case :: struct { weapon: s32; secondary: bool; ammo: Ammo; cost: s32; }
    CASES :: Case.[
        .{WEAPON_REPEATER, false, .POWER, 1},
        .{WEAPON_REPEATER, true, .POWER, 3},
        .{WEAPON_FUSION, false, .POWER, 1},
        .{WEAPON_FUSION, true, .POWER, 8},
        .{WEAPON_MORTAR, false, .SHELL, 1},
        .{WEAPON_CONCUSSION, false, .POWER, 4},
        .{WEAPON_CANNON, false, .PLASMA, 1},
        .{WEAPON_CANNON, true, .MISSILE, 1},
    ];
    for CASES {
        world_give_weapon(it.weapon);
        if !run(30, .{}) return;
        before := a.ammo[it.ammo];
        input: World_Input;
        if it.secondary  input.fire_secondary = true;
        else             input.fire = true;
        if !run(2, input) return;
        if !run(120, .{}) return;
        check(a.ammo[it.ammo] == before - it.cost, "weapon % (secondary %): ammo % from %, wanted % less", it.weapon, it.secondary, a.ammo[it.ammo], before, it.cost);
    }
} @test

// The thermal detonator: held back while fire is held, thrown when it's let go, going off
// where it first lands (the primary); out of them, the fists come up.
secbase_detonator_thrown :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    world_give_weapon(WEAPON_DETONATOR);
    a := world_get_agent();
    a.ammo[Ammo.DETONATOR] = 1;
    if !run(5, .{}) return;
    if !run(40, .{fire = true}) return;
    check(world_get_projectile_count() == 0, "% projectiles while held", world_get_projectile_count());
    check(a.ammo[Ammo.DETONATOR] == 0, "% detonators while one is held", a.ammo[Ammo.DETONATOR]);
    before: [..] s32;
    before.allocator = temp;
    for world_get_objects()  if is_projectile(xx it_index)  array_add(*before, xx it_index);
    if !run(2, .{}) return;
    thrown: s32 = -1;
    for world_get_objects()  if is_projectile(xx it_index) && !array_find(before, xx it_index)  thrown = xx it_index;
    if !check(thrown >= 0, "nothing thrown") return;
    check(run_until_gone(thrown, 150) >= 0, "the detonator hasn't gone off");
    if !run(2, .{fire = true}) return;
    if !run(40, .{}) return;
    check(world_get_weapon() == WEAPON_FIST, "weapon % after firing with no detonators", world_get_weapon());
} @test

// The mines: the hand goes down, a mine is set on the floor under the player, the hand
// comes back up.
secbase_mine_set :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    world_give_weapon(WEAPON_MINES);
    a := world_get_agent();
    mines := a.ammo[Ammo.MINE];
    if !run(5, .{}) return;
    if !run(2, .{fire_secondary = true}) return;
    if !run(50, .{}) return;
    check(a.ammo[Ammo.MINE] == mines - 1, "% mines after setting one, from %", a.ammo[Ammo.MINE], mines);
    check(world_get_projectile_count() == 1, "% projectiles after setting a mine", world_get_projectile_count());
    x, y := world_get_weapon_offset();
    check(y == 0, "the hand at % after setting the mine", y);
} @test

// A thermal detonator dropped on an officer: it bounces about at the officer's feet until
// its three seconds are up, and the blast kills it.
secbase_detonator_kills_officer :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    officer := find_object_with_logic("I_OFFICER");
    o := world_get_objects()[officer];
    if !check(launch(.THERMAL_DETONATOR, .{o.position.x, o.position.y - 2 * FIXED_ONE, o.position.z}, -90, 0) >= 0, "no detonator") return;
    if !run(200, .{}) return;
    check(world_get_actor(xx officer) != null, "the officer died before the blast");
    check(world_get_projectile_count() == 1, "% projectiles before the blast", world_get_projectile_count());
    if !run(60, .{}) return;
    check(world_get_projectile_count() == 0, "the detonator is still there");
    actor := world_get_actor(xx officer);
    check(!actor || world_get_actor_hp(actor) < FIXED_ONE, "the officer lived through the blast");
} @test

// The blast hurts the player too: half the damage, for a detonator.
secbase_detonator_hurts_player :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(269.21, -2, 341.05, 180) return;
    if !run(5, .{}) return;
    p := world_get_player();
    a := world_get_agent();
    before := a.shields + a.health;
    detonator := launch(.THERMAL_DETONATOR, .{p.position.x, p.position.y - 2 * FIXED_ONE, p.position.z + 4 * FIXED_ONE}, -90, 0);
    check(run_until_gone(detonator, 260) >= 0, "the detonator is still there");
    check(a.shields + a.health < before, "shields and health % after the blast, from %", a.shields + a.health, before);
} @test

// A proximity mine arms after its three seconds, then goes off a second later with the
// player beside it.
secbase_proximity_mine :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(269.21, -2, 341.05, 180) return;
    if !run(5, .{}) return;
    p := world_get_player();
    a := world_get_agent();
    before := a.shields + a.health;
    mine := launch(.LAND_MINE_PROXIMITY, .{p.position.x, p.position.y - FIXED_ONE, p.position.z + 6 * FIXED_ONE}, 0, 0);
    gone := run_until_gone(mine, 340);
    check(gone < 0 || gone > 260, "the mine went off before it was armed, on frame %", gone);
    check(gone >= 0, "the armed mine didn't go off");
    check(a.shields + a.health < before, "shields and health % after the mine, from %", a.shields + a.health, before);
} @test

// A placed mine waits for the player: one far off stays, one within 20 units goes off.
secbase_placed_mine :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(269.21, -2, 341.05, 180) return;
    if !run(5, .{}) return;
    p := world_get_player();
    a := world_get_agent();
    far := launch(.LAND_MINE_PLACED, .{p.position.x, p.position.y - FIXED_ONE, p.position.z - 40 * FIXED_ONE}, 0, 0);
    if !check(far >= 0, "no place for the far mine") return;
    if !run(100, .{}) return;
    check(world_get_projectile_count() == 1, "the far mine went off");
    before := a.shields + a.health;
    launch(.LAND_MINE_PLACED, .{p.position.x, p.position.y - FIXED_ONE, p.position.z + 10 * FIXED_ONE}, 0, 0);
    if !run(60, .{}) return;
    check(world_get_projectile_count() == 1, "% projectiles: the near mine didn't go off", world_get_projectile_count());
    check(a.shields + a.health < before, "shields and health % after the mine, from %", a.shields + a.health, before);
} @test

// A homing missile fired past the player turns onto it and goes off.
secbase_homing_missile :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(235, 4, 200, 0) return;
    if !run(5, .{}) return;
    p := world_get_player();
    a := world_get_agent();
    before := a.shields + a.health;
    // 40 units out in the open, aimed 15 degrees off the player.
    if !check(launch(.HOMING_MISSILE, .{p.position.x - 37 * FIXED_ONE, p.position.y - 3 * FIXED_ONE, p.position.z + 14 * FIXED_ONE}, 0, 125) >= 0, "no missile") return;
    if !run(300, .{}) return;
    check(world_get_projectile_count() == 0, "the missile is still flying");
    check(a.shields + a.health < before, "shields and health % after the missile, from %", a.shields + a.health, before);
} @test

// A blast beside an exploding wall opens it: its ceiling, down on its floor, goes up.
dtention_exploding_wall :: () {
    skip_without_dark();
    if !start_level("DTENTION") return;
    defer world_unload();
    level := world_get_level();
    sector := 116;
    s := *level.sectors[sector];
    if !check(s.ceiling.altitude == s.floor.altitude, "the wall is open before the blast") return;
    // Just over one of its openings, in the sector beyond.
    at: Fixed3;
    found := false;
    for * wall: s.walls {
        if wall.adjoin < 0 continue;
        a := s.vertices[wall.left];
        b := s.vertices[wall.right];
        mid := Fixed2.{(a.x + b.x) / 2, (a.z + b.z) / 2};
        for side: Fixed.[FIXED_ONE, -FIXED_ONE] {
            x := mid.x + mul16(side, wall.direction.z);
            z := mid.z - mul16(side, wall.direction.x);
            next := *level.sectors[wall.adjoin];
            at = .{x, next.floor.altitude - FIXED_ONE, z};
            if level_find_sector(level, at) == wall.adjoin { found = true; break; }
        }
        if found break;
    }
    if !check(found, "no opening beside sector %", sector) return;
    launch(.THERMAL_DETONATOR, at, -90, 0);
    if !run(240, .{}) return;
    check(s.ceiling.altitude < s.floor.altitude, "the wall is still shut: ceiling %, floor %", s.ceiling.altitude / 65536.0, s.floor.altitude / 65536.0);
} @test

// A Gamorrean guard close up wakes and swings its axe: 40 off health, no shots.
narshada_gamorrean_strikes :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("NARSHADA") return;
    defer world_unload();
    guard := find_object_with_logic("G_GUARD");
    if !face_object(guard, 6) return;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    placed := world_get_projectile_count();
    fired := false;
    for 1..900 {
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
        if a.health < 100 break;
    }
    check(a.health == 60, "health % after the axe", a.health);
    check(!fired, "the guard fired");
} @test

// A Ree-Yees farther off than its detonator's blast lobs one, aimed to come down by the
// player, where it goes off. Here the player is some 18 units below, and the original's aim,
// right on level ground, brings it down about 8 units short.
narshada_reeyees_lobs_detonator :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("NARSHADA") return;
    defer world_unload();
    REEYEES :: 54;
    if !check(has_logic(*world_get_level_objects()[REEYEES], "REE_YEES"), "object % isn't a Ree-Yees", REEYEES) return;
    if !face_object(REEYEES, 45) return;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    thrown := -1;
    last: Fixed3;
    for 1..400 {
        if !run(1, .{}) return;
        if thrown < 0 {
            for world_get_objects() {
                if !it.used || it.sector < 0 || !(it.entity & ENTITY_PROJECTILE) || (it.entity & ENTITY_LANDMINE) continue;
                thrown = xx it_index;
                last = it.position;
            }
        } else {
            o := world_get_objects()[thrown];
            if !(o.entity & ENTITY_PROJECTILE) break;
            last = o.position;
        }
    }
    if !check(thrown >= 0, "no detonator thrown") return;
    p := world_get_player();
    off := dist_approx(last.x, last.z, p.position.x, p.position.z);
    check(off < 12 * FIXED_ONE, "the detonator came down % units from the player", off / 65536.0);
    // The blast is dealt in the hit effects' turn, which comes before the projectiles': the
    // frame after the detonator goes.
    check(a.health == 100, "health % in the frame the detonator went", a.health);
    if !run(1, .{}) return;
    check(a.health < 100, "health % after the blast", a.health);
} @test

// Bossk fires his concussion rifle at the player.
narshada_bossk_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("NARSHADA") return;
    defer world_unload();
    BOSSK :: 133;
    if !check(has_logic(*world_get_level_objects()[BOSSK], "BOSSK"), "object % isn't Bossk", BOSSK) return;
    if !face_object(BOSSK, 45) return;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    placed := world_get_projectile_count();
    fired := false;
    for 1..400 {
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
    }
    check(fired, "Bossk didn't fire");
    check(a.health < 100, "health % after his shots", a.health);
} @test

// A probe droid wakes, rises or sinks toward the player's eye and fires.
dtention_probe_droid_flies_and_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("DTENTION") return;
    defer world_unload();
    DROID :: 90;
    if !check(has_logic(*world_get_level_objects()[DROID], "PROBE_DROID"), "object % isn't a probe droid", DROID) return;
    if !face_object(DROID, 25) return;
    o := world_get_objects()[DROID];
    start_y := o.position.y;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    placed := world_get_projectile_count();
    fired := false;
    flown: Fixed;
    for 1..400 {
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
        flown = max(flown, abs(o.position.y - start_y));
    }
    actor := world_get_actor(DROID);
    check(actor && !world_is_actor_idle(actor), "the droid didn't wake");
    check(flown >= FIXED_ONE, "the droid flew % units up or down", flown / 65536.0);
    check(fired, "the droid didn't fire");
    // Most shots miss; give them time to land one.
    for 1..800 {
        if a.health < 100 break;
        if !run(1, .{}) return;
    }
    check(a.health < 100, "health % after its shots", a.health);
} @test

// A training remote wakes, turns about, hovers toward the player and stings it.
dtention_remote_flies_and_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("DTENTION") return;
    defer world_unload();
    REMOTE :: 303;
    if !check(has_logic(*world_get_level_objects()[REMOTE], "REMOTE"), "object % isn't a remote", REMOTE) return;
    if !face_object(REMOTE, 25) return;
    o := world_get_objects()[REMOTE];
    start_y := o.position.y;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    placed := world_get_projectile_count();
    fired := false;
    flown: Fixed;
    for 1..400 {
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
        flown = max(flown, abs(o.position.y - start_y));
    }
    actor := world_get_actor(REMOTE);
    check(actor && !world_is_actor_idle(actor), "the remote didn't wake");
    check(flown >= FIXED_ONE, "the remote flew % units up or down", flown / 65536.0);
    check(fired, "the remote didn't fire");
    check(a.health < 100, "health % after its shots", a.health);
    check(!(o.entity & ENTITY_SMART), "the remote opens doors");
} @test

// An interrogation droid within 30 units stuns rather than fires: 5 off health a time.
sewers_interrogation_droid_stuns :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SEWERS") return;
    defer world_unload();
    DROID :: 94;
    if !check(has_logic(*world_get_level_objects()[DROID], "INT_DROID"), "object % isn't an interrogation droid", DROID) return;
    if !face_object(DROID, 25) return;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    placed := world_get_projectile_count();
    fired := false;
    for 1..400 {
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
        if a.health < 100 break;
    }
    check(a.health == 95, "health % after the first stun", a.health);
    check(!fired, "the droid fired");
} @test

// A sewer creature waits under the water, unseen; with the player at the edge it surfaces
// and strikes: 20 off health a strike. The enemies it wakes fire too, so health is put back
// every frame and a frame's loss looked at.
sewers_creature_surfaces_and_strikes :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SEWERS") return;
    defer world_unload();
    CREATURE :: 3;
    if !check(has_logic(*world_get_level_objects()[CREATURE], "SEWER1"), "object % isn't a sewer creature", CREATURE) return;
    o := world_get_objects()[CREATURE];
    if !check((o.flags & OBJECT_HIDDEN) != 0, "the creature starts in sight") return;
    if !face_object(CREATURE, 8) return;
    a := world_get_agent();
    struck := false;
    for 1..900 {
        a.health, a.shields = 100, 0;
        if !run(1, .{}) return;
        // A second creature nearby may strike on the same tick.
        if a.health == 80 || a.health == 60 { struck = true; break; }
    }
    check(struck, "no strike: health % in the last frame", a.health);
    check(!(o.flags & OBJECT_HIDDEN), "the creature struck unseen");
} @test

// A thermal detonator by a barrel blows it up; the barrel is gone once its blowing up has
// shown.
fuelstat_barrel_blows_up :: () {
    skip_without_dark();
    if !start_level("FUELSTAT") return;
    defer world_unload();
    barrel := find_object_with_logic("BARREL");
    actor := world_get_actor(barrel);
    if !check(actor != null, "the barrel has no actor") return;
    check(!world_is_actor_idle(actor), "the barrel is idle");
    o := world_get_objects()[barrel];
    if !check(launch(.THERMAL_DETONATOR, .{o.position.x, o.position.y - 2 * FIXED_ONE, o.position.z}, -90, 0) >= 0, "no detonator") return;
    if !run(400, .{}) return;
    check(world_get_actor(barrel) == null, "the barrel is still there");
    check(!world_get_objects()[barrel].used || world_get_objects()[barrel].actor == null, "the barrel's object kept its actor");
} @test

// Scenery broken by a blast leaves its broken action behind, as an object of its own.
secbase_scenery_breaks :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    scenery := find_object_with_logic("SCENERY");
    if !check(world_get_actor(scenery) != null, "the scenery has no actor") return;
    o := world_get_objects()[scenery];
    at := o.position;
    data := o.data;
    if !check(launch(.THERMAL_DETONATOR, .{at.x, at.y - 2 * FIXED_ONE, at.z}, -90, 0) >= 0, "no detonator") return;
    if !run(400, .{}) return;
    check(world_get_actor(scenery) == null, "the scenery is unbroken");
    broken := false;
    for world_get_objects() {
        if !it.used || it.sector < 0 || it.data != data || it.anim != 1 continue;
        if is_same_place(it.position, at)  broken = true;
    }
    check(broken, "nothing broken left behind");
} @test

// The level's land mines are placed mines with the barrel's damage; one goes off with the
// player beside it, actor and all.
dtention_land_mine :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("DTENTION") return;
    defer world_unload();
    mine := find_object_with_logic("LAND_MINE");
    l := world_get_level_objects()[mine];
    mines := world_get_projectile_count();
    if !check(mines > 0, "no mines placed") return;
    mine_object := -1;
    for world_get_objects() {
        if it.used && it.sector >= 0 && (it.entity & ENTITY_LANDMINE) && is_same_place(it.position, l.position)  mine_object = it_index;
    }
    if !check(mine_object >= 0, "no mine where the level puts one") return;
    if !check(world_get_actor(xx mine_object) != null, "the mine has no actor") return;
    if !place(l.position.x / 65536.0 + 5, l.position.y / 65536.0 - 1, l.position.z / 65536.0, 0) return;
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    if !run(200, .{}) return;
    check(world_get_projectile_count() < mines, "the mine didn't go off: % projectiles, from %", world_get_projectile_count(), mines);
    check(a.health < 100, "health % after the mine", a.health);
    check(!world_get_objects()[mine_object].used || world_get_objects()[mine_object].actor == null, "the mine's actor outlived it");
} @test

// Talay's generators wait for the INF's MASTER_ON (sent as the ship takes off). This one, in
// gen4, then sends out a trooper every 2 s while the player is 70 to 200 units off and out of
// its sight, at most 4 at once and 4 in all. Each comes out awake, 7 units tall, in the
// generator's art; the generator itself is out of sight.
talay_generator_sends_troopers :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("TALAY") return;
    defer world_unload();
    GENERATOR :: 329;
    l := *world_get_level_objects()[GENERATOR];
    if !check(has_logic(l, "GENERATOR"), "object % isn't a generator", GENERATOR) return;
    g := world_get_objects()[GENERATOR];
    check(g.class == .SPIRIT && !g.width && (g.entity & ENTITY_GENERATOR) != 0, "the generator is still about: class %, width %", g.class, g.width);
    if !place(335.35, -2, 63, 0) return;
    a := world_get_agent();
    is_generated :: (o: *Object) -> bool { return o.used && o.actor && o.actor.generator >= 0; }
    // An enemy moves in the frame it comes out: the actors run after the generators.
    is_at_generator :: (o: *Object, g: *Object) -> bool { return dist_approx(o.position.x, o.position.z, g.position.x, g.position.z) < 2 * FIXED_ONE; }
    if !run(400, .{}) return;
    for world_get_objects() {
        if is_generated(it) && is_at_generator(it, g) { check(false, "an enemy came out before MASTER_ON"); return; }
    }

    world_send_sector_message(g.sector, .MASTER_ON);
    out: [..] s32;
    total, first := 0, -1;
    for 1..1200 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        now: [..] s32;
        now.allocator = temp;
        for world_get_objects() {
            if !is_generated(it) continue;
            array_add(*now, xx it_index);
            if array_find(out, xx it_index) continue;
            // Others come out of object 274, which isn't waiting for MASTER_ON.
            if !is_at_generator(it, g) continue;
            total += 1;
            if first >= 0 continue;
            first = it_index;
            check(it.height == 7 * FIXED_ONE, "the first is % tall", it.height / 65536.0);
            check(it.class == .SPRITE && it.data == l.data, "the first is class % art %", it.class, it.data);
            check(!world_is_actor_idle(it.actor), "the first came out idle");
        }
        array_reset(*out);
        array_add(*out, ..now);
    }
    array_free(out);
    check(first >= 0, "no enemy came out after MASTER_ON");
    check(total == 4, "% enemies came out, not 4", total);
} @test

// A mousebot dropped in Detention's tallest room comes down faster than 160 a second:
// the fall's message goes to its own task (0x2646c), which takes no notice, so it lands
// whole and no enemy elsewhere is touched.
dtention_mousebot_falls_fast :: () {
    skip_without_dark();
    if !start_level("DTENTION") return;
    defer world_unload();
    MOUSEBOT :: 130;
    if !check(has_logic(*world_get_level_objects()[MOUSEBOT], "MOUSEBOT"), "object % isn't a mousebot", MOUSEBOT) return;
    level := world_get_level();
    s := *level.sectors[107];
    cx, cz: s64;
    for s.vertices { cx += it.x; cz += it.z; }
    cx /= s.vertices.count;
    cz /= s.vertices.count;
    if !check(world_place_object(MOUSEBOT, .{xx cx, s.floor.altitude - 150 * FIXED_ONE, xx cz}), "nowhere to put the mousebot") return;
    actors := world_get_actor_count();
    o := world_get_objects()[MOUSEBOT];
    start := o.position.y;
    still := 0;
    for 1..300 {
        y := o.position.y;
        if !run(1, .{}) return;
        if o.position.y == y  still += 1;
        else                  still = 0;
        if still == 10 break;
    }
    check(still == 10 && o.position.y - start > 100 * FIXED_ONE, "the mousebot didn't come down: % units", (o.position.y - start) / 65536.0);
    if !run(20, .{}) return;
    check(o.used && o.mousebot != null, "the mousebot broke up");
    check(world_get_actor_count() == actors, "% enemies, not %", world_get_actor_count(), actors);
} @test

// Robotics' 39 SOUND objects are kept going at their places (0x153d7, 0x154f8): at the
// start the water within 100 units plays and the conveyors 170 off don't; out of earshot,
// the water stops at the task's next turn, 72 ticks on.
robotics_sound_objects_play :: () {
    skip_without_dark();
    if !start_level("ROBOTICS") return;
    defer world_unload();
    if !check(world_get_sound_objects().count == 39, "% sound objects, not 39", world_get_sound_objects().count) return;
    if !run(3, .{}) return;
    p := world_get_player();
    near, far := 0, 0;
    start := p.position;
    for world_get_sound_objects() {
        d := dist_approx(it.at.x, it.at.z, start.x, start.z);
        if d < 100 * FIXED_ONE {
            near += 1;
            check(it.playing, "% at % units isn't playing", it.name, d / 65536.0);
        } else if d > 160 * FIXED_ONE {
            far += 1;
            check(!it.playing, "% at % units is playing", it.name, d / 65536.0);
        }
    }
    if !check(near > 0 && far > 0, "% near, % far", near, far) return;
    // Far off from every one of them.
    if !place(-236.4, 77, 386.5, 0) return;
    if !run(40, .{}) return;
    for world_get_sound_objects() {
        if dist_approx(it.at.x, it.at.z, start.x, start.z) < 100 * FIXED_ONE  check(!it.playing, "% still playing far off", it.name);
    }
} @test

// The Executor's INF has two amb_sound lines; their task (0x15457) is made after the O
// file's, so it's the level task's newest child and runs first of them. Their VOCs aren't in
// the GOBs, so nothing plays, as in the original.
executor_amb_sound_task :: () {
    skip_without_dark();
    if !start_level("EXECUTOR") return;
    defer world_unload();
    order := world_get_task_order();
    root := -1;
    for order  if it == .ROOT { root = it_index; break; }
    check(root >= 0 && root + 1 < order.count && order[root + 1] == .LEVEL_SOUNDS, "the frame's order is %", order);
    if !run(400, .{}) return;
} @test

// A turret hung in Detention's cells wakes to the player in sight below it (with the
// headlamp: in the dark it sees no one), turns to face them, its pitch down, and fires turret
// bolts, 17 each. Two hang there.
dtention_turret_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("DTENTION") return;
    defer world_unload();
    TURRET :: 159;
    if !check(has_logic(*world_get_level_objects()[TURRET], "TURRET"), "object % isn't a turret", TURRET) return;
    o := world_get_objects()[TURRET];
    check(o.width == 3 * FIXED_ONE && o.height == -2 * FIXED_ONE, "the turret is % by %", o.width / 65536.0, o.height / 65536.0);
    if !place(132.13, -48, 393.02, 0) return;
    world_toggle_headlight();
    a := world_get_agent();
    a.health, a.shields = 100, 0;
    for 1..400 {
        if !run(1, .{}) return;
        if a.health < 100 break;
    }
    check(a.health == 83 || a.health == 66, "health % after the first bolts", a.health);
    check(o.yaw == 8192 && o.pitch > 0x3000, "the turret faces yaw %, pitch %", o.yaw, o.pitch);
} @test

// Shot from below, a turret aims at the player. Five rifle bolts leave it 10 of its 60 hit
// points; three remote bolts (1 each) take it under 8 and it spins at random, firing as it
// faces; another rifle bolt blows it up, and it's gone.
dtention_turret_shot_down :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("DTENTION") return;
    defer world_unload();
    TURRET :: 159;
    o := world_get_objects()[TURRET];
    if !check(o.turret != null, "object % isn't a turret", TURRET) return;
    if !place(132.13, -48, 393.02, 0) return;
    a := world_get_agent();
    below := Fixed3.{o.position.x, o.position.y + 3 * FIXED_ONE, o.position.z};
    shoot :: (type: Projectile_Type, at: Fixed3) { world_launch_projectile(type, at, 4096, 0); }
    for 1..5 {
        shoot(.RIFLE_BOLT, below);
        for 1..20 { a.health, a.shields = 100, 100; if !run(1, .{}) return; }
    }
    if !check(o.used && o.turret != null, "five bolts brought it down") return;
    for 1..3 {
        shoot(.REMOTE_BOLT, below);
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
    }
    yaws: [..] s32;
    yaws.allocator = temp;
    placed := world_get_projectile_count();
    fired := false;
    for 1..300 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        if world_get_projectile_count() > placed  fired = true;
        placed = world_get_projectile_count();
        if !array_find(yaws, o.yaw)  array_add(*yaws, o.yaw);
    }
    check(yaws.count > 20, "it turned through only % yaws", yaws.count);
    check(fired, "it didn't fire while spinning");
    shoot(.RIFLE_BOLT, below);
    for 1..100 { a.health, a.shields = 100, 100; if !run(1, .{}) return; }
    check(!o.turret, "the turret outlived its hit points");
} @test

// A mousebot in Secret Base, the player 15 units ahead in the headlamp's light, squeaks and
// runs about. It's as wide as its model plus a unit, half that tall, and not aimed at.
secbase_mousebot_runs_about :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    BOT :: 40;
    if !check(has_logic(*world_get_level_objects()[BOT], "MOUSEBOT"), "object % isn't a mousebot", BOT) return;
    o := world_get_objects()[BOT];
    check(o.width > 3 * FIXED_ONE && o.width < 4 * FIXED_ONE && o.height == o.width >> 1 && !o.aimable, "the mousebot is % by %, aimable %", o.width / 65536.0, o.height / 65536.0, o.aimable);
    if !face_object(BOT, 15) return;
    world_toggle_headlight();
    start := o.position;
    a := world_get_agent();
    farthest: Fixed;
    for 1..300 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        farthest = max(farthest, dist_approx(start.x, start.z, o.position.x, o.position.z));
    }
    check(farthest > 10 * FIXED_ONE, "it ran only % units", farthest / 65536.0);
} @test

// A rifle bolt takes a mousebot's 10 hit points: it squeals, and once on the floor pops into
// its wreck and a battery. Killed by a message, it lands only when its idle second is up.
secbase_mousebot_shot :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    BOT :: 40;
    o := world_get_objects()[BOT];
    if !check(o.mousebot != null, "object % isn't a mousebot", BOT) return;
    at := o.position;
    world_launch_projectile(.RIFLE_BOLT, .{at.x, at.y - FIXED_ONE, at.z - 6 * FIXED_ONE}, 0, 0);
    if !run(120, .{}) return;
    check(!o.mousebot, "the mousebot outlived the bolt");
    wreck, battery := false, false;
    for world_get_objects() {
        if !it.used || dist_approx(it.position.x, it.position.z, at.x, at.z) > FIXED_ONE continue;
        if it.class == .FRAME && (it.entity & ENTITY_CORPSE)  wreck = true;
        if it.item == 29  battery = true;   // A battery.
    }
    check(wreck && battery, "wreck %, battery %", wreck, battery);
} @test

// A welder in the Arc Hammer swings to the player standing 12 units before it (with the
// headlamp) and strikes a spark: 20 off health. It strikes only after a swing, so with the
// player standing still it strikes no more.
arc_welder_sparks :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ARC") return;
    defer world_unload();
    WELDER :: 123;
    if !check(has_logic(*world_get_level_objects()[WELDER], "WELDER"), "object % isn't a welder", WELDER) return;
    o := world_get_objects()[WELDER];
    check(o.width == 10 * FIXED_ONE && o.height == 4 * FIXED_ONE, "the welder is % by %", o.width / 65536.0, o.height / 65536.0);
    yaw := o.yaw / 16384.0 * TAU;
    if !place(o.position.x / 65536.0 + 12 * sin(yaw), -96, o.position.z / 65536.0 + 12 * cos(yaw), (o.yaw + 8192) / 16384.0 * 360) return;
    world_toggle_headlight();
    start_yaw := o.yaw;
    a := world_get_agent();
    strikes := 0;
    for 1..600 {
        a.health, a.shields = 100, 0;
        if !run(1, .{}) return;
        if a.health < 100 {
            check(a.health == 80, "health % after a spark", a.health);
            strikes += 1;
        }
    }
    check(o.yaw != start_yaw, "the welder didn't swing");
    check(strikes == 1, "% sparks hurt the player", strikes);
} @test

// Thirteen rifle bolts take a welder's 130 hit points; it blows up and is gone. They come
// from 14 units before it, level with it: from below they'd meet its mount.
arc_welder_destroyed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ARC") return;
    defer world_unload();
    WELDER :: 123;
    o := world_get_objects()[WELDER];
    if !check(o.welder != null, "object % isn't a welder", WELDER) return;
    yaw := o.yaw / 16384.0 * TAU;
    from := Fixed3.{o.position.x + cast(s32) (14 * 65536 * sin(yaw)), o.position.y - 2 * FIXED_ONE, o.position.z + cast(s32) (14 * 65536 * cos(yaw))};
    toward := (o.yaw + 8192) & 0x3FFF;
    a := world_get_agent();
    for 1..12 {
        world_launch_projectile(.RIFLE_BOLT, from, 0, toward);
        for 1..10 { a.health, a.shields = 100, 100; if !run(1, .{}) return; }
    }
    if !check(o.welder != null, "twelve bolts brought it down") return;
    world_launch_projectile(.RIFLE_BOLT, from, 0, toward);
    for 1..150 { a.health, a.shields = 100, 100; if !run(1, .{}) return; }
    check(!o.welder, "the welder outlived its hit points");
} @test

// Gromas Mines' dark trooper waits in the sealed lift that later raises it. With the player
// in the lift beside it, it sees them at its first look, charges, and swings: 20 off health
// each time it connects.
gromas_dark_trooper_strikes :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("GROMAS") return;
    defer world_unload();
    T := find_object_with_logic("D_TROOP1");
    if !check(T >= 0, "no phase-one dark trooper") return;
    o := world_get_objects()[T];
    check(o.dark_trooper != null && (o.flags & OBJECT_BOSS) != 0, "trooper %, boss flag %", o.dark_trooper != null, o.flags & OBJECT_BOSS);
    if !place(-396, 119, 357, 225) return;
    a := world_get_agent();
    strikes := 0;
    first := -1;
    for 1..300 {
        a.health, a.shields = 100, 0;
        if !run(1, .{}) return;
        if a.health < 100 {
            check(a.health == 80, "health % after a swing", a.health);
            strikes += 1;
            if first < 0  first = it;
        }
    }
    check(strikes >= 3 && first < 200, "% swings connected, the first on frame %", strikes, first);
} @test

// Rifle bolts at the trooper: seven in ten glance off its arm, turned back about a half turn;
// the rest take 10 of its 180 hit points.
gromas_dark_trooper_glances :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("GROMAS") return;
    defer world_unload();
    o := world_get_objects()[find_object_with_logic("D_TROOP1")];
    if !place(-396, 119, 357, 225) return;
    p := world_get_player();
    a := world_get_agent();
    turned, hit := 0, 0;
    for 1..6 {
        eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
        yaw := vec2_to_angle(o.position.x - eye.x, o.position.z - eye.z);
        hp := o.dark_trooper.hp;
        bolt := world_launch_projectile(.RIFLE_BOLT, eye, 0, yaw);
        b := world_get_objects()[bolt];
        for 1..40 {
            a.health, a.shields = 100, 100;
            if !run(1, .{}) return;
            off := (b.yaw - yaw) & 0x3FFF;
            if it == 1 && is_projectile(bolt) && off > 0x1000 && off < 0x3000  turned += 1;
        }
        if o.dark_trooper.hp == hp - 10 * FIXED_ONE  hit += 1;
        else check(o.dark_trooper.hp == hp, "a bolt took % hit points", (hp - o.dark_trooper.hp) / 65536.0);
    }
    check(turned >= 1 && hit >= 1 && hit < 6, "% bolts seen turned back, % hit", turned, hit);
} @test

// Shot down, the trooper falls and leaves its corpse, kept from generators; as the level's
// boss it tells the "boss" sector, whose stops drop the "bossisdead" ceiling to 88.
gromas_dark_trooper_killed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("GROMAS") return;
    defer world_unload();
    T := find_object_with_logic("D_TROOP1");
    o := world_get_objects()[T];
    level := world_get_level();
    dead := find_sector_named(level, "bossisdead");
    if !check(dead >= 0, "no bossisdead sector") return;
    if !place(-396, 119, 357, 225) return;
    p := world_get_player();
    a := world_get_agent();
    for 1..600 {
        a.health, a.shields = 100, 100;
        if !o.dark_trooper break;
        if it % 4 == 0 {
            eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
            world_launch_projectile(.RIFLE_BOLT, eye, 0, vec2_to_angle(o.position.x - eye.x, o.position.z - eye.z));
        }
        if !run(1, .{}) return;
    }
    if !check(!o.dark_trooper, "the trooper outlived 150 bolts") return;
    corpses := 0;
    for world_get_objects() {
        if !it.used || !(it.entity & ENTITY_KEPT_CORPSE) continue;
        check(it.class == .SPRITE && it.anim == 4 && it.sector == level_find_sector(level, it.position) && !it.width, "the corpse: class %, action %, sector %, width %", it.class, it.anim, it.sector, it.width);
        corpses += 1;
    }
    check(corpses == 1, "% corpses", corpses);
    for 1..300  if !run(1, .{}) return;
    check(level.sectors[dead].ceiling.altitude == 88 * FIXED_ONE, "bossisdead's ceiling at %", level.sectors[dead].ceiling.altitude / 65536.0);
} @test

// Robotics' phase-two dark troopers wait behind doors. With the first's open and the player
// 30 units off, it wakes, flies at them a unit or two above their feet, lands, and fires
// missiles and plasma, at full light while it does, hurting them.
robotics_dark_trooper_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ROBOTICS") return;
    defer world_unload();
    level := world_get_level();
    T := find_trooper_in(level, "dt1");
    if !check(T >= 0, "no dark trooper in dt1") return;
    o := world_get_objects()[T];
    check(o.dark_trooper.phase == 2 && o.dark_trooper.hp == 350 * FIXED_ONE, "phase %, % hit points", o.dark_trooper.phase, o.dark_trooper.hp / 65536.0);
    world_send_inf_message(find_sector_named(level, "dtdoor1"), .NEXT_STOP);
    if !place(o.position.x / 65536.0, o.position.y / 65536.0 - 1, o.position.z / 65536.0 - 30, 0) return;
    a := world_get_agent();
    floor := o.position.y;
    flew, lit, hurt := false, false, 0;
    for 1..900 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        if o.position.y < floor  flew = true;
        if o.lit  lit = true;
        if a.health < 100 || a.shields < 100  hurt += 1;
    }
    check(flew && lit && hurt >= 3, "flew %, fired at full light %, hurt the player % times", flew, lit, hurt);
} @test

// Every rifle bolt that meets a phase-two trooper takes 10 of its 350 hit points. Shot down,
// it leaves its corpse, plasma and missiles; its death as a boss drops "bossisdead"'s
// ceiling to 28.
robotics_dark_trooper_killed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ROBOTICS") return;
    defer world_unload();
    level := world_get_level();
    T := find_trooper_in(level, "dt1");
    o := world_get_objects()[T];
    world_send_inf_message(find_sector_named(level, "dtdoor1"), .NEXT_STOP);
    if !place(o.position.x / 65536.0, o.position.y / 65536.0 - 1, o.position.z / 65536.0 - 30, 0) return;
    p := world_get_player();
    a := world_get_agent();
    for 1..3000 {
        a.health, a.shields = 100, 100;
        if !o.dark_trooper break;
        if it % 4 == 0 {
            eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
            to := Fixed3.{o.position.x - eye.x, o.position.y - 6 * FIXED_ONE - eye.y, o.position.z - eye.z};
            distance := cast(s32) sqrt(cast(float) to.x * to.x + cast(float) to.z * to.z);
            world_launch_projectile(.RIFLE_BOLT, eye, vec2_to_angle(-to.y, distance), vec2_to_angle(to.x, to.z));
        }
        if !run(1, .{}) return;
    }
    if !check(!o.dark_trooper, "the trooper outlived 750 bolts") return;
    corpse, plasma, missiles := 0, 0, 0;
    for world_get_objects() {
        if !it.used continue;
        if it.entity & ENTITY_KEPT_CORPSE  corpse += 1;
        if it.item == 13  plasma += 1;
        if it.item == 21  missiles += 1;
    }
    check(corpse == 1 && plasma == 1 && missiles == 1, "% corpses, % plasma, % missiles", corpse, plasma, missiles);
    dead := find_sector_named(level, "bossisdead");
    for 1..300  if !run(1, .{}) return;
    check(level.sectors[dead].ceiling.altitude == 28 * FIXED_ONE, "bossisdead's ceiling at %", level.sectors[dead].ceiling.altitude / 65536.0);
} @test

// General Mohc, the phase-three dark trooper, waits on a raised platform behind a door in the
// Arc Hammer, which the level lowers and opens. With the player 40 units off he wakes, and
// before long fires six homing missiles at once, at full light while he does.
arc_mohc_fires_homing_missiles :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ARC") return;
    defer world_unload();
    o := world_get_objects()[find_object_with_logic("D_TROOP3")];
    if !check(o.dark_trooper != null, "Mohc isn't a dark trooper") return;
    t := o.dark_trooper;
    check(t.phase == 3 && t.hp == 750 * FIXED_ONE && (o.entity & ENTITY_MOHC) != 0, "phase %, % hit points, entity %", t.phase, t.hp / 65536.0, o.entity);
    if !face_mohc(o) return;
    a := world_get_agent();
    volleys := 0;
    count := world_get_projectile_count();
    for 1..900 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        now := world_get_projectile_count();
        if now - count == 6 && o.lit  volleys += 1;
        count = now;
    }
    check(volleys >= 1, "% volleys of six", volleys);
} @test

// Shot down, Mohc leaves his corpse and no items, and tells the "mohc" sector, not "boss":
// its first stop is a unit down.
arc_mohc_killed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("ARC") return;
    defer world_unload();
    level := world_get_level();
    o := world_get_objects()[find_object_with_logic("D_TROOP3")];
    mohc := find_sector_named(level, "mohc");
    boss := find_sector_named(level, "boss");
    mohc_floor, boss_floor := level.sectors[mohc].floor.altitude, level.sectors[boss].floor.altitude;
    items := count_items(13) + count_items(21);
    if !face_mohc(o) return;
    p := world_get_player();
    a := world_get_agent();
    for 1..4000 {
        a.health, a.shields = 100, 100;
        if !o.dark_trooper break;
        if it % 3 == 0 {
            eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
            to := Fixed3.{o.position.x - eye.x, o.position.y - 7 * FIXED_ONE - eye.y, o.position.z - eye.z};
            distance := cast(s32) sqrt(cast(float) to.x * to.x + cast(float) to.z * to.z);
            world_launch_projectile(.RIFLE_BOLT, eye, vec2_to_angle(-to.y, distance), vec2_to_angle(to.x, to.z));
        }
        if !run(1, .{}) return;
    }
    if !check(!o.dark_trooper, "Mohc outlived 1300 bolts") return;
    corpses := 0;
    for world_get_objects()  if it.used && (it.entity & ENTITY_KEPT_CORPSE)  corpses += 1;
    check(corpses == 1 && count_items(13) + count_items(21) == items, "% corpses, % plasma and missiles more", corpses, count_items(13) + count_items(21) - items);
    for 1..100  if !run(1, .{}) return;
    check(level.sectors[mohc].floor.altitude == mohc_floor - FIXED_ONE && level.sectors[boss].floor.altitude == boss_floor, "mohc's floor moved %, boss's %", (level.sectors[mohc].floor.altitude - mohc_floor) / 65536.0, (level.sectors[boss].floor.altitude - boss_floor) / 65536.0);
} @test

// Boba Fett waits in a tall hall of Imperial City. With the player 20 units off he sees them,
// takes off on his jetpack, and flies about the hall shooting at them, never leaving it.
impcity_boba_fett_flies_and_fires :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("IMPCITY") return;
    defer world_unload();
    o := world_get_objects()[find_object_with_logic("BOBA_FETT")];
    if !check(o.boba_fett != null && o.height == 7 * FIXED_ONE, "Boba Fett isn't set up: %, height %", o.boba_fett != null, o.height / 65536.0) return;
    hall := o.sector;
    floor := o.position.y;
    if !place(o.position.x / 65536.0 + 20, o.position.y / 65536.0 - 1, o.position.z / 65536.0, 270) return;
    a := world_get_agent();
    highest := floor;
    hurt := 0;
    for 1..900 {
        a.health, a.shields = 100, 100;
        if !run(1, .{}) return;
        if !check(o.sector == hall, "frame %: Boba Fett left the hall for sector %", it, o.sector) return;
        highest = min(highest, o.position.y);
        if a.health < 100 || a.shields < 100  hurt += 1;
    }
    check(floor - highest > 10 * FIXED_ONE && hurt >= 5, "rose % units, hurt the player % times", (floor - highest) / 65536.0, hurt);
} @test

// Shot down, Boba Fett leaves his corpse where he is, and as the level's boss sets off its
// "boss" sector, which rises 5 units.
impcity_boba_fett_killed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("IMPCITY") return;
    defer world_unload();
    level := world_get_level();
    o := world_get_objects()[find_object_with_logic("BOBA_FETT")];
    boss := find_sector_named(level, "boss");
    boss_floor := level.sectors[boss].floor.altitude;
    if !place(o.position.x / 65536.0 + 20, o.position.y / 65536.0 - 1, o.position.z / 65536.0, 270) return;
    p := world_get_player();
    a := world_get_agent();
    for 1..3000 {
        a.health, a.shields = 100, 100;
        if !o.boba_fett break;
        if it % 3 == 0 {
            eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
            to := Fixed3.{o.position.x - eye.x, o.position.y - 4 * FIXED_ONE - eye.y, o.position.z - eye.z};
            distance := cast(s32) sqrt(cast(float) to.x * to.x + cast(float) to.z * to.z);
            world_launch_projectile(.RIFLE_BOLT, eye, vec2_to_angle(-to.y, distance), vec2_to_angle(to.x, to.z));
        }
        if !run(1, .{}) return;
    }
    if !check(!o.boba_fett, "Boba Fett outlived 1000 bolts") return;
    corpses := 0;
    for world_get_objects()  if it.used && (it.entity & ENTITY_KEPT_CORPSE) && it.anim == 4  corpses += 1;
    check(corpses == 1, "% corpses", corpses);
    for 1..800  if !run(1, .{}) return;
    check(level.sectors[boss].floor.altitude == boss_floor - 5 * FIXED_ONE, "boss's floor moved %", (level.sectors[boss].floor.altitude - boss_floor) / 65536.0);
} @test

// A Kell dragon in the pit of Jabba's ship sees the player 40 units off and charges; it
// leaps at them and bites, 20 off health each time it connects.
jabship_kell_dragon_leaps_and_bites :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("JABSHIP") return;
    defer world_unload();
    o := find_boss_dragon();
    if !check(o != null, "no boss Kell dragon") return;
    if !place(o.position.x / 65536.0 + 40, o.position.y / 65536.0 - 1, o.position.z / 65536.0, 270) return;
    world_toggle_headlight();
    a := world_get_agent();
    leaps, bites := 0, 0;
    for 1..900 {
        a.health, a.shields = 100, 0;
        if !run(1, .{}) return;
        if o.anim == 9 && o.frame == 0  leaps += 1;
        if a.health < 100 {
            check(a.health == 80, "health % after a bite", a.health);
            bites += 1;
        }
    }
    check(leaps >= 1 && bites >= 3, "% frames crouching to leap, % bites", leaps, bites);
} @test

// Shot down, a Kell dragon leaves its corpse, and as the level's boss tells its "boss"
// sector, whose floor drops a unit.
jabship_kell_dragon_killed :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("JABSHIP") return;
    defer world_unload();
    level := world_get_level();
    o := find_boss_dragon();
    boss := find_sector_named(level, "boss");
    boss_floor := level.sectors[boss].floor.altitude;
    if !place(o.position.x / 65536.0 + 40, o.position.y / 65536.0 - 1, o.position.z / 65536.0, 270) return;
    p := world_get_player();
    a := world_get_agent();
    for 1..3000 {
        a.health, a.shields = 100, 100;
        if !o.kell_dragon break;
        if it % 3 == 0 {
            eye := Fixed3.{p.position.x, p.position.y - 5 * FIXED_ONE, p.position.z};
            to := Fixed3.{o.position.x - eye.x, o.position.y - 5 * FIXED_ONE - eye.y, o.position.z - eye.z};
            distance := cast(s32) sqrt(cast(float) to.x * to.x + cast(float) to.z * to.z);
            world_launch_projectile(.RIFLE_BOLT, eye, vec2_to_angle(-to.y, distance), vec2_to_angle(to.x, to.z));
        }
        if !run(1, .{}) return;
    }
    if !check(!o.kell_dragon, "the dragon outlived 1000 bolts") return;
    corpses := 0;
    for world_get_objects()  if it.used && (it.entity & ENTITY_KEPT_CORPSE) && it.anim == 4  corpses += 1;
    check(corpses == 1, "% corpses", corpses);
    for 1..100  if !run(1, .{}) return;
    check(level.sectors[boss].floor.altitude == boss_floor - FIXED_ONE, "boss's floor moved %", (level.sectors[boss].floor.altitude - boss_floor) / 65536.0);
} @test

// Jabba's ship takes the inventory and the ammo and puts the fists in hand. The pile gives it
// all back, added to what was found since and cut to the limits, but takes the nava card;
// the highest weapon held comes back up.
jabship_pile_gives_back_inventory :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    a := world_get_agent();
    a.items[Item_Slot.RIFLE] = -1;
    a.items[Item_Slot.RED_KEY] = -1;
    a.ammo[Ammo.ENERGY] = 450;
    a.ammo[Ammo.POWER] = 30;
    a.weapon = WEAPON_RIFLE;
    a.highest_weapon = WEAPON_RIFLE;
    if !start_level("JABSHIP") return;
    defer world_unload();
    check(world_get_weapon() == WEAPON_FIST, "weapon % in hand at the start", world_get_weapon());
    empty := true;
    for a.items  if it  empty = false;
    for a.ammo   if it  empty = false;
    check(empty, "the agent kept %", a.*);

    a.items[Item_Slot.NAVA] = -1;
    a.ammo[Ammo.ENERGY] = 100;
    pile := world_get_objects()[find_object_with_logic("PILE")];
    // It hangs 10 units over the floor, in reach of a jump from under it.
    if !place(pile.position.x / 65536.0, 46, pile.position.z / 65536.0, 0) return;
    if !run(60, .{}) return;
    check(a.items[Item_Slot.PISTOL] == 0, "the pile was taken without a jump");
    if !run(60, .{jump = true}) return;
    check(a.items[Item_Slot.PISTOL] != 0 && a.items[Item_Slot.RIFLE] != 0, "no pistol or rifle back: %", a.items);
    check(a.items[Item_Slot.RED_KEY] == 0, "the red key came into the level");
    check(a.items[Item_Slot.NAVA] == 0, "the nava card stayed");
    check(a.ammo[Ammo.ENERGY] == 500 && a.ammo[Ammo.POWER] == 30, "ammo %", a.ammo);
    if !run(60, .{}) return;
    check(world_get_weapon() == WEAPON_RIFLE, "weapon % in hand after the pile", world_get_weapon());
} @test

// What the view shows is marked for the map as the original's renderer marks it: from the
// start, the start sector and the corridor's sectors, nowhere near the whole level. The PDA's
// map draws the walls seen and the player at its center; a secret found sets the PDA's
// percentage, worked out only then (one of Secret Base's seven: 14).
secbase_map_marks_what_was_seen :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !run(150, .{}) return;
    world_mark_seen();
    level := world_get_level();
    p := world_get_player();
    sectors, walls := 0, 0;
    for level.sectors {
        if it.flags[0] & SECTOR_SEEN  sectors += 1;
        for w: it.walls  if w.seen  walls += 1;
    }
    check((level.sectors[p.sector].flags[0] & SECTOR_SEEN) != 0, "the player's sector isn't seen");
    check(sectors > 5 && sectors < level.sectors.count / 4 && walls > sectors, "% sectors and % walls seen", sectors, walls);

    world_send_automap_message(.CENTER);
    pixels: [290 * 156] u8;
    world_draw_automap_for_pda(pixels, 290, 156);
    drawn := 0;
    for pixels  if it == 10  drawn += 1;
    check(drawn > 50, "% pixels of walls on the map", drawn);
    check(pixels[78 * 290 + 145] == 6, "the map's center is % rather than the player", pixels[78 * 290 + 145]);

    check(world_get_secrets_percent() == 0, "secrets at the start: %", world_get_secrets_percent());
    // Into a secret: from just outside one of its openings, walking in.
    for secret, secret_index: level.sectors {
        if !(secret.flags[0] & SECTOR_SECRET) continue;
        for wall: secret.walls {
            if wall.adjoin < 0 continue;
            a, b := secret.vertices[wall.left], secret.vertices[wall.right];
            dx, dz := (b.x - a.x) / 65536.0, (b.z - a.z) / 65536.0;
            length := sqrt(dx * dx + dz * dz);
            if length < 2 continue;
            in_x, in_z := dz / length, -dx / length;    // Walls face into their sector.
            x := (a.x + b.x) / 2 / 65536.0 - in_x * 1.5;
            z := (a.z + b.z) / 2 / 65536.0 - in_z * 1.5;
            outside := *level.sectors[wall.adjoin];
            if !world_place_player(.{x, outside.floor.altitude / 65536.0, z}) || world_get_player().sector != wall.adjoin continue;
            face(atan2(in_x, in_z) * 180 / PI);
            for 1..60 {
                if !run(1, .{forward = true}) return;
                if world_get_player().sector == secret_index break;
            }
            if world_get_player().sector != secret_index continue;
            check(world_get_secrets_percent() == 14, "a secret found: %", world_get_secrets_percent());
            return;
        }
    }
    check(false, "couldn't walk into a secret sector");
} @test

// The Tab map's keys, frame by frame: = zooms by the frame's time; ` held scrolls it with the
// arrows, off the player, until the player moves again;
// [ and ] change its layer within the level's.
secbase_tab_map_keys :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    if !run(150, .{}) return;
    world_toggle_automap(false);
    defer if world_is_automap_on()  world_toggle_automap(false);
    if !check(world_is_automap_on(), "Tab didn't bring the map up") return;
    before := world_get_automap();
    if !run(20, .{map_zoom_in = true}) return;
    after := world_get_automap();
    check(after.scale > before.scale, "zooming in: % to %", before.scale, after.scale);
    if !run(20, .{map_zoom_out = true}) return;

    // Whether the player has moved is looked at as the map is drawn (0x1c0cf), every frame
    // in the game; the PDA's picture draws it the same way, with no screen.
    run_drawn :: (frames: int, input: World_Input) -> bool {
        pixels: [290 * 156] u8;
        for 1..frames {
            if !run(1, input) return false;
            world_draw_automap_for_pda(pixels, 290, 156);
        }
        return true;
    }
    p := world_get_player();
    if !run_drawn(10, .{map_scroll = true, map_left = true}) return;
    scrolled := world_get_automap();
    check(!scrolled.auto_center && scrolled.x < p.position.x, "scrolling left: centered %, % from the player's %", scrolled.auto_center, scrolled.x, p.position.x);
    if !run_drawn(10, .{}) return;
    check(!world_get_automap().auto_center, "the map came back with the player standing still");
    if !run_drawn(10, .{forward = true}) return;
    check(world_get_automap().auto_center, "the map didn't come back to the player as it moved");

    layer := world_get_automap().layer;
    world_change_automap_layer(true);
    world_change_automap_layer(true);
    world_change_automap_layer(true);
    check(world_get_automap().layer >= layer, "layer up went down");
    for 1..10  world_change_automap_layer(false);
    lowest := world_get_automap().layer;
    world_change_automap_layer(false);
    check(world_get_automap().layer == lowest, "below the level's lowest layer: %", world_get_automap().layer);
} @test

// The bot, as footage uses it: in the officer's room with the rifle, it finds him, turns to
// him and fires until he's down. Without a screen there's no aiming help (it works from what
// was drawn), so this needs its own aim, up and down too.
secbase_bot_kills_officer :: () {
    skip_without_dark();
    saved := world_get_agent().*;
    defer world_get_agent().* = saved;
    if !start_level("SECBASE") return;
    defer world_unload();
    if !place(300, 20, 275.64, 90) return;
    officer := find_object_with_logic("I_OFFICER");
    if !check(world_get_actor(xx officer) != null, "the officer has no actor") return;
    world_give_weapon(WEAPON_RIFLE);
    world_get_player_state().invincible = -2;
    world_reset_bot();
    killed := -1;
    for 1..600 {
        input: World_Input;
        world_get_bot_input(*input);
        if !run(1, input) return;
        if world_get_actor(xx officer) == null { killed = it; break; }
    }
    check(killed > 0, "the bot didn't kill the officer in 600 frames");
} @test

// The goggles, cleats and mask keys (0x2a508-0x2a684): nothing without the item; on and off
// with their messages; the goggles' palette green two drawn frames after they go on and
// back three after they go off; with the battery empty the goggles and mask stay off, and
// running it out turns them off and stops the breathing.
secbase_goggles_cleats_mask :: () {
    skip_without_dark();
    if !start_level("SECBASE") return;
    defer world_unload();
    a := world_get_agent();
    s := world_get_player_state();
    a.items[Item_Slot.GOGGLES] = 0;
    a.items[Item_Slot.CLEATS] = 0;
    a.items[Item_Slot.MASK] = 0;
    world_toggle_goggles();
    world_toggle_cleats();
    world_toggle_mask();
    check(!s.goggles_on && !s.cleats_on && !s.mask_on, "on without the items");

    a.items[Item_Slot.GOGGLES] = -1;
    a.items[Item_Slot.CLEATS] = -1;
    a.items[Item_Slot.MASK] = -1;
    world_toggle_cleats();
    check(s.cleats_on && world_get_hud_message() == "Ice Cleats On", "cleats: % \"%\"", s.cleats_on, world_get_hud_message());
    world_toggle_cleats();
    check(!s.cleats_on, "cleats still on");

    world_toggle_goggles();
    check(s.goggles_on && world_get_hud_message() == "Goggles On", "goggles: % \"%\"", s.goggles_on, world_get_hud_message());
    world_count_view_frame();
    check(!s.goggles_green, "green after one frame");
    world_count_view_frame();
    palette := world_get_palette();
    c := palette.colors[100];
    check(s.goggles_green && c.r == 0 && c.b == 0 && c.g != 0, "not green after two frames: %", c);
    world_toggle_goggles();
    check(!s.goggles_on, "goggles still on");
    world_count_view_frame();
    world_count_view_frame();
    check(s.goggles_green, "the green gone before three frames");
    world_count_view_frame();
    check(!s.goggles_green, "still green three frames after");

    world_toggle_mask();
    check(s.mask_on && s.breath_tick != 0 && world_get_hud_message() == "Gas Mask On", "mask: % % \"%\"", s.mask_on, s.breath_tick, world_get_hud_message());
    world_toggle_goggles();
    a.battery = 0x100;
    run(20, .{});
    check(!s.goggles_on && !s.mask_on && s.breath_tick == 0 && a.battery == 0, "the battery run out: goggles %, mask %, breathing %, battery %", s.goggles_on, s.mask_on, s.breath_tick, a.battery);
    world_toggle_goggles();
    world_toggle_mask();
    check(!s.goggles_on && !s.mask_on, "on with an empty battery");
} @test

// Robotics' gas (sector 44): it hurts and chokes without the mask; with it on the damage and
// the choking stop, the breathing goes on and the battery drains.
robotics_mask_keeps_out_gas :: () {
    skip_without_dark();
    if !start_level("ROBOTICS") return;
    defer world_unload();
    level := world_get_level();
    gas := *level.sectors[44];
    x, z: float;
    for gas.vertices { x += it.x / 65536.0; z += it.z / 65536.0; }
    x /= gas.vertices.count;
    z /= gas.vertices.count;
    if !place(x, gas.floor.altitude / 65536.0 - 1, z, 0) return;
    check(world_get_player().sector == 44, "not in the gas: sector %", world_get_player().sector);
    a := world_get_agent();
    s := world_get_player_state();
    a.items[Item_Slot.MASK] = -1;
    health := a.health;
    if !run(60, .{}) return;
    check(a.health < health && s.choke_tick != 0, "no choking: health % to %, choke %", health, a.health, s.choke_tick);
    world_toggle_mask();
    battery := a.battery;
    health = a.health;
    if !run(300, .{}) return;
    check(a.health == health && s.choke_tick == 0, "the mask on: health % to %, choke %", health, a.health, s.choke_tick);
    check(s.breath_tick != 0 && a.battery < battery, "breathing %, battery % to %", s.breath_tick, battery, a.battery);
} @test

// Walking into Arc Hammer's shuttle bay: its light elevator, holding at its first stop, is
// triggered on entering (a light keeps the original's trigger rule -1, taken as the next
// stop), brings the lights up to 6 and completes goal 3 on the way to 8.
arc_shuttle_bay_completes_goal :: () {
    skip_without_dark();
    if !start_level("ARC") return;
    defer world_unload();
    level := world_get_level();
    bay := find_sector_named(level, "shuttle_bay");
    if !check(bay >= 0, "no shuttle_bay sector") return;
    s := *level.sectors[bay];
    check(s.ambient == 0, "the bay's light starts at %", s.ambient / 65536.0);
    x, z: float;
    for s.vertices { x += it.x / 65536.0; z += it.z / 65536.0; }
    x /= s.vertices.count;
    z /= s.vertices.count;
    // From just outside an opening level with its floor, walking in toward the middle.
    from: Vector2;
    for w: s.walls {
        if w.adjoin < 0 || level.sectors[w.adjoin].floor.altitude != s.floor.altitude continue;
        a, b := s.vertices[w.left], s.vertices[w.right];
        mx, mz := (a.x + b.x) / 131072.0, (a.z + b.z) / 131072.0;
        dx, dz := x - mx, z - mz;
        l := sqrt(dx * dx + dz * dz);
        from = .{mx - dx / l * 3, mz - dz / l * 3};
        break;
    }
    if !place(from.x, s.floor.altitude / 65536.0 - 1, from.y, atan2(x - from.x, z - from.y) / TAU * 360) return;
    if !run(60, .{forward = true}) return;
    if !check(world_get_player().sector == bay, "not in the bay: sector %", world_get_player().sector) return;
    if !run(60, .{}) return;
    check(s.ambient == 8 * FIXED_ONE, "the bay's light is %", s.ambient / 65536.0);
    check(world_get_player_state().triggers_done[3], "goal 3 isn't done");
} @test

// A shot at a switch answers only within its sign, as a nudge does (0x56b34): Detention
// Center's first gate switch (wall 5 of gateswitch1, which takes shots) shot beside its sign
// stays, and shot on it turns.
dtention_shot_switch_within_sign :: () {
    skip_without_dark();
    if !start_level("DTENTION") return;
    defer world_unload();
    level := world_get_level();
    s := find_sector_named(level, "gateswitch1");
    if !check(s >= 0, "no gateswitch1 sector") return;
    ok, along_min, along_max, top, bottom := world_get_sign_box(s, 5);
    if !check(ok, "wall 5 has no sign") return;
    w := *level.sectors[s].walls[5];

    // A rifle bolt from 3 units off the wall, square to it, on whichever side is open.
    shoot :: (s: s32, w: *Wall, along: Fixed, y: Fixed) -> bool {
        level := world_get_level();
        v := level.sectors[s].vertices[w.left];
        dx, dz := w.direction.x / 65536.0, w.direction.z / 65536.0;
        hx := v.x / 65536.0 + dx * along / 65536.0;
        hz := v.z / 65536.0 + dz * along / 65536.0;
        for side: float.[1, -1] {
            fx, fz := hx + dz * 3 * side, hz - dx * 3 * side;
            at := Fixed3.{cast(Fixed) (fx * 65536), y, cast(Fixed) (fz * 65536)};
            if level_find_sector(level, at) < 0 continue;
            launch(.RIFLE_BOLT, at, 0, atan2(hx - fx, hz - fz) / TAU * 360);
            return run(20, .{});
        }
        return check(false, "nowhere to shoot from");
    }

    middle_y := (top + bottom) / 2;
    beside := along_max + 2 * FIXED_ONE;
    if beside + FIXED_ONE > w.length  beside = along_min - 2 * FIXED_ONE;
    if !shoot(s, w, beside, middle_y) return;
    check(world_get_switch_frame(s, 5) == 0, "the switch turned, shot beside its sign");
    if !shoot(s, w, (along_min + along_max) / 2, middle_y) return;
    check(world_get_switch_frame(s, 5) == 1, "the switch didn't turn, shot on its sign");
} @test

#scope_file

// Puts the player a distance in front of an object, facing it, a unit above its feet.
face_object :: (index: s32, distance: float) -> bool {
    o := world_get_objects()[index];
    yaw := o.yaw / 16384.0 * TAU;
    x := o.position.x / 65536.0 + distance * sin(yaw);
    z := o.position.z / 65536.0 + distance * cos(yaw);
    return place(x, o.position.y / 65536.0 - 1, z, (o.yaw + 8192) / 16384.0 * 360);
}

// The number key (1 to 0) held.
number_key :: (n: int) -> World_Input {
    input: World_Input;
    input.weapon_keys[(n + 9) % 10] = true;
    return input;
}

launch :: (type: Projectile_Type, at: Fixed3, pitch_degrees: float, yaw_degrees: float) -> s32 {
    return world_launch_projectile(type, at, cast(s32) (pitch_degrees / 360.0 * 16384), cast(s32) (yaw_degrees / 360.0 * 16384));
}

// Puts the player at a place facing a way; false if no sector holds it.
place :: (x: float, y: float, z: float, degrees: float) -> bool {
    if !check(world_place_player(.{x, y, z}), "no sector holds (%, %, %)", x, y, z) return false;
    face(degrees);
    return true;
}

// Runs frames until a projectile goes: the frame it went on, or -1 (or a failed frame). Its
// slot may be taken by another projectile afterwards, so it's watched every frame.
run_until_gone :: (index: s32, frames: int) -> int {
    for 1..frames {
        if !run(1, .{}) return -1;
        if !is_projectile(index) return it;
    }
    return -1;
}

is_projectile :: (index: s32) -> bool {
    o := world_get_objects()[index];
    return o.used && (o.entity & ENTITY_PROJECTILE) != 0;
}

is_same_place :: (a: Fixed3, b: Fixed3) -> bool { return a.x == b.x && a.y == b.y && a.z == b.z; }

find_object_with_logic :: (logic: string) -> s32 {
    for * world_get_level_objects()  if has_logic(it, logic) return xx it_index;
    return -1;
}

find_sector_named :: (level: *Level, name: string) -> s32 {
    for level.sectors  if equal_nocase(it.name, name) return xx it_index;
    return -1;
}

// Lowers Mohc's platform and opens its door, as the level's "vocelev" does, and puts the
// player 40 units east of him in the hangar, facing him.
face_mohc :: (o: *Object) -> bool {
    level := world_get_level();
    world_send_inf_message(find_sector_named(level, "mohc.door"), .NEXT_STOP);
    world_send_inf_message(find_sector_named(level, "mohc.platform"), .NEXT_STOP);
    for 1..800  world_update(0, .{}, fixed_step = true);
    return place(o.position.x / 65536.0 + 40, o.position.y / 65536.0 - 1, o.position.z / 65536.0, 270);
}

count_items :: (item: s32) -> int {
    count := 0;
    for world_get_objects()  if it.used && it.item == item  count += 1;
    return count;
}

// The Kell dragon marked as the level's boss that's in play.
find_boss_dragon :: () -> *Object {
    for world_get_objects()  if it.used && it.kell_dragon && (it.flags & OBJECT_BOSS) && it.sector >= 0  return it;
    return null;
}

// The dark trooper waiting in a sector.
find_trooper_in :: (level: *Level, sector_name: string) -> s32 {
    sector := find_sector_named(level, sector_name);
    for world_get_objects()  if it.used && it.dark_trooper && it.sector == sector  return xx it_index;
    return -1;
}

// Loads a level for a test, or says why it can't. Each starts from the executable's random
// seed, so a scenario doesn't depend on the random numbers the ones before it drew.
start_level :: (name: string) -> bool {
    if !level_data_ready {
        dir := find_dark_data_dir();
        if !check(gob_mount_retail(dir), "couldn't mount the retail GOBs") return false;
        if !check(fixed_load_tables(dir), "couldn't read DARK.EXE's tables") return false;
        level_data_ready = true;
        first_seed = fixed_get_random_seed();
    }
    fixed_set_random_seed(first_seed);
    return check(world_load(name), "couldn't load %", name);
}

level_data_ready: bool;
first_seed: u32;

face :: (degrees: float) {
    p := world_get_player();
    p.yaw = (cast(s32) (degrees / 360.0 * 16384)) & 0x3FFF;
    p.object_yaw = p.yaw;
}

// Runs frames with the input held, checking the world after each; false at the first that
// fails.
run :: (frames: int, input: World_Input) -> bool {
    for 1..frames {
        world_update(0, input, fixed_step = true);
        if !check_world(it) return false;
    }
    return true;
}

check_world :: (frame: int) -> bool {
    p := world_get_player();
    level := world_get_level();
    if !check(p.sector >= 0 && p.sector < level.sectors.count, "frame %: no sector (%)", frame, p.sector) return false;
    sector := *level.sectors[p.sector];
    if !check(is_point_in_sector(sector, p.position.x, p.position.z), "frame %: at % but counted in sector %, which doesn't hold it", frame, at(p), p.sector) return false;
    // Water's bottom (the second floor) is below the floor.
    floor := max(sector.col_floor, sector.col_second);
    if !check(p.position.y >= sector.ceiling.altitude && p.position.y <= floor, "frame %: y % outside sector %'s heights (% to %)", frame, p.position.y / 65536.0, p.sector, sector.ceiling.altitude / 65536.0, floor / 65536.0) return false;
    a := world_get_agent();
    if !check(a.health >= 0 && a.health <= 100, "frame %: health %", frame, a.health) return false;
    return true;
}

at :: (p: *Player) -> string {
    return tprint("(%, %, %)", p.position.x / 65536.0, p.position.y / 65536.0, p.position.z / 65536.0);
}

#import "Basic";
#import "Math";
#import "String";
#import "engine/dfArchive";
#import "engine/dfFixed";
#import "engine/dfLevel";
#import "engine/dfWorld";
#import "engine/dfAgents";
