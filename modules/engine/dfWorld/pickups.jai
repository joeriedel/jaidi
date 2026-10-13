// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Things in the level that take up room or can be picked up, and picking them up, as DARK.EXE
// does it.
//
// Each placed object gets a size (objects.jai), unless its logic block gives RADIUS: or
// HEIGHT:. Items (LOGIC: ITEM name, or the name alone) are pickups a quarter unit tall
// (0x30e8a).
//
// After every move that succeeds the player sweeps, its width grown by 1.5, through the
// sectors it reaches (0x5af40): an item whose box it overlaps at its height is offered to it
// (0x31a16). Accepted, it gives what it gives, shows its message, sounds, flashes the screen
// blue and goes; refused (ammo at its cap and the like) it stays, silent.

#scope_module

// Sizes for the O file's objects, and the items among them.
set_object_sizes :: () {
    for * l, index: world.level_objects.objects {
        o := world.objects[index];
        set_object_size(o, l.radius, l.height);
        item := get_item_kind(l);
        if item >= 0  make_pickup(o, item);
    }
}

// Items are pickups a quarter unit tall (0x30e8a).
make_pickup :: (o: *Object, item: s32) {
    o.item = item;
    o.flags |= OBJECT_PICKUP;
    o.height = 0x4000;
    type := ITEMS[item].type;
    if type == .OBJECTIVE || type == .CODE  o.flags |= OBJECT_STAYS;
}

register_item_sounds :: () {
    world.item_sounds[0] = register_sound("KEY.VOC", 0x54);
    world.item_sounds[1] = register_sound("COMPLETE.VOC", 0x7F);
    world.item_sounds[2] = register_sound("BONUS.VOC", 0x7B);
    world.item_sounds[3] = register_sound("QUARTER.VOC", 0x7B);
}

// The sweep after a move (0x2d17c, 0x5af40).
on_player_moved :: (p: *Player) {
    c := *world.collision;
    c.width += 0x18000;
    for_each_sector_reached(c, p.sector, check_pickups);
    c.width -= 0x18000;
}

// The powerups' timers (the tasks at 0x2fbe8 and 0x48238): 45 seconds, then four blinks
// of 87 ticks off and on, the HUD showing normal shields (or ammo) in the off half; then the
// shields are 200.
update_invincibility :: () {
    s := *world.player_state;
    tick := world.clock.tick;
    if s.invincible != -1 || tick < s.invincible_until return;
    if s.invincible_blinks < 8 {
        if s.invincible_blinks % 2 == 0 {
            play_sound(world.item_sounds[3]);
            agent.shields = 200;
        } else {
            agent.shields = -1;
        }
        s.invincible_blinks += 1;
        s.invincible_until = tick + BLINK_TICKS;
        return;
    }
    agent.shields = 200;
    s.invincible = 0;
    // The task ends in its turn.
    t := world.tasks.invincibility;
    world.tasks.invincibility = null;
    end_task(t);
}

update_supercharge :: () {
    s := *world.player_state;
    tick := world.clock.tick;
    if !s.supercharged_until || tick < s.supercharged_until return;
    if s.supercharge_blinks < 8 {
        s.supercharged = s.supercharge_blinks % 2 == 1;
        s.supercharge_blinks += 1;
        s.supercharged_until = tick + BLINK_TICKS;
        return;
    }
    s.supercharged = false;
    s.supercharged_until = 0;
    t := world.tasks.supercharge;
    world.tasks.supercharge = null;
    end_task(t);
}

// The supercharge (0x481e4): a new timer in place of any running, the child of the task
// that starts it.
start_supercharge :: (parent: *Task) {
    s := *world.player_state;
    s.supercharged = true;
    s.supercharged_until = world.clock.tick + POWERUP_TICKS;
    s.supercharge_blinks = 0;
    t := *world.tasks;
    end_task(t.supercharge);
    t.supercharge = add_child_task(parent, .SUPERCHARGE);
}

ITEM_RIFLE      :: 5;
ITEM_CONCUSSION :: 9;
ITEM_POWER      :: 12;
ITEM_PLASMA     :: 13;
ITEM_DETONATORS :: 15;      // Five.
ITEM_MISSILES   :: 21;
ITEM_BATTERY    :: 29;

// The items' art, by kind (0xe65b0), for those the game makes itself.
ITEM_ART :: string.["IDPLANS.WAX", "IPHRIK.WAX", "INAVA.WAX", "IDTGUN.WAX", "IDATA.FME",
    "IST-GUNI.FME", "IAUTOGUN.FME", "IMORTAR.FME", "IFUSION.FME", "ICONCUS.FME", "ICANNON.FME",
    "IENERGY.FME", "IPOWER.FME", "IPLAZMA.FME", "IDET.FME", "IDETS.FME", "ISHELL.FME",
    "ISHELLS.FME", "IMINE.FME", "IMINES.FME", "IMSL.FME", "IMSLS.FME", "IARMOR.WAX", "IKEYR.FME",
    "IKEYY.FME", "IKEYB.FME", "IGOGGLES.FME", "ICLEATS.FME", "IMASK.FME", "IBATTERY.FME",
    "DET_CODE.FME", "DET_CODE.FME", "DET_CODE.FME", "DET_CODE.FME", "DET_CODE.FME",
    "DET_CODE.FME", "DET_CODE.FME", "DET_CODE.FME", "DET_CODE.FME", "IINVINC.WAX", "ICHARGE.FME",
    "IREVIVE.WAX", "ILIFE.WAX", "IMEDKIT.FME", "IPILE.FME"];

#scope_file

POWERUP_TICKS :: 0x199A;    // 45 seconds.
BLINK_TICKS :: 87;

// The item an object's logic names (0x1582e): LOGIC: ITEM name or LOGIC: name. A name the
// table doesn't know, after ITEM, is the plans.
get_item_kind :: (object: *Level_Object) -> s32 {
    for object.logics {
        words := split(it, " ",, temp);
        if !words continue;
        name := words[0];
        is_item := name == "ITEM";
        if is_item  name = ifx words.count > 1 then words[1] else "";
        for ITEM_NAMES  if it == name return ITEM_KINDS[it_index];
        if is_item return 0;
    }
    return -1;
}

ITEM_NAMES :: string.["BATTERY", "BLUE", "CANNON", "CLEATS", "CODE1", "CODE2", "CODE3", "CODE4",
    "CODE5", "CODE6", "CODE7", "CODE8", "CODE9", "CONCUSSION", "DETONATOR", "DETONATORS",
    "DT_WEAPON", "DATATAPE", "ENERGY", "FUSION", "GOGGLES", "MASK", "MINE", "MINES", "MISSILE",
    "MISSILES", "MORTAR", "NAVA", "PHRIK", "PLANS", "PLASMA", "POWER", "RED", "RIFLE", "SHELL",
    "SHELLS", "SHIELD", "INVINCIBLE", "REVIVE", "SUPERCHARGE", "LIFE", "MEDKIT", "PILE",
    "YELLOW", "AUTOGUN"];
ITEM_KINDS :: s32.[29, 25, 10, 27, 30, 31, 32, 33, 34, 35, 36, 37, 38, 9, 14, 15, 3, 4, 11, 8, 26,
    28, 18, 19, 20, 21, 7, 2, 1, 0, 13, 12, 23, 5, 16, 17, 22, 39, 41, 40, 42, 43, 44, 24, 6];

// The pickups' kinds (0x30e8a): what each is and gives.
Item_Type :: enum s32 { OBJECTIVE :: 1; WEAPON :: 2; AMMO :: 4; USABLE :: 8; CODE :: 16; POWERUP :: 32; SPECIAL :: 64; }

Item_Value :: enum u8 { NONE; ENERGY; POWER; PLASMA; DETONATOR; SHELL; MINE; MISSILE; SHIELDS; HEALTH; BATTERY; }

Item :: struct {
    type: Item_Type;
    slot: s32 = -1;             // Agent.items, or -1.
    value: Item_Value;          // What it adds to.
    amount: s32;
    max: s32;
    message, message_owned: s32 = -1;
    weapon: s32 = -1;
}

ITEMS :: Item.[
    .{.OBJECTIVE, 14, .NONE, 0, 0, 400, -1, -1},          // Plans
    .{.OBJECTIVE, 15, .NONE, 0, 0, 401, -1, -1},          // Phrik
    .{.OBJECTIVE, 18, .NONE, 0, 0, 402, -1, -1},          // Nava
    .{.OBJECTIVE, 19, .NONE, 0, 0, 405, -1, -1},          // DT weapon
    .{.OBJECTIVE, 16, .NONE, 0, 0, 406, -1, -1},          // Datatape
    .{.WEAPON, 2, .ENERGY, 15, 500, 100, 101, 2},         // Rifle
    .{.WEAPON, 3, .POWER, 30, 500, 103, 104, 4},          // Autogun
    .{.WEAPON, 4, .SHELL, 3, 50, 105, 106, 6},            // Mortar
    .{.WEAPON, 5, .POWER, 50, 500, 107, 108, 5},          // Fusion
    .{.WEAPON, 6, .POWER, 100, 500, 110, 111, 8},         // Concussion
    .{.WEAPON, 7, .PLASMA, 30, 400, 112, 113, 9},         // Cannon
    .{.AMMO, -1, .ENERGY, 15, 500, 200, -1, -1},
    .{.AMMO, -1, .POWER, 10, 500, 201, -1, -1},
    .{.AMMO, -1, .PLASMA, 20, 400, 202, -1, -1},
    .{.AMMO, -1, .DETONATOR, 1, 50, 203, -1, -1},
    .{.AMMO, -1, .DETONATOR, 5, 50, 204, -1, -1},
    .{.AMMO, -1, .SHELL, 1, 50, 205, -1, -1},
    .{.AMMO, -1, .SHELL, 5, 50, 206, -1, -1},
    .{.AMMO, -1, .MINE, 1, 30, 207, -1, -1},
    .{.AMMO, -1, .MINE, 5, 30, 208, -1, -1},
    .{.AMMO, -1, .MISSILE, 1, 20, 209, -1, -1},
    .{.AMMO, -1, .MISSILE, 5, 20, 210, -1, -1},
    .{.AMMO, -1, .SHIELDS, 20, 200, 114, -1, -1},         // Shield
    .{.USABLE, 8, .NONE, 0, 0, 300, -1, -1},              // Red key
    .{.USABLE, 9, .NONE, 0, 0, 301, -1, -1},              // Yellow key
    .{.USABLE, 10, .NONE, 0, 0, 302, -1, -1},             // Blue key
    .{.USABLE, 11, .BATTERY, 0x10000, 0x20000, 303, -1, -1},  // Goggles
    .{.USABLE, 12, .NONE, 0, 0, 304, -1, -1},             // Cleats
    .{.USABLE, 13, .BATTERY, 0x10000, 0x20000, 305, -1, -1},  // Mask
    .{.AMMO, -1, .BATTERY, 0x10000, 0x20000, 211, -1, -1},    // Battery
    .{.CODE, 20, .NONE, 0, 0, 501, -1, -1},
    .{.CODE, 21, .NONE, 0, 0, 502, -1, -1},
    .{.CODE, 22, .NONE, 0, 0, 503, -1, -1},
    .{.CODE, 23, .NONE, 0, 0, 504, -1, -1},
    .{.CODE, 24, .NONE, 0, 0, 505, -1, -1},
    .{.CODE, 25, .NONE, 0, 0, 506, -1, -1},
    .{.CODE, 26, .NONE, 0, 0, 507, -1, -1},
    .{.CODE, 27, .NONE, 0, 0, 508, -1, -1},
    .{.CODE, 28, .NONE, 0, 0, 509, -1, -1},
    .{.POWERUP, -1, .NONE, 0, 0, 306, -1, -1},            // Invincible
    .{.POWERUP, -1, .NONE, 0, 0, 307, -1, -1},            // Supercharge
    .{.POWERUP, -1, .NONE, 0, 0, 308, -1, -1},            // Revive
    .{.POWERUP, -1, .NONE, 0, 0, 310, -1, -1},            // Life
    .{.AMMO, -1, .HEALTH, 20, 100, 311, -1, -1},          // Medkit
    .{.SPECIAL, -1, .NONE, 0, 0, -1, -1, -1},             // Pile
];

ITEM_SHIELD      :: 22;
ITEM_CLEATS      :: 27;
ITEM_INVINCIBLE  :: 39;
ITEM_SUPERCHARGE :: 40;
ITEM_REVIVE      :: 41;
ITEM_LIFE        :: 42;
OBJECTIVE_GOALS  :: s32.[0, 1, 2, 5, 4];     // The item number each objective counts as.

// The value an item adds to.
get_value :: (value: Item_Value) -> *s32 {
    if #complete value == {
        case .NONE;    return null;
        case .ENERGY;  return *agent.ammo[Ammo.ENERGY];
        case .POWER;   return *agent.ammo[Ammo.POWER];
        case .PLASMA;  return *agent.ammo[Ammo.PLASMA];
        case .DETONATOR; return *agent.ammo[Ammo.DETONATOR];
        case .SHELL;   return *agent.ammo[Ammo.SHELL];
        case .MINE;    return *agent.ammo[Ammo.MINE];
        case .MISSILE; return *agent.ammo[Ammo.MISSILE];
        case .SHIELDS; return *agent.shields;
        case .HEALTH;  return *agent.health;
        case .BATTERY; return *agent.battery;
    }
    return null;
}

// Adds an amount, held between 0 and the cap (0x481d4).
add_to_value :: (value: *s32, amount: s32, max: s32) {
    v := value.* + amount;
    if v < 0  v = 0;
    if v > max  v = max;
    value.* = v;
}

// The sweep's look at a sector's objects (0x5af40). A sector with no height between its
// floor and ceiling isn't looked into, nor through.
check_pickups :: (c: *Collision, sector_index: s32) -> bool {
    sector := *world.level.sectors[sector_index];
    if sector.floor.altitude == sector.ceiling.altitude return false;
    for index: walk_sector(sector_index) {
        t := world.objects[index];
        if !t.width || !(t.flags & OBJECT_PICKUP) continue;
        reach := t.width + c.width;
        if abs(t.position.x - c.dst.x) >= reach || abs(t.position.z - c.dst.z) >= reach continue;
        if t.position.y - t.height < c.dst_y && c.dst_y - c.height < t.position.y  pick_up(index);
    }
    return true;
}

// The item's logic, offered to the player (0x31a16).
pick_up :: (index: s32) {
    s := *world.player_state;
    if s.dying return;
    t := world.objects[index];
    kind := t.item;
    item := ITEMS[kind];
    slot := ifx item.slot >= 0 then *agent.items[item.slot] else null;
    value := get_value(item.value);
    accepted := true;
    if item.type == {
        case .OBJECTIVE;
            slot.* = -1;
            send_message(item.message);
            on_objective_taken();
            s.items_done[OBJECTIVE_GOALS[kind]] = true;
        case .WEAPON;
            if slot.* == 0 || value.* < item.max {
                add_to_value(value, item.amount, item.max);
                if slot.* == 0 {
                    slot.* = -1;
                    send_message(item.message);
                    on_weapon_picked_up(item.weapon);
                } else {
                    send_message(item.message_owned);
                }
            } else {
                accepted = false;
            }
        case .AMMO;
            if kind == ITEM_SHIELD && s.invincible != 0  accepted = false;
            if accepted && value.* < item.max {
                was_empty := is_weapon_empty();
                add_to_value(value, item.amount, item.max);
                send_message(item.message);
                on_ammo_picked_up(kind, was_empty);
            } else {
                accepted = false;
            }
        case .USABLE;
            slot.* = -1;
            send_message(item.message);
            // The battery only adds to a battery with some charge in it.
            if value && value.* != 0  add_to_value(value, item.amount, item.max);
            if kind == ITEM_CLEATS && !s.cleats_on  s.cleats_on = true;
        case .CODE;
            slot.* = -1;
            send_message(item.message);
        case .POWERUP;
            if kind == {
                case ITEM_INVINCIBLE;
                    // Its task's start (0x2a20c) also ends the mask's breathing, the mask
                    // left on, and the choking.
                    stop_breathing();
                    stop_choking();
                    s.invincible = -1;
                    agent.shields = -1;
                    s.invincible_until = world.clock.tick + POWERUP_TICKS;
                    s.invincible_blinks = 0;
                    // A new timer in place of any running, the pickups' task's child.
                    t := *world.tasks;
                    end_task(t.invincibility);
                    t.invincibility = add_child_task(t.pickups, .INVINCIBILITY);
                case ITEM_SUPERCHARGE;
                    start_supercharge(world.tasks.pickups);
                case ITEM_REVIVE;
                    if agent.health < 100 || agent.shields < 200 {
                        revive_stats();
                        agent.shields = 200;
                    } else {
                        accepted = false;
                    }
                case ITEM_LIFE;
                    if agent.lives < LIVES_MAX  agent.lives += 1;
                    else accepted = false;
            }
            if accepted  send_message(item.message);
        case .SPECIAL;
            // The pile, on Jabba's ship: the inventory taken at the level's start comes back.
            send_message(312);
            give_back_pile();
            s.items_done[6] = true;
            on_objective_taken();
    }
    if !accepted return;

    sound: s32;
    if item.type == {
        case .OBJECTIVE; #through;
        case .SPECIAL;   sound = 1;
        case .USABLE;    #through;
        case .POWERUP;   sound = 2;
        case;            sound = 0;
    }
    play_sound(world.item_sounds[sound]);
    s.flash_fx = 15 * FIXED_ONE;
    free_object(index);
}

// An objective tells the level's "complete" sector (INF, to come).
on_objective_taken :: () {
    send_objective_taken();
}
