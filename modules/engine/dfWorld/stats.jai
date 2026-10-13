// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The player's stats and what changes them, as DARK.EXE keeps them: health and shields,
// lives, ammo, the battery and the items it powers, damage and dying, safe places to start
// again, secrets found.
//
// What an agent carries from level to level (Agent) is kept apart from the level; each level
// starts by the original's rules (0x29790): at least 3 lives, shields back up to 100 if
// lower, health 100, the battery full, nothing worn or lit.

Agent :: struct {
    lives:   s32 = 3;
    shields: s32 = 100;             // -1 while invincible: the HUD shows the super shield.
    health:  s32 = 100;
    health_fraction: s32;           // Below one point, 16 bits.
    battery: Fixed = BATTERY_FULL;
    ammo: [AMMO_KINDS] s32 = .[100, 0, 0, 0, 0, 0, 0];  // By Ammo.

    // What the agent has, as the original's table of slots (0xe6430): nonzero for owned.
    items: [ITEM_SLOTS] s32 = .[0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    // The weapons thrown from the detonator and mine ammo, kept just before the table
    // (0xe6428, 0xe642c).
    detonator_weapon, mine_weapon: s32 = -1;
    weapon: s32 = 1;                // The weapon in hand, carried into the next mission.
    // The highest weapon put in hand (0xe64d8), which the pile switches back to. The original
    // never resets it, so it outlives levels and agents.
    highest_weapon: s32;
}

Ammo :: enum u8 { ENERGY; POWER; PLASMA; DETONATOR; SHELL; MINE; MISSILE; }
AMMO_KINDS :: 7;

// The slots of Agent.items (by their place after 0xe6430).
ITEM_SLOTS :: 29;
Item_Slot :: enum s32 {
    PISTOL :: 1;
    RIFLE :: 2; AUTOGUN :: 3; MORTAR :: 4; FUSION :: 5; CONCUSSION :: 6; CANNON :: 7;
    RED_KEY :: 8; YELLOW_KEY :: 9; BLUE_KEY :: 10;
    GOGGLES :: 11; CLEATS :: 12; MASK :: 13;
    PLANS :: 14; PHRIK :: 15; DATATAPE :: 16; NAVA :: 18; DT_WEAPON :: 19;
    CODE1 :: 20;    // To CODE9, 28.
}

AMMO_MAX :: s32.[500, 500, 400, 50, 50, 30, 20];
SHIELDS_MAX :: 200;
HEALTH_MAX  :: 100;
LIVES_MAX   :: 9;
BATTERY_FULL :Fixed: 0x20000;

agent: Agent;

// What the level adds to the agent's stats while it's played.
Player_State :: struct {
    headlamp, goggles_on, mask_on, cleats_on: bool;
    invincible: s32;                // -1 from the powerup, -2 the cheat; 0 none.
    dying: bool;
    revive_tick: s32;               // When a key may bring it back.
    shields_safe_until: s32;        // After coming back, no shield damage till this tick.
    hurt_sound_after: s32;
    level_light: s32;               // Added to the weapon's light (Gromas: 30).

    // The screen's tints, 16.16, faded each tick (0x1ef6c): health red, shields green,
    // pickups blue.
    health_fx, shield_fx, flash_fx: Fixed;
    health_level, shield_level, flash_level: s32;  // This frame's, for the palette.

    safe: Safe;
    has_safe: bool;
    secrets_found, secrets: s32;
    // As the PDA shows it (0xfb1d4): worked out only when a secret is found, so a level
    // without secrets shows 0%.
    secrets_percent: s32;

    level_failed: bool;             // Died with no lives left.
    // What the goals wait for, done (goals.jai): objectives picked up by their item number
    // (0xfa1b4: plans, phrik, nava, -, datatape, DT weapon, the pile) and INF "complete"
    // messages by their number (0xfa18c).
    items_done, triggers_done: [GOAL_SLOTS] bool;
    current_weapon: s32 = 1;        // In hand: the agent's at the start, then weapons.jai's.
    invincible_until, supercharged_until: s32;     // The powerups' timers, in ticks.
    invincible_blinks, supercharge_blinks: s32;
    supercharged: bool;             // The HUD's ammo font.
    scream, crush_sound: Sound_Instance;

    // The goggles' palette (0x51ef0, 0x51f10): green two drawn frames after they go on,
    // back three after they go off, each counted down on its own (0x124940, 0x124954).
    goggles_green: bool;
    goggles_green_in, goggles_green_out: s32;
    // The mask's breathing (0x2fc74) and the choking in gas without it (0x2fcb4): tasks
    // that play their sound and wait, as the tick they run next; 0 when not running.
    breath_tick, choke_tick: s32;
    breath_out: bool;               // The next breath is mask2.voc.
}

Safe :: struct {
    sector: s32;
    x, z: Fixed;
    yaw: s32;
}

world_get_agent :: () -> *Agent { return *agent; }

// The weapon in hand becomes the one the agent starts the next level with, as a mission's end
// saves it (0x2f504): for levels played from the tools, which have no mission to end.
world_keep_weapon :: () {
    if world.loaded  agent.weapon = world.player_state.current_weapon;
}

world_get_player_state :: () -> *Player_State { return *world.player_state; }

world_get_secrets_percent :: () -> s32 { return world.player_state.secrets_percent; }

// What the agent takes into a mission, from the agent file's 32 bytes and 10 numbers
// (0x1860d, 0x2f678): each byte a slot's value, zero-extended.
world_set_agent_inventory :: (items: [32] u8, stats: [10] s32) {
    for slot, i: INVENTORY_SLOTS  set_inventory_slot(slot, items[i]);
    agent.weapon = items[30];
    agent.highest_weapon = max(agent.highest_weapon, agent.weapon);
    agent.lives = items[31];
    for 0..AMMO_KINDS-1  agent.ammo[it] = stats[it];
    agent.shields = stats[7];
    agent.health = stats[8];
    agent.battery = stats[9];
}

// The same, for the next mission (0x184ba, 0x2f504): each slot's low byte.
world_get_agent_inventory :: () -> [32] u8, [10] s32 {
    items: [32] u8;
    stats: [10] s32;
    for slot, i: INVENTORY_SLOTS  items[i] = cast,trunc(u8) get_inventory_slot(slot);
    items[30] = cast,trunc(u8) ifx world.loaded then world.player_state.current_weapon else agent.weapon;
    items[31] = cast,trunc(u8) agent.lives;
    for 0..AMMO_KINDS-1  stats[it] = agent.ammo[it];
    stats[7] = agent.shields;
    stats[8] = agent.health;
    stats[9] = agent.battery;
    return items, stats;
}

world_has_failed :: () -> bool { return world.loaded && world.player_state.level_failed; }

// The headlamp, on and off (0x2a6a4, 0x2a6dc): on only with charge in the battery.
world_toggle_headlight :: () {
    if !world.loaded return;
    s := *world.player_state;
    if s.headlamp {
        s.headlamp = false;
        send_message(MSG_HEADLAMP_OFF);
    } else if agent.battery != 0 {
        s.headlamp = true;
        send_message(MSG_HEADLAMP_ON);
    } else {
        send_message(MSG_NO_BATTERY);
    }
}

// For the debug panel: every weapon with full ammo, the keys, the goggles, cleats and mask,
// a full battery, health and shields. The mission's own items (plans, codes and the rest)
// stay out, since picking them up is what completes goals.
world_give_everything :: () {
    if !world.loaded return;
    for cast(s32) Item_Slot.PISTOL..cast(s32) Item_Slot.MASK  agent.items[it] = -1;
    agent.detonator_weapon, agent.mine_weapon = -1, -1;
    for * agent.ammo  it.* = AMMO_MAX[it_index];
    agent.battery = BATTERY_FULL;
    agent.health = HEALTH_MAX;
    if agent.shields >= 0  agent.shields = SHIELDS_MAX;
}

// The goggles (0x2a508, 0x2a628): only with them in the inventory, on only with charge in
// the battery.
world_toggle_goggles :: () {
    if !world.loaded || !agent.items[Item_Slot.GOGGLES] return;
    s := *world.player_state;
    if s.goggles_on {
        turn_goggles_off();
        send_message(MSG_GOGGLES_OFF);
    } else if agent.battery != 0 {
        s.goggles_on = true;
        s.goggles_green_in = 2;
        send_message(MSG_GOGGLES_ON);
        play_player_sound(.GOGGLES_ON);
    } else {
        send_message(MSG_NO_BATTERY);
        play_player_sound(.GOGGLES_EMPTY);
    }
}

// The cleats (0x2a610, 0x2a684): no battery.
world_toggle_cleats :: () {
    if !world.loaded || !agent.items[Item_Slot.CLEATS] return;
    s := *world.player_state;
    s.cleats_on = !s.cleats_on;
    if s.cleats_on  send_message(MSG_CLEATS_ON);
    else            send_message(MSG_CLEATS_OFF);
}

// The mask (0x2a560, 0x2a64c): on only with charge in the battery, breathing while on.
world_toggle_mask :: () {
    if !world.loaded || !agent.items[Item_Slot.MASK] return;
    s := *world.player_state;
    if s.mask_on {
        turn_mask_off();
    } else if agent.battery != 0 {
        s.mask_on = true;
        send_message(MSG_MASK_ON);
        if !s.breath_tick  start_breathing();
    } else {
        send_message(MSG_NO_BATTERY);
    }
}

// Counts a drawn frame of the view for the goggles' palette (the end of 0x50574).
world_count_view_frame :: () {
    s := *world.player_state;
    if s.goggles_green_in {
        s.goggles_green_in -= 1;
        if !s.goggles_green_in  s.goggles_green = true;
    }
    if s.goggles_green_out {
        s.goggles_green_out -= 1;
        if !s.goggles_green_out  s.goggles_green = false;
    }
}

#scope_module

// LAPOSTAL (0x29ff8): health and shields, every weapon, the goggles, cleats and mask, full
// ammo and battery. As every give below, it brings a dying player back to its feet, lying
// down.
give_weapons_and_ammo :: () {
    restore_health_for_cheat();
    for cast(s32) Item_Slot.PISTOL..cast(s32) Item_Slot.CANNON  agent.items[it] = -1;
    agent.detonator_weapon, agent.mine_weapon = -1, -1;
    for cast(s32) Item_Slot.GOGGLES..cast(s32) Item_Slot.MASK  agent.items[it] = -1;
    for * agent.ammo  it.* = AMMO_MAX[it_index];
    agent.battery = BATTERY_FULL;
    reset_weapon_frame();
}

// LABRADY (0x29eb4): health and shields, and ammo for the weapons there are, the energy,
// detonators and mines whatever; the battery.
give_ammo :: () {
    restore_health_for_cheat();
    has :: (slot: Item_Slot) -> bool { return agent.items[slot] != 0; }
    agent.ammo[Ammo.ENERGY] = AMMO_MAX[Ammo.ENERGY];
    if has(.AUTOGUN) || has(.FUSION) || has(.CONCUSSION)  agent.ammo[Ammo.POWER] = AMMO_MAX[Ammo.POWER];
    if has(.CANNON)  agent.ammo[Ammo.PLASMA] = AMMO_MAX[Ammo.PLASMA];
    agent.ammo[Ammo.DETONATOR] = AMMO_MAX[Ammo.DETONATOR];
    if has(.MORTAR)  agent.ammo[Ammo.SHELL] = AMMO_MAX[Ammo.SHELL];
    agent.ammo[Ammo.MINE] = AMMO_MAX[Ammo.MINE];
    if has(.CANNON)  agent.ammo[Ammo.MISSILE] = AMMO_MAX[Ammo.MISSILE];
    agent.battery = BATTERY_FULL;
    reset_weapon_frame();
}

// LAUNLOCK (0x29f70): the keys, the goggles, cleats and mask, and every mission item and
// code, without a word to the goals.
give_inventory :: () {
    for cast(s32) Item_Slot.RED_KEY..ITEM_SLOTS-1  agent.items[it] = -1;
}

restore_health_for_cheat :: () {
    agent.health = HEALTH_MAX;
    agent.health_fraction = 0;
    world.player_state.dying = false;
    agent.shields = SHIELDS_MAX;
}

// The agent file's item bytes, in order, by Item_Slot; -1 and -2 for the thrown weapons.
INVENTORY_SLOTS :: s32.[1, 2, -1, 3, 4, 5, -2, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 16, 17, 19,
                        20, 21, 22, 23, 24, 25, 26, 27, 28];

set_inventory_slot :: (slot: s32, value: s32) {
    if slot == {
        case -1; agent.detonator_weapon = value;
        case -2; agent.mine_weapon = value;
        case;    agent.items[slot] = value;
    }
}

get_inventory_slot :: (slot: s32) -> s32 {
    if slot == {
        case -1; return agent.detonator_weapon;
        case -2; return agent.mine_weapon;
    }
    return agent.items[slot];
}

// The level's start (0x29790).
start_player_stats :: () {
    s := *world.player_state;
    s.* = .{};
    s.current_weapon = agent.weapon;
    if agent.lives < 4  agent.lives = 3;
    if agent.shields <= 100  agent.shields = 100;
    agent.health = 100;
    agent.health_fraction = 0;
    agent.battery = BATTERY_FULL;
    // Keys, the mission's items and the codes don't come into a level.
    for 8..10   agent.items[it] = 0;
    for 14..28  agent.items[it] = 0;
    // On Jabba's ship the rest goes too, with the ammo, and the fists are in hand, until the
    // pile gives it all back. The original looks only at the level's name.
    if world.name == "JABSHIP" {
        world.pile.taken = true;
        world.pile.items = agent.items;
        world.pile.ammo = agent.ammo;
        for * agent.items  it.* = 0;
        for * agent.ammo   it.* = 0;
        s.current_weapon = WEAPON_FIST;
    }
    if world.name == "GROMAS"  s.level_light = 30;

    // The safes: SAFE objects, and the player's start (0x1520e, 0x152a9).
    for * world.level_objects.objects {
        if !is_object_in_difficulty(it, world.object_difficulty) continue;
        is_safe := it.class == .SAFE;
        if !is_safe && !has_logic(it, "PLAYER") continue;
        sector := level_find_sector(*world.level, it.position);
        if sector < 0 continue;
        array_add(*world.safes, .{sector, it.position.x, it.position.z, it.yaw});
        if is_safe  world.level.sectors[sector].flags[0] |= SECTOR_SAFE;
    }
    for world.level.sectors  if it.flags[0] & SECTOR_SECRET  s.secrets += 1;
}

// The pile (0x2a7d4): what Jabba's ship took is added back, the ammo then cut to its
// limits. The nava card goes, even one picked up before; its goal stays done.
give_back_pile :: () {
    if !world.pile.taken return;
    for * agent.items  it.* += world.pile.items[it_index];
    for * agent.ammo   it.* += world.pile.ammo[it_index];
    agent.items[Item_Slot.NAVA] = 0;
    if agent.highest_weapon != world.weapon.current  request_weapon(agent.highest_weapon);
    world.pile.taken = false;
    for * agent.ammo  it.* = clamp(it.*, 0, AMMO_MAX[it_index]);
}

// The player task starts with the safe of the sector it's in, if there is one.
find_safe :: (sector: s32) -> *Safe {
    for * world.safes  if it.sector == sector return it;
    return null;
}

// Damage to health and shields (0x2ecf0). Shields take half the shield damage, and when they
// fall under 50 health takes part of the rest, more the lower they are; then shields take
// the other half. Health damage keeps a fraction of a point.
apply_damage :: (health_damage: Fixed, shield_damage: Fixed, play_sound: bool) {
    s := *world.player_state;
    health := (agent.health << 16) + agent.health_fraction;
    if s.invincible == -2 || health == 0 || shield_damage < 0 return;
    tick := world.clock.tick;
    if shield_damage != 0 && s.shields_safe_until < tick {
        shields := (agent.shields << 16) - shield_damage / 2;
        if shields < 0  shields = 0;
        if shields < 50 * FIXED_ONE {
            health_damage += mul16(FIXED_ONE - div16(shields, 50 * FIXED_ONE), shield_damage);
        }
        left := shields - shield_damage / 2;
        if left < 0  left = 0;
        agent.shields = clamp(left >> 16, 0, SHIELDS_MAX);
        if play_sound  play_player_sound(.SHIELD_HIT);
        s.shield_fx = min(s.shield_fx + shield_damage * 4, 17 * FIXED_ONE);
    }
    if health_damage != 0 {
        left := health - health_damage;
        if left < FIXED_ONE {
            agent.health_fraction = 0;
            agent.health = 0;
            if play_sound  play_player_sound(.DIE);
            stop_choking();
            if s.mask_on  turn_mask_off();
            s.dying = true;
            s.revive_tick = tick + REVIVE_DELAY;
        } else {
            if play_sound && s.hurt_sound_after < tick {
                play_player_sound(.HURT);
                s.hurt_sound_after = tick + 72;
            }
            agent.health = left >> 16;
            agent.health_fraction = left & 0xFFFF;
        }
        s.health_fx += health_damage / 2;
        if s.health_fx > 0x10FFFF  s.health_fx = 17 * FIXED_ONE;
        if s.health_fx <= FIXED_ONE  s.health_fx = FIXED_ONE;
    }
}

// The goggles off (0x51f10): the view at once, the palette three frames on.
turn_goggles_off :: () {
    s := *world.player_state;
    s.goggles_on = false;
    s.goggles_green_out = 3;
}

turn_mask_off :: () {
    s := *world.player_state;
    send_message(MSG_MASK_OFF);
    s.mask_on = false;
    stop_breathing();
}

// The breathing task (0x2fc74), made by the main loop's keys, waits first: mask1.voc to
// the left, mask2.voc to the right, 0x123 ticks apart.
start_breathing :: () {
    s := *world.player_state;
    s.breath_tick = world.clock.tick + BREATH_TICKS;
    s.breath_out = false;
    if !world.tasks.breathing  world.tasks.breathing = add_child_task(world.tasks.main, .BREATHING);
}

stop_breathing :: () {
    world.player_state.breath_tick = 0;
    end_task(world.tasks.breathing);
    world.tasks.breathing = null;
}

// The choking task (0x2fcb4), made by the player's: it plays first, then waits.
start_choking :: () {
    world.player_state.choke_tick = world.clock.tick;
    if !world.tasks.choking  world.tasks.choking = add_child_task(world.tasks.player, .CHOKING);
}

stop_choking :: () {
    world.player_state.choke_tick = 0;
    end_task(world.tasks.choking);
    world.tasks.choking = null;
}

update_breathing :: () {
    s := *world.player_state;
    tick := world.clock.tick;
    if !s.breath_tick || tick < s.breath_tick return;
    id := play_player_sound(ifx s.breath_out then Player_Sound.BREATH_OUT else .BREATH_IN);
    set_sound_pan(id, ifx s.breath_out then cast(s32) 16 else -16);
    s.breath_out = !s.breath_out;
    s.breath_tick = tick + BREATH_TICKS;
}

update_choking :: () {
    s := *world.player_state;
    tick := world.clock.tick;
    if !s.choke_tick || tick < s.choke_tick return;
    play_player_sound(.CHOKE);
    s.choke_tick = tick + BREATH_TICKS;
}

BREATH_TICKS :: 0x123;      // 2 seconds.

// The battery's drain and what it runs (0x2e418): the headlamp a little, the mask and the
// goggles more. When it runs out, each of them goes off with its message.
update_battery :: () {
    s := *world.player_state;
    if agent.battery == 0 return;
    dt := world.clock.dt;
    if s.headlamp    agent.battery -= mul16(dt, 0x111);
    if s.mask_on     agent.battery -= mul16(dt, 0x444);
    if s.goggles_on  agent.battery -= mul16(dt, 0x444);
    if agent.battery < 1 {
        if s.goggles_on { turn_goggles_off(); send_message(MSG_GOGGLES_OFF); }
        if s.headlamp   { send_message(MSG_HEADLAMP_OFF); s.headlamp = false; }
        if s.mask_on    turn_mask_off();
        agent.battery = 0;
    }
}

// The player's light (0x2d17c's end): the headlamp, by the battery's charge up to full at
// half charge, or the weapon's light and the level's, whichever is brighter (0xfe2a0); the
// goggles see without it.
get_player_light :: () -> s32 {
    if world.player_state.goggles_on return 0;
    return get_player_light_level();
}

get_player_light_level :: () -> s32 {
    s := *world.player_state;
    lamp: s32;
    if s.headlamp {
        lamp = mul16(min(agent.battery, FIXED_ONE), 64 * FIXED_ONE) >> 16;
        lamp = min(lamp, 31);
    }
    return max(world.weapon.light + s.level_light, lamp);
}

// The tints' levels for the palette, from the effects (0x2ea24): set once a frame.
update_screen_effects :: () {
    s := *world.player_state;
    level :: (fx: Fixed, table: [16] s32) -> s32 {
        if fx == 0 return 0;
        return table[min(fx >> 16, 15)];
    }
    s.health_level = level(s.health_fx, HEALTH_LEVELS);
    s.shield_level = level(s.shield_fx, SHIELD_LEVELS);
    s.flash_level  = level(s.flash_fx, FLASH_LEVELS);
}

HEALTH_LEVELS :: s32.[4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 63];
SHIELD_LEVELS :: s32.[2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32];
FLASH_LEVELS  :: s32.[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

// The palette tinted (0x5d49c): one tint at a time, health's red over the shields' green
// over a pickup's blue. The tint's channel goes toward full by the level, the others toward
// black, in the DAC's 6-bit values.
apply_screen_effects :: (palette: *Palette) {
    s := *world.player_state;
    channel, level: s32;
    if s.health_level       { channel, level = 0, s.health_level; }
    else if s.shield_level  { channel, level = 1, s.shield_level; }
    else if s.flash_level   { channel, level = 2, s.flash_level; }
    else return;
    keep := 63 - (level & 63);
    for * palette.colors {
        c: [3] s32 = .[it.r >> 2, it.g >> 2, it.b >> 2];
        for i: 0..2 {
            if i == channel  c[i] = 63 - (((63 - c[i]) * keep) >> 6);
            else             c[i] = (c[i] * keep) >> 6;
        }
        it.* = .{expand_6_bit(xx c[0]), expand_6_bit(xx c[1]), expand_6_bit(xx c[2])};
    }
}

// The goggles' green (0x5d434): each color's brightness, a quarter of red and blue and half
// of green in 6 bits, each part truncated, in green alone.
apply_goggles_palette :: (palette: *Palette) {
    if !world.player_state.goggles_green return;
    for * palette.colors {
        g := (it.b >> 4) + (it.g >> 3) + (it.r >> 4);
        it.* = .{0, expand_6_bit(g), 0};
    }
}

// Each tick, the tints fade (0x1f05f).
fade_screen_effects :: () {
    s := *world.player_state;
    if s.health_fx  s.health_fx = max(s.health_fx - 0x1999, 0);
    if s.shield_fx  s.shield_fx = max(s.shield_fx - 0x3333, 0);
    if s.flash_fx   s.flash_fx  = max(s.flash_fx - 0x9999, 0);
}

// Damage from where the player stands (0x2d17c): floors that hurt, gas without the mask
// (choking), walls that hurt to touch.
apply_floor_damage :: (p: *Player) {
    s := *world.player_state;
    dt := world.clock.dt;
    sector := *world.level.sectors[p.floor_sector];
    kind := sector.flags[0] & (SECTOR_LOW_DAMAGE | SECTOR_HIGH_DAMAGE);
    if kind == SECTOR_LOW_DAMAGE && p.on_floor        apply_damage(mul16(dt, 5 * FIXED_ONE), 0, true);
    else if kind == SECTOR_HIGH_DAMAGE && p.on_floor  apply_damage(mul16(dt, 10 * FIXED_ONE), 0, true);
    else if kind == SECTOR_LOW_DAMAGE | SECTOR_HIGH_DAMAGE && !s.mask_on {
        apply_damage(mul16(dt, 5 * FIXED_ONE), 0, false);
        // The choking task (0x2fcb4), until out of the gas or masked.
        if !s.choke_tick && !s.dying  start_choking();
    }
    if s.choke_tick && (kind != SECTOR_LOW_DAMAGE | SECTOR_HIGH_DAMAGE || s.mask_on)  stop_choking();
    if p.slide_wall && (p.slide_wall.flags[0] & WALL_DAMAGE)  apply_damage(mul16(dt, 20 * FIXED_ONE), 0, true);
}

// Dying (0x2ef44): the eye sinks to the floor, the view tips up and rolls; once the delay is
// over a key brings the player back at the last safe place for a life, or ends the level.
update_dying :: (p: *Player, input: World_Input) {
    s := *world.player_state;
    dt := world.clock.dt;
    p.min_eye = FIXED_ONE;
    p.crouch_speed = 0x5B332;
    p.pitch = clamp(p.pitch + mul16(dt, 0x6AA), -0x3FF, 0x3FF);
    p.roll = clamp(p.roll - mul16(dt, 0xD55), -0x638, 0x638);
    if world.clock.tick < s.revive_tick || !input.revive return;
    if agent.lives != 0 && s.has_safe {
        agent.lives -= 1;
        revive_player(p);
        p.yaw = s.safe.yaw;
        p.object_yaw = p.yaw;
        p.position.x = s.safe.x;
        p.position.z = s.safe.z;
        sector := *world.level.sectors[s.safe.sector];
        p.y = sector.floor.altitude + sector.second_altitude;
        p.position.y = p.y;
        s.headlamp = false;
        change_player_sector(p, s.safe.sector);
        s.shields_safe_until = world.clock.tick + REVIVE_DELAY;
        s.invincible = 0;
        return;
    }
    revive_player(p);
    s.level_failed = true;
}

// Back on its feet: the stats (0x29d54), then the player's motion (0x2a0cc).
revive_player :: (p: *Player) {
    revive_stats();
    reset_player_motion(p);
}

revive_stats :: () {
    agent.shields = 100;
    agent.health = 100;
    agent.health_fraction = 0;
    world.player_state.dying = false;
}

reset_player_motion :: (p: *Player) {
    p.yaw_speed, p.pitch, p.roll = 0, 0, 0;
    p.forward, p.strafe = 0, 0;
    p.max_move = 32 * FIXED_ONE;
    p.min_eye = 2 * FIXED_ONE;
    p.land_squash, p.land_velocity = 0, 0;
    p.velocity, p.external = .{}, .{};
    p.up_velocity, p.tick_up_velocity = 0, 0;
    p.speed_average, p.bob = 0, 0;
    p.on_floor = false;
    p.rise_speed = -0x84000;
    p.crouch_speed = 0;
    p.fallen = 0;
    p.height = PLAYER_HEIGHT;
}

// A sector entered (0x2d17c): its safe becomes the place to come back to; a secret is
// found once.
on_player_entered_sector :: (p: *Player, from: s32) {
    s := *world.player_state;
    sector := *world.level.sectors[p.sector];
    // Onto another layer, the map follows.
    if from >= 0 && world.level.sectors[from].layer != sector.layer  set_automap_layer(sector.layer);
    if sector.flags[0] & SECTOR_SAFE {
        safe := find_safe(p.sector);
        if safe { s.safe = safe.*; s.has_safe = true; }
    }
    if sector.flags[0] & SECTOR_SECRET {
        sector.flags[0] &= ~cast(u32) SECTOR_SECRET;
        s.secrets_found += 1;
        if s.secrets == 0  s.secrets_percent = 100;
        else s.secrets_percent = mul16(div16(int_to_fixed(s.secrets_found), int_to_fixed(s.secrets)), int_to_fixed(100)) >> 16;
        s.secrets_percent = clamp(s.secrets_percent, 0, 100);
    }
}

REVIVE_DELAY :: 436;        // Ticks: 3 seconds.

Player_Sound :: enum u8 { JUMP; LAND; SPLASH; FALL; CRUSH; HURT; DIE; SHIELD_HIT; GOGGLES_ON; GOGGLES_EMPTY; BREATH_IN; BREATH_OUT; CHOKE; }

// TEXT.MSG's numbers for the items' messages.
MSG_GOGGLES_OFF  :: 9;
MSG_GOGGLES_ON   :: 10;
MSG_NO_BATTERY   :: 11;
MSG_HEADLAMP_OFF :: 12;
MSG_HEADLAMP_ON  :: 13;
MSG_MASK_OFF     :: 19;
MSG_MASK_ON      :: 20;
MSG_CLEATS_OFF   :: 21;
MSG_CLEATS_ON    :: 22;
