// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The player's weapons, as DARK.EXE runs them: the table (0x41500, art 0x41f54), the weapon
// task (0x428f0) and the fire functions (0xe6b38), one for each of the ten weapons.
//
// The task is one of the original's coroutines, written here as the places it waits at. It
// sleeps until a message wakes it: 2 switches weapons (lowering the one in hand, raising the
// next), 4 starts firing (primary or secondary), 5 stops, 6 holsters or brings the weapon
// back. While firing, each pass of its loop fires if a shot is owed, then plays the weapon's
// animation, a frame held so many ticks. Shots are owed by the timer: while firing, every so
// many ticks by the weapon (0x43368; 71 for the pistol) it adds one (0x1eef2, counted in
// 0x1ef6c), and a fresh press makes one owed at once. Late frames can owe two, and then two
// bolts go, the first a shot's length ahead.
//
// Messages come from the player's task, between the weapon task's runs, and are taken in at
// once where the task waits (0x47c90): a wait goes on to its first deadline, since the
// scheduler (0x1d793) only sets one when the task itself yields, not when a message hands
// control back. A yield of no ticks runs the task again on the next frame. The task runs
// before the player's each frame, so a press fires on the next frame.
//
// The weapon is drawn over the view in 320x200 from its frame's place, swayed by the player's
// walking (not while firing), turned with the view's pitch and roll, moved by raising and
// lowering, and lit as if 6 units off in the player's sector; the muzzle flash lights the
// world. A holstered weapon isn't drawn.

WEAPON_FIST       :s32: 0;
WEAPON_PISTOL     :s32: 1;
WEAPON_RIFLE      :s32: 2;
WEAPON_DETONATOR  :s32: 3;
WEAPON_REPEATER   :s32: 4;
WEAPON_FUSION     :s32: 5;
WEAPON_MORTAR     :s32: 6;
WEAPON_MINES      :s32: 7;
WEAPON_CONCUSSION :s32: 8;
WEAPON_CANNON     :s32: 9;
WEAPON_COUNT      :: 10;

// Alt+F8: when the weapon in hand runs dry, switch to the best one with ammo (0x42e78). Off
// in the retail JEDI.CFG. A setting, kept across levels.
world_toggle_weapon_auto_switch :: () {
    weapon_auto_switch = !weapon_auto_switch;
    if world.loaded  send_message(ifx weapon_auto_switch then MSG_AUTO_SWITCH_ON else MSG_AUTO_SWITCH_OFF);
}

world_is_weapon_auto_switch_on :: () -> bool { return weapon_auto_switch; }

// F8 (0x2ea08): holster the weapon, or bring it back.
world_holster_weapon :: () {
    if world.loaded  send_weapon_message(6);
}

// F9 and F10 (0x2e834): the previous or next weapon the agent has, from the one the task
// holds, round through the fists.
world_cycle_weapon :: (direction: s32) {
    if !world.loaded return;
    w := *world.weapon;
    step: s32 = ifx direction < 0 then cast(s32) -1 else 1;
    weapon := w.task_weapon;
    while true {
        weapon += step;
        if weapon < 0  weapon = 10;
        if weapon == 11  weapon = 0;
        if weapon > 9 continue;
        if weapon == WEAPON_DETONATOR && !agent.detonator_weapon continue;
        if is_weapon_selectable(weapon) break;
    }
    if weapon != w.current  request_weapon(weapon);
}

// Backspace (0x2e3ac): back to the weapon held before.
world_swap_weapon :: () {
    if world.loaded && world.weapon.current != -1  request_weapon(-1);
}

world_get_weapon :: () -> s32 { return world.weapon.current; }

// For tests and dev options: the agent given the weapon, its ammo filled if there's none, and
// the weapon put in hand at once.
world_give_weapon :: (weapon: s32) {
    if !world.loaded || weapon < 0 || weapon >= WEAPON_COUNT return;
    slot := WEAPON_SLOTS[weapon];
    if slot > 0  agent.items[slot] = -1;
    if weapon == WEAPON_DETONATOR  agent.detonator_weapon = -1;
    if weapon == WEAPON_MINES      agent.mine_weapon = -1;
    w := *world.weapon;
    for kind: s32.[w.weapons[weapon].ammo, w.weapons[weapon].secondary_ammo] {
        if kind >= 0 && !agent.ammo[kind]  agent.ammo[kind] = AMMO_MAX[kind];
    }
    select_weapon(weapon);
}
world_is_weapon_holstered :: () -> bool { return world.weapon.holstered; }

// How far the weapon in hand is lowered, in 320x200 pixels.
world_get_weapon_offset :: () -> s32, s32 {
    weapon := *world.weapon.weapons[world.weapon.current];
    return weapon.x_offset, weapon.y_offset;
}

#scope_module

weapon_auto_switch: bool;

MSG_AUTO_SWITCH_OFF :s32: 23;
MSG_AUTO_SWITCH_ON  :s32: 24;

Player_Weapon :: struct {
    frame_count: s32;
    images: [8] Gpu_Image;
    frame: s32;
    x, y: [8] s32;              // Each frame's place on the 320x200 screen.
    flags: u32 = 7;             // WEAPON_TURNS, WEAPON_SWAYS, WEAPON_MOVES.
    x_offset, y_offset: s32;    // Raising and lowering.
    ammo: s32 = -1;             // Into agent.ammo, -1 for none;
    secondary_ammo: s32 = -1;   // the secondary fire's, if its own.
    wake_range: Fixed;          // Enemies within it hear it fire.
    variation, secondary_variation: s32;    // Angle units of scatter.
}

WEAPON_TURNS :u32: 0x1;         // With the view's roll and pitch.
WEAPON_SWAYS :u32: 0x2;         // With walking.
WEAPON_MOVES :u32: 0x4;         // By its offset.

// Where the task waits: each the code after one of the original's yields.
Weapon_Resume :: enum u8 {
    SLEEP;                      // At the loop's bottom, for a message.
    SWITCH_YIELD;               // Woken by 2, 4, 5 or 6: on next frame.
    FIRE_YIELD;
    STOP_YIELD;
    HOLSTER_YIELD;
    MOVE_START;                 // Raising or lowering (0x47d9c): its first frame,
    MOVE_STEP;                  // then a step every so many ticks.
    LOOP_TOP;                   // The firing loop's top, waiting for the frame's run.
    NO_SHOT;                    // No shot owed: the loop again next frame.
    FIRING;                     // A frame of a fire function held.
    CHARGE_START;               // The detonator held back: from the next frame,
    CHARGING;                   // each frame while fire is held,
    CHARGE_END;                 // then thrown on the frame after it's let go.
}

// What follows a raise or a lower.
Weapon_After :: enum u8 {
    LOOP;                       // The firing loop's test.
    AFTER_FIRE;                 // Back from a fire function: a switch asked for, then the loop.
    FIRE_REST;                  // The rest of the press (message 4) that raised the weapon.
    SWITCH;                     // Lowered for a switch: the next weapon, raised.
    HOLSTER;                    // Lowered to holster.
    YIELD_REST;                 // Raised by a press taken in at a message's yield: its rest.
    MINE_SET;                   // The hand lowered with a mine: set it down, raise the hand.
}

// A frame of a fire function's animation: shown, the flash's light set (-1 left), held.
Fire_Step :: struct {
    frame, light: s32;
    ticks, supercharged_ticks: s32;
    action: Fire_Action;
}

Fire_Action :: enum u8 {
    NONE;
    PUNCH;                      // The fists' blow.
    EMPTY;                      // Nothing owed either way, maybe a better weapon;
    EMPTY_PRIMARY;              // nothing owed of the primary, maybe a better weapon;
    EMPTY_SECONDARY;            // nothing owed of the secondary, maybe a better weapon;
    EMPTY_MISSILES;             // nothing owed of the secondary.
    LIGHT_OFF;
    CHARGE;                     // The detonator held back while fire is held.
    AFTER_THROW;                // Another detonator in hand, or the empty one.
    SHOOT_REPEATER;             // The repeater's bolt, after its frame 1;
    SHOOT_REPEATER_SPREAD;      // its three;
    SHOOT_MISSILE;              // the cannon's missile after its frame 2.
    MORTAR_RELOAD;              // The mortar's second sound.
    FUSION_BARRELS;             // The next barrel, a step for each shot.
    CANNON_AGAIN;               // The cannon's frame again while firing, else at rest.
}

Weapon_State :: struct {
    weapons: [WEAPON_COUNT] Player_Weapon;
    mask: Gpu_Image;            // GMASK.BM (0xfed10), loaded with the weapons' art.
    current: s32 = WEAPON_PISTOL;   // In hand (0xfed30, 0xe64d4).
    task_weapon: s32 = WEAPON_PISTOL;   // Being switched to (0xfed3c).
    previous: s32 = WEAPON_PISTOL;  // For Backspace (0xfe5fc).
    requested: s32;             // The weapon asked for, -1 the previous (0xfe5f8).
    switch_requested: bool;     // A switch asked for while busy (0xe6be0).
    pending: s32 = -1;          // Picked up, to be selected with the keys' (0xe64d0).
    held, secondary_held: bool; // The fire keys, as last passed to the task.
    firing: bool;               // 0xfecec
    secondary: bool;            // 0xfece8
    holstered: bool;            // 0xfed34
    owed, owed_secondary: s32;  // Shots owed (0xfe604, 0xfe5ec).
    fire_delay, secondary_delay: s32;   // Ticks between shots owed (0xe57f8, 0xe57fc),
    fire_ticks, secondary_ticks: s32;   // counted by the timer (0xfb4e4, 0xfb4dc).
    fire_frame: u32;            // Passes of the firing loop (0xe6b34).
    light: s32;                 // The muzzle flash's light (0xe6390).

    // The task: where it waits, when it runs next (-1 never; 0 the next frame), and the
    // message being taken in, if any.
    resume: Weapon_Resume;
    wake: s32 = -1;
    wait_ticks: s32;
    message, message_arg, woken_arg: s32;
    in_message: bool;
    yield_rest: Weapon_Resume;

    // Raising or lowering (0x47d9c).
    move_frame, move_dx, move_dy, move_steps, move_delay: s32;
    move_start: s32;            // The tick the step's wait began.
    move_late: bool;
    after: Weapon_After;
    after_switch: Weapon_After; // What follows the raise of a switch.

    // The fire function's animation.
    steps: [] Fire_Step;
    step_index: s32;

    fire_pitch, fire_yaw: s32;  // Where the last shot went (0xfe600, 0xfe608).
    aim_sin_pitch, aim_cos_pitch, aim_x, aim_z: Fixed;

    charge_start: s32;          // The tick the detonator was held back at.
    shots: s32;                 // Shots fired, for the fusion cutter's barrels.
    steps_buffer: [2] Fire_Step;    // Steps made up as it goes.

    sounds: [WEAPON_SOUND_COUNT] Sound_Handle;
    playing: [WEAPON_SOUND_COUNT] Sound_Instance;  // The last play of each.
}

// The weapons' sounds (0x41500), one instance of each kept so a new play stops the last.
Weapon_Sound :: enum u8 {
    SWING; PISTOL; PISTOL_EMPTY; RIFLE; RIFLE_EMPTY; FUSION; FUSION_EMPTY; REPEATER_LOOP;
    REPEATER; REPEATER_EMPTY; MORTAR; MORTAR_RELOAD; MORTAR_EMPTY; MINE; CONCUSSION;
    CONCUSSION_AFTER; CONCUSSION_EMPTY; CANNON; CANNON_EMPTY; MISSILE; RAISE;
}

WEAPON_SOUND_COUNT :: #run enum_highest_value(Weapon_Sound) + 1;

WEAPON_SOUND_FILES :: string.[
    "SWING.VOC", "PISTOL-1.VOC", "PISTOUT1.VOC", "RIFLE-1.VOC", "RIFLOUT.VOC", "FUSION1.VOC",
    "FUSION2.VOC", "REPEATER.VOC", "REPEAT-1.VOC", "REP-EMP.VOC", "MORTAR4.VOC", "MORTAR2.VOC",
    "MORTAR9.VOC", "CLAYMOR1.VOC", "CONCUSS6.VOC", "CONCUSS5.VOC", "CONCUSS1.VOC", "PLASMA4.VOC",
    "PLAS-EMP.VOC", "MISSILE1.VOC", "WEAPON1.VOC",
];

// The fusion cutter's barrel, 1 to 4, and which way it steps (0xe6be4, 0xe6be8): kept from
// level to level, as the original's.
fusion_barrel: s32 = 1;
fusion_barrel_rising := true;

load_weapons :: () {
    w := *world.weapon;
    w.* = .{};
    set_weapon(w, WEAPON_FIST, .["RHAND1.BM", "PUNCH1.BM", "PUNCH2.BM", "PUNCH3.BM"], .[172, 55, 59, 56], .[141, 167, 114, 141]);
    set_weapon(w, WEAPON_PISTOL, .["PISTOL1.BM", "PISTOL2.BM", "PISTOL3.BM"], .[165, 169, 169], .[142, 136, 136],
               .ENERGY, wake_range = 45, variation = 22);
    set_weapon(w, WEAPON_RIFLE, .["RIFLE1.BM", "RIFLE2.BM"], .[113, 112], .[127, 114],
               .ENERGY, wake_range = 50, variation = 86);
    // The empty hand when out of detonators or mines.
    set_weapon(w, WEAPON_DETONATOR, .["THERM1.BM", "THERM2.BM", "THERM3.BM", "RHAND1.BM"], .[161, 179, 180, 132], .[131, 165, 102, 150],
               .DETONATOR, variation = 45, secondary_variation = 45);
    set_weapon(w, WEAPON_REPEATER, .["AUTOGUN1.BM", "AUTOGUN2.BM", "AUTOGUN3.BM"], .[156, 163, 163], .[138, 140, 140],
               .POWER, wake_range = 60, variation = 45, secondary_variation = 45);
    set_weapon(w, WEAPON_FUSION, .["FUSION1.BM", "FUSION2.BM", "FUSION3.BM", "FUSION4.BM", "FUSION5.BM", "FUSION6.BM"],
               .[19, 23, 23, 23, 23, 23], .[152, 155, 155, 155, 155, 155], .POWER, wake_range = 55, variation = 45);
    set_weapon(w, WEAPON_MORTAR, .["MORTAR1.BM", "MORTAR2.BM", "MORTAR3.BM", "MORTAR4.BM"], .[123, 126, 127, 123], .[119, 117, 119, 116],
               .SHELL, wake_range = 60, variation = 45);
    set_weapon(w, WEAPON_MINES, .["CLAY1.BM", "CLAY2.BM", "RHAND1.BM"], .[105, 105, 132], .[153, 153, 150], .MINE);
    set_weapon(w, WEAPON_CONCUSSION, .["CONCUSS1.BM", "CONCUSS2.BM", "CONCUSS3.BM"], .[130, 191, 188], .[131, 129, 132],
               .POWER, wake_range = 70);
    // The first two frames reach above the screen: drawn from there, as the original's.
    set_weapon(w, WEAPON_CANNON, .["ASSAULT1.BM", "ASSAULT2.BM", "ASSAULT3.BM", "ASSAULT4.BM"], .[206, 208, 224, 230], .[-74, -60, 81, 86],
               .PLASMA, .MISSILE, wake_range = 55, variation = 45, secondary_variation = 45);
    w.weapons[WEAPON_CANNON].secondary_ammo = xx Ammo.MISSILE;
    w.mask = load_weapon_image("GMASK.BM");

    for WEAPON_SOUND_FILES  w.sounds[it_index] = register_sound(it, ifx it_index == cast(s32) Weapon_Sound.RAISE then cast(s32) 0x10 else 0x77);

    // The level's start (0x29b30): the agent's weapon in hand, raised.
    weapon := world.player_state.current_weapon;
    if weapon < 0 || weapon >= WEAPON_COUNT  weapon = WEAPON_PISTOL;
    select_weapon(weapon);
    agent.highest_weapon = max(agent.highest_weapon, weapon);
}

unload_weapons :: () {
    for * weapon: world.weapon.weapons {
        for * weapon.images  render_release_image(it);
    }
    render_release_image(*world.weapon.mask);
    world.weapon = .{};
}

// The fire keys, from the player's actions (0x2e418), primary then secondary: a press starts
// the task firing that way; a release stops it, or goes on with the other if that's held.
pass_fire_keys :: (primary: bool, secondary: bool) {
    w := *world.weapon;
    if primary && !w.held {
        w.held = true;
        send_weapon_message(4, 0);
    } else if !primary && w.held {
        w.held = false;
        if w.secondary_held  send_weapon_message(4, -1);
        else                 send_weapon_message(5);
    }
    if secondary && !w.secondary_held {
        w.secondary_held = true;
        send_weapon_message(4, -1);
    } else if !secondary && w.secondary_held {
        w.secondary_held = false;
        if w.held  send_weapon_message(4, 0);
        else       send_weapon_message(5);
    }
}

// The number keys held this frame, 1 to 0, and a weapon just picked up (0x2e418): the last
// one that can be had, if it isn't the one in hand. The detonator and mines can always be
// chosen, for the empty hand.
pass_weapon_keys :: (keys: [10] bool) {
    w := *world.weapon;
    for KEY_WEAPONS {
        if keys[it_index] && (it == WEAPON_FIST || it == WEAPON_DETONATOR || it == WEAPON_MINES || is_weapon_selectable(it))  w.pending = it;
    }
    if w.pending == -1 return;
    if w.pending != w.current  request_weapon(w.pending);
    w.pending = -1;
}

// Picked up (0x31a16): a new weapon is selected with the keys; detonators or mines while
// the empty hand shows bring the weapon back up.
on_weapon_picked_up :: (weapon: s32) { world.weapon.pending = weapon; }

on_ammo_picked_up :: (kind: s32, was_empty: bool) {
    w := *world.weapon;
    if !was_empty return;
    if w.current == WEAPON_DETONATOR && (kind == 14 || kind == 15)  send_weapon_message(2, WEAPON_DETONATOR);
    if w.current == WEAPON_MINES && (kind == 18 || kind == 19)      send_weapon_message(2, WEAPON_MINES);
}

// A switch asked of the task by the keys or the pile, the highest weapon held then kept up
// with the one in hand.
request_weapon :: (weapon: s32) {
    send_weapon_message(2, weapon);
    agent.highest_weapon = max(agent.highest_weapon, world.weapon.current);
}

// Whether the empty hand shows for want of ammo: the detonator's or the mines'.
is_weapon_empty :: () -> bool {
    w := *world.weapon;
    if w.current != WEAPON_DETONATOR && w.current != WEAPON_MINES return false;
    return agent.ammo[w.weapons[w.current].ammo] == 0;
}

// Its task's turn (0x428f0), late in the frame after the projectiles': the task, if its
// time has come.
update_weapon :: () {
    w := *world.weapon;
    if w.wake < 0 || w.wake > world.clock.tick return;
    w.message = 0;
    resume_weapon_task();
}

// The timer's counts toward the next shots owed (0x1ef6c).
count_fire_delay :: () {
    w := *world.weapon;
    if w.fire_delay {
        w.fire_ticks += 1;
        if w.fire_ticks == w.fire_delay {
            w.fire_ticks = 0;
            w.owed += 1;
        }
    }
    if w.secondary_delay {
        w.secondary_ticks += 1;
        if w.secondary_ticks == w.secondary_delay {
            w.secondary_ticks = 0;
            w.owed_secondary += 1;
        }
    }
}

// The objects drawn this frame, for the aiming help.
clear_drawn_objects :: () { array_reset_keeping_memory(*world.drawn_objects); }
note_drawn_object :: (index: s32) { array_add(*world.drawn_objects, index); }

// The weapon over the view (0x8dcd0), in 320x200 pixels.
draw_weapon :: (lighting: Lighting) {
    w := *world.weapon;
    if w.holstered return;
    weapon := *w.weapons[w.current];
    if weapon.frame < 0 || weapon.frame >= weapon.frame_count return;
    image := *weapon.images[weapon.frame];
    if !image.texture return;
    p := *world.player;
    x, y := weapon.x[weapon.frame], weapon.y[weapon.frame];
    if weapon.flags & WEAPON_TURNS {
        x += -p.roll / 13;
        y += p.pitch / 64;
    }
    if weapon.flags & WEAPON_SWAYS {
        x += p.weapon_wave;
        y += p.bob >> 13;
    }
    if weapon.flags & WEAPON_MOVES {
        x += weapon.x_offset;
        y += weapon.y_offset;
    }
    light := get_light_by_depth(lighting, world.colormap.light_ramp, 6 * FIXED_ONE);
    render_set_image(image);
    render_add_quad(.{xx x, xx y, 0}, .{xx (x + image.width), xx (y + image.height), 0}, .{0, 0}, .{xx image.width, xx image.height},
                    xx light, 0, render_pack_color(.TEXTURE_FLAT, transparent = true));
}

// The gas mask over the view (0x8dcd0), after the weapon, holstered or not: GMASK.BM swaying
// against the weapon, lit as at 2 units.
draw_mask :: (lighting: Lighting) {
    if !world.player_state.mask_on return;
    image := *world.weapon.mask;
    if !image.texture return;
    p := *world.player;
    x := 0x69 - (p.weapon_wave >> 3);
    y := 0x8D + ((p.bob >> 13) >> 2);
    light := get_light_by_depth(lighting, world.colormap.light_ramp, 2 * FIXED_ONE);
    render_set_image(image);
    render_add_quad(.{xx x, xx y, 0}, .{xx (x + image.width), xx (y + image.height), 0}, .{0, 0}, .{xx image.width, xx image.height},
                    xx light, 0, render_pack_color(.TEXTURE_FLAT, transparent = true));
}

#scope_file

// Each weapon's slot in Agent.items, 0 for none.
WEAPON_SLOTS :: s32.[0, xx Item_Slot.PISTOL, xx Item_Slot.RIFLE, 0, xx Item_Slot.AUTOGUN, xx Item_Slot.FUSION,
                     xx Item_Slot.MORTAR, 0, xx Item_Slot.CONCUSSION, xx Item_Slot.CANNON];

// The keys 1 to 0 (scancodes 2 to 11) and the weapons they choose.
KEY_WEAPONS :: s32.[WEAPON_FIST, WEAPON_PISTOL, WEAPON_RIFLE, WEAPON_DETONATOR, WEAPON_REPEATER,
                    WEAPON_FUSION, WEAPON_MINES, WEAPON_MORTAR, WEAPON_CONCUSSION, WEAPON_CANNON];

set_weapon :: (w: *Weapon_State, index: s32, names: [] string, x: [] s32, y: [] s32, ammo := Ammo.ENERGY,
               secondary_ammo := Ammo.ENERGY, wake_range: s32 = 0, variation: s32 = 0, secondary_variation: s32 = 0) {
    weapon := *w.weapons[index];
    weapon.frame_count = xx names.count;
    for names {
        weapon.images[it_index] = load_weapon_image(it);
        weapon.x[it_index] = x[it_index];
        weapon.y[it_index] = y[it_index];
    }
    if index != WEAPON_FIST  weapon.ammo = xx ammo;
    weapon.wake_range = wake_range * FIXED_ONE;
    weapon.variation = variation;
    weapon.secondary_variation = secondary_variation;
}

load_weapon_image :: (name: string) -> Gpu_Image {
    image: Gpu_Image;
    data, found := gob_find(name);
    if !found { log_error("No %.", name); return image; }
    texture, ok := bm_parse(data);
    if ok && texture.frames  image = render_upload_image(texture.frames[0]);
    texture_free(*texture);
    return image;
}

// Whether the agent has the weapon, by its slot (the detonator and mines by their ammo).
is_weapon_selectable :: (weapon: s32) -> bool {
    if weapon == {
        case WEAPON_FIST;       return true;
        case WEAPON_PISTOL;     return agent.items[Item_Slot.PISTOL] != 0;
        case WEAPON_RIFLE;      return agent.items[Item_Slot.RIFLE] != 0;
        case WEAPON_DETONATOR;  return agent.ammo[Ammo.DETONATOR] != 0;
        case WEAPON_REPEATER;   return agent.items[Item_Slot.AUTOGUN] != 0;
        case WEAPON_FUSION;     return agent.items[Item_Slot.FUSION] != 0;
        case WEAPON_MORTAR;     return agent.items[Item_Slot.MORTAR] != 0;
        case WEAPON_MINES;      return (agent.ammo[Ammo.MINE] & agent.mine_weapon) != 0;
        case WEAPON_CONCUSSION; return agent.items[Item_Slot.CONCUSSION] != 0;
        case WEAPON_CANNON;     return agent.items[Item_Slot.CANNON] != 0;
    }
    return false;
}

// A message to the task (0x1d8e5): it runs from where it waits, at once, until it yields.
send_weapon_message :: (message: s32, arg: s32 = 0) {
    w := *world.weapon;
    w.message = message;
    w.message_arg = arg;
    w.in_message = true;
    resume_weapon_task();
    w.in_message = false;
    w.message = 0;
}

// A yield (0x1d793): the task stops here. Only when it runs on its own does that set when it
// runs next; after a message it keeps the time it had.
wait_weapon :: (resume: Weapon_Resume, ticks: s32) {
    w := *world.weapon;
    w.resume = resume;
    w.wait_ticks = ticks;
    if w.in_message return;
    w.wake = ifx ticks < 0 then -1 else world.clock.tick + ticks;
}

// 0x1d96a: the task runs on the next frame, whatever it waits for.
run_weapon_next_frame :: () { world.weapon.wake = 0; }

resume_weapon_task :: () {
    w := *world.weapon;
    if w.resume == {
        case .SLEEP;
            w.woken_arg = w.message_arg;
            if w.message == {
                case 0;
                    // Run after a message left it here: the loop's test, then to sleep for
                    // good.
                    test_firing_loop();
                case 2;
                    w.requested = w.message_arg;
                    run_weapon_next_frame();
                    wait_weapon(.SWITCH_YIELD, 0);
                case 4;
                    run_weapon_next_frame();
                    wait_weapon(.FIRE_YIELD, 0);
                case 5;
                    run_weapon_next_frame();
                    wait_weapon(.STOP_YIELD, 0);
                case 6;
                    run_weapon_next_frame();
                    wait_weapon(.HOLSTER_YIELD, 0);
            }
        case .SWITCH_YIELD;
            if take_weapon_message(.SWITCH_YIELD) return;
            finish_switch_yield();
        case .FIRE_YIELD;
            if take_weapon_message(.FIRE_YIELD) return;
            finish_fire_yield();
        case .STOP_YIELD;
            if take_weapon_message(.STOP_YIELD) return;
            finish_stop_yield();
        case .HOLSTER_YIELD;
            if take_weapon_message(.HOLSTER_YIELD) return;
            finish_holster_yield();
        case .MOVE_START;
            if take_weapon_message(.MOVE_START) return;
            start_move_steps();
        case .MOVE_STEP;
            step_move();
        case .LOOP_TOP;
            if take_weapon_message(.LOOP_TOP) return;
            wait_for_message_to_pass();
        case .NO_SHOT;
            if take_weapon_message(.NO_SHOT) return;
            finish_fire();
        case .FIRING;
            if take_weapon_message(.FIRING) return;
            // A message: the wait goes on.
            if w.message  { wait_weapon(.FIRING, w.wait_ticks); return; }
            continue_firing();
        case .CHARGE_START; #through;
        case .CHARGING;
            take_weapon_message(w.resume);
            if w.firing { wait_weapon(.CHARGING, 0); return; }
            run_weapon_next_frame();
            wait_weapon(.CHARGE_END, 0);
        case .CHARGE_END;
            take_weapon_message(.CHARGE_END);
            throw_detonator();
    }
}

// Woken by 2 (0x428f0): to the weapon asked for, or back to the one before; the one in hand
// lowered first unless holstered, the next raised.
finish_switch_yield :: () {
    choose_requested_weapon();
    start_switch(.LOOP);
}

// Woken by 4: firing, primary or secondary by the press that woke it; a holstered weapon
// comes back up first.
finish_fire_yield :: () {
    w := *world.weapon;
    w.secondary = w.woken_arg != 0;
    w.firing = true;
    if w.holstered {
        raise_weapon(.FIRE_REST);
        return;
    }
    finish_fire_press();
}

finish_fire_press :: () {
    finish_press_taken();
    test_firing_loop();
}

finish_stop_yield :: () {
    w := *world.weapon;
    w.firing = false;
    rest_weapon_frame();
    w.weapons[w.current].flags |= WEAPON_SWAYS;
    test_firing_loop();
}

// Woken by 6: lowered and put away, or brought back.
finish_holster_yield :: () {
    w := *world.weapon;
    if !w.holstered {
        rest_weapon_frame();
        start_move(w.weapons[w.current].frame, 0, 0, 3, 4, .HOLSTER);
        return;
    }
    raise_weapon(.LOOP);
}

// The firing loop's test (0x428f0): while firing, each pass first lets a message's yield end,
// then fires if a shot is owed.
test_firing_loop :: () {
    w := *world.weapon;
    if !w.firing {
        wait_weapon(.SLEEP, -1);
        return;
    }
    w.fire_frame += 1;
    w.switch_requested = false;
    wait_for_message_to_pass();
}

wait_for_message_to_pass :: () {
    w := *world.weapon;
    if w.message {
        run_weapon_next_frame();
        wait_weapon(.LOOP_TOP, 0);
        return;
    }
    try_firing();
}

try_firing :: () {
    w := *world.weapon;
    if !w.secondary || !w.owed_secondary {
        if !w.owed {
            run_weapon_next_frame();
            wait_weapon(.NO_SHOT, 0);
            return;
        }
    }
    if w.current == {
        case WEAPON_FIST;       fire_fists();
        case WEAPON_PISTOL;     fire_bolt_weapon(*PISTOL);
        case WEAPON_RIFLE;      fire_bolt_weapon(*RIFLE);
        case WEAPON_DETONATOR;  fire_detonator();
        case WEAPON_REPEATER;   fire_repeater();
        case WEAPON_FUSION;     fire_fusion_cutter();
        case WEAPON_MORTAR;     fire_mortar();
        case WEAPON_MINES;      fire_mines();
        case WEAPON_CONCUSSION; fire_bolt_weapon(*CONCUSSION);
        case WEAPON_CANNON;     fire_cannon();
    }
}

// Back from the fire function: a switch asked for meanwhile, then the loop's test.
finish_fire :: () {
    w := *world.weapon;
    if w.switch_requested {
        choose_requested_weapon();
        if start_switch(.LOOP) return;
    }
    test_firing_loop();
}

// handle_state (0x47c90): a switch asked for is kept for later; a press fires (bringing a
// holstered weapon up) and in 1.0 makes a shot owed at once; a release stops firing and the
// weapon sways again. Returns true if it started raising the weapon, and with that took
// over the task.
take_weapon_message :: (at: Weapon_Resume) -> bool {
    w := *world.weapon;
    if w.message == {
        case 2;
            w.switch_requested = true;
            w.requested = w.message_arg;
        case 4;
            w.secondary = w.message_arg != 0;
            w.firing = true;
            // Only where the task waits holstered, at a message's yield: the original
            // raises it right there, inside the handler, then carries on.
            if w.holstered {
                w.yield_rest = at;
                raise_weapon(.YIELD_REST);
                return true;
            }
            finish_press_taken();
        case 5;
            w.firing = false;
            rest_weapon_frame();
            w.weapons[w.current].flags |= WEAPON_SWAYS;
    }
    return false;
}

finish_press_taken :: () {
    w := *world.weapon;
    w.weapons[w.current].flags &= ~WEAPON_SWAYS;
    rest_weapon_frame();
    set_fire_rate();
}

// The rest of the press and of the message's yield it came at, once the raise it started is
// over.
finish_yield_rest :: () {
    w := *world.weapon;
    finish_press_taken();
    if w.yield_rest == {
        case .SWITCH_YIELD;  finish_switch_yield();
        case .FIRE_YIELD;    finish_fire_yield();
        case .STOP_YIELD;    finish_stop_yield();
        case .HOLSTER_YIELD; finish_holster_yield();
        case;                test_firing_loop();
    }
}

choose_requested_weapon :: () {
    w := *world.weapon;
    old := w.task_weapon;
    w.task_weapon = ifx w.requested == -1 then w.previous else w.requested;
    w.previous = old;
}

// To task_weapon: lowered unless holstered, then set and raised; then after_raise.
// Returns true if it moves (the task now waits).
start_switch :: (after_raise: Weapon_After) -> bool {
    w := *world.weapon;
    w.after_switch = after_raise;
    if !w.holstered {
        lower_weapon_for_switch();
        return true;
    }
    select_weapon(w.task_weapon);
    raise_weapon(after_raise);
    return true;
}

// 0x42fd4: the repeater's sound stopped and frames at rest, then lowered.
lower_weapon_for_switch :: () {
    w := *world.weapon;
    rest_weapon_frame();
    start_move(w.weapons[w.current].frame, 0, 0, 3, 4, .SWITCH);
}

// 0x43084: up from 30 right and 40 down, ten steps, with the sound for all but the fists,
// the detonator and the mines.
raise_weapon :: (after: Weapon_After) {
    w := *world.weapon;
    w.holstered = false;
    if w.task_weapon != WEAPON_FIST && w.task_weapon != WEAPON_DETONATOR && w.task_weapon != WEAPON_MINES  play_sound(w.sounds[cast(s32) Weapon_Sound.RAISE]);
    weapon := *w.weapons[w.current];
    weapon.frame = get_rest_frame();
    start_move(weapon.frame, 30, 40, -3, -4, after);
}

// 0x42dc0: the weapon in hand, its resting frame (the empty hand for the detonator and mines
// with none), its fire rate; raising and lowering carry over.
select_weapon :: (index: s32) {
    w := *world.weapon;
    old := *w.weapons[w.current];
    w.current = index;
    w.task_weapon = index;
    world.player_state.current_weapon = index;
    weapon := *w.weapons[index];
    weapon.frame = get_rest_frame();
    set_fire_rate();
    weapon.x_offset = old.x_offset;
    weapon.y_offset = old.y_offset;
}

get_rest_frame :: () -> s32 {
    w := *world.weapon;
    if w.current == WEAPON_DETONATOR && agent.ammo[Ammo.DETONATOR] == 0  return 3;
    if w.current == WEAPON_MINES && agent.ammo[Ammo.MINE] == 0  return 2;
    return 0;
}

// 0x432ec: the repeater's looping sound stopped and its frame at rest, the cannon's too
// unless on its secondary.
rest_weapon_frame :: () {
    w := *world.weapon;
    weapon := *w.weapons[w.current];
    if w.current == WEAPON_REPEATER {
        stop_sound(w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP]);
        w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP] = 0;
        weapon.frame = 0;
    }
    if w.current == WEAPON_CANNON && !w.secondary  weapon.frame = 0;
}

// Raising or lowering (0x47d9c): from (x, y) by (dx, dy) a step, for ten steps, a step every
// two ticks (one supercharged) unless given; a late frame takes the steps it's owed at once.
// The frame shows from the next frame on.
start_move :: (frame: s32, x: s32, y: s32, dx: s32, dy: s32, after: Weapon_After, steps: s32 = 10, delay: s32 = 0) {
    w := *world.weapon;
    weapon := *w.weapons[w.current];
    weapon.x_offset = x;
    weapon.y_offset = y;
    w.move_frame = frame;
    w.move_dx = dx;
    w.move_dy = dy;
    w.move_steps = steps;
    w.move_delay = delay;
    if !delay  w.move_delay = ifx world.player_state.supercharged then cast(s32) 1 else 2;
    w.move_late = false;
    w.after = after;
    run_weapon_next_frame();
    wait_weapon(.MOVE_START, 0);
}

start_move_steps :: () {
    w := *world.weapon;
    w.weapons[w.current].frame = w.move_frame;
    w.move_start = world.clock.tick;
    wait_weapon(.MOVE_STEP, ifx w.move_late then 0 else w.move_delay);
}

step_move :: () {
    w := *world.weapon;
    if w.message {
        // Its own handling: a switch kept, a press or release as 0x431ac and 0x4328c.
        if w.message == {
            case 2;
                w.switch_requested = true;
                w.requested = w.message_arg;
            case 4;
                // Never holstered while moving, so never the raise 0x431ac would start.
                w.secondary = w.message_arg != 0;
                w.firing = true;
                finish_press_taken();
            case 5;
                w.firing = false;
                rest_weapon_frame();
                w.weapons[w.current].flags |= WEAPON_SWAYS;
        }
        wait_weapon(.MOVE_STEP, w.wait_ticks);
        return;
    }
    weapon := *w.weapons[w.current];
    elapsed := world.clock.tick - w.move_start;
    w.move_late = elapsed > w.move_delay + 1;
    steps: s32 = 1;
    if w.move_late && w.move_steps >= 2  steps = min(elapsed / w.move_delay, w.move_steps);
    weapon.x_offset += w.move_dx * steps;
    weapon.y_offset += w.move_dy * steps;
    w.move_steps -= steps;
    if w.move_steps > 0 {
        w.move_start = world.clock.tick;
        wait_weapon(.MOVE_STEP, ifx w.move_late then 0 else w.move_delay);
        return;
    }
    if w.after == {
        case .LOOP;       test_firing_loop();
        case .AFTER_FIRE; finish_fire();
        case .FIRE_REST;  finish_fire_press();
        case .SWITCH;
            w.holstered = true;
            select_weapon(w.task_weapon);
            raise_weapon(w.after_switch);
        case .HOLSTER;
            w.holstered = true;
            test_firing_loop();
        case .YIELD_REST; finish_yield_rest();
        case .MINE_SET;   set_mine();
    }
}

// A shot owed now and one every so many ticks while firing, by the weapon (0x43368): its
// animation's length, half supercharged.
set_fire_rate :: () {
    w := *world.weapon;
    w.owed = 1;
    w.owed_secondary = 1;
    w.fire_delay, w.fire_ticks = 0, 0;
    w.secondary_delay, w.secondary_ticks = 0, 0;
    s := world.player_state.supercharged;
    if w.current == {
        case WEAPON_PISTOL;     w.fire_delay = ifx s then cast(s32) 35 else 71;
        case WEAPON_RIFLE;      w.fire_delay = ifx s then cast(s32) 10 else 21;
        case WEAPON_DETONATOR;  w.fire_delay = 1;
        case WEAPON_MINES;      w.fire_delay = 1;
        case WEAPON_REPEATER;
            w.fire_delay = ifx s then cast(s32) 14 else 30;
            w.secondary_delay = ifx s then cast(s32) 18 else 37;
        case WEAPON_FUSION;
            w.fire_delay = ifx s then cast(s32) 17 else 35;
            w.secondary_delay = ifx s then cast(s32) 33 else 68;
        case WEAPON_MORTAR;     w.fire_delay = ifx s then cast(s32) 50 else 100;
        case WEAPON_CONCUSSION; w.fire_delay = ifx s then cast(s32) 57 else 115;
        case WEAPON_CANNON;
            w.fire_delay = ifx s then cast(s32) 17 else 35;
            w.secondary_delay = ifx s then cast(s32) 86 else 174;
    }
}

// The best weapon with ammo, when the one in hand runs dry and auto-switching is on
// (0x42e78): the cannon, fusion cutter, repeater, rifle, pistol, concussion rifle, mortar,
// detonators, else the fists. Returns true if it switches (the task now waits).
auto_switch_weapon :: () -> bool {
    w := *world.weapon;
    if !weapon_auto_switch return false;
    best := WEAPON_FIST;
    has :: (slot: Item_Slot, ammo: Ammo) -> bool #expand { return agent.items[slot] != 0 && agent.ammo[ammo] != 0; }
    if      has(.CANNON, .PLASMA)      best = WEAPON_CANNON;
    else if has(.FUSION, .POWER)       best = WEAPON_FUSION;
    else if has(.AUTOGUN, .POWER)      best = WEAPON_REPEATER;
    else if has(.RIFLE, .ENERGY)       best = WEAPON_RIFLE;
    else if has(.PISTOL, .ENERGY)      best = WEAPON_PISTOL;
    else if has(.CONCUSSION, .POWER)   best = WEAPON_CONCUSSION;
    else if has(.MORTAR, .SHELL)       best = WEAPON_MORTAR;
    else if agent.ammo[Ammo.DETONATOR] best = WEAPON_DETONATOR;
    if best == w.current return false;
    w.previous = w.task_weapon;
    w.task_weapon = best;
    return start_switch(.AFTER_FIRE);
}

// The fire function's animation: each frame shown and held, with what follows it.
play_fire_steps :: (steps: [] Fire_Step) {
    w := *world.weapon;
    w.steps = steps;
    w.step_index = 0;
    show_fire_step();
}

show_fire_step :: () {
    w := *world.weapon;
    a := w.steps[w.step_index];
    w.weapons[w.current].frame = a.frame;
    if a.light >= 0  w.light = a.light;
    wait_weapon(.FIRING, ifx world.player_state.supercharged then a.supercharged_ticks else a.ticks);
}

continue_firing :: () {
    w := *world.weapon;
    if run_fire_action(w.steps[w.step_index].action) return;
    w.step_index += 1;
    if w.step_index < w.steps.count {
        show_fire_step();
        return;
    }
    finish_fire();
}

// What follows a frame of the animation. Returns true if it took the task elsewhere.
run_fire_action :: (action: Fire_Action) -> bool {
    w := *world.weapon;
    if action == {
        case .PUNCH;
            punch();
        case .EMPTY;
            w.owed = 0;
            w.owed_secondary = 0;
            return auto_switch_weapon();
        case .EMPTY_PRIMARY;
            w.owed = 0;
            return auto_switch_weapon();
        case .EMPTY_SECONDARY;
            w.owed_secondary = 0;
            return auto_switch_weapon();
        case .EMPTY_MISSILES;
            w.owed_secondary = 0;
        case .LIGHT_OFF;
            w.light = 0;
        case .CHARGE;
            // The hand drops out of sight while fire is held; the throw's speed is the time.
            weapon := *w.weapons[WEAPON_DETONATOR];
            weapon.x_offset, weapon.y_offset = 100, 100;
            w.charge_start = world.clock.tick;
            run_weapon_next_frame();
            wait_weapon(.CHARGE_START, 0);
            return true;
        case .AFTER_THROW;
            if agent.ammo[Ammo.DETONATOR]  play_fire_steps(DETONATOR_NEXT_STEPS);
            else                           play_fire_steps(DETONATOR_EMPTY_STEPS);
            return true;
        case .SHOOT_REPEATER;
            shoot_bolts(*REPEATER);
            play_fire_steps(REPEATER_AFTER_STEPS);
            return true;
        case .SHOOT_REPEATER_SPREAD;
            shoot_spread(*REPEATER_SPREAD);
            return true;
        case .SHOOT_MISSILE;
            play_weapon_sound(.MISSILE);
            wake_for_weapon();
            shoot_bolts(*MISSILE);
            play_fire_steps(MISSILE_AFTER_STEPS);
            return true;
        case .MORTAR_RELOAD;
            play_weapon_sound(.MORTAR_RELOAD);
        case .FUSION_BARRELS;
            for 1..w.shots  step_fusion_barrel();
            w.light = 0;
        case .CANNON_AGAIN;
            w.light = 0;
            play_fire_steps(ifx w.firing then CANNON_AGAIN_STEPS else CANNON_REST_STEPS);
            return true;
    }
    return false;
}

play_weapon_sound :: (sound: Weapon_Sound) {
    w := *world.weapon;
    stop_sound(w.playing[cast(s32) sound]);
    w.playing[cast(s32) sound] = play_sound(w.sounds[cast(s32) sound]);
}

// Enemies within the weapon's range hear it (0x5c8f8).
wake_for_weapon :: () {
    w := *world.weapon;
    p := *world.player;
    weapon := *w.weapons[w.current];
    if weapon.wake_range  wake_actors_in_range(p.sector, weapon.wake_range, p.position, -1);
}

get_eye_y :: () -> Fixed {
    p := *world.player;
    return p.position.y - p.height + p.bob;
}

// Out of detonators or mines (0x445c8, 0x46108): the best weapon with auto-switching, else
// the fists.
switch_from_empty_hand :: () {
    w := *world.weapon;
    if weapon_auto_switch {
        if !auto_switch_weapon()  finish_fire();
        return;
    }
    w.previous = w.task_weapon;
    w.task_weapon = WEAPON_FIST;
    start_switch(.AFTER_FIRE);
}

EMPTY_STEPS           :: Fire_Step.[.{0, -1, 7, 3, .EMPTY}];
EMPTY_PRIMARY_STEPS   :: Fire_Step.[.{0, -1, 7, 3, .EMPTY_PRIMARY}];
EMPTY_SECONDARY_STEPS :: Fire_Step.[.{0, -1, 7, 3, .EMPTY_SECONDARY}];

// The fists (0x436f8): the arm drawn back, then three punches spread across the view, the
// swing's sound; then the follow-through and back to rest.
FIST_STEPS :: Fire_Step.[
    .{1, -1, 10, 5, .PUNCH},
    .{2, -1, 21, 10, .NONE},
    .{3, -1, 21, 10, .NONE},
    .{0, -1, 21, 10, .NONE},
];

fire_fists :: () { play_fire_steps(FIST_STEPS); }

punch :: () {
    w := *world.weapon;
    p := *world.player;
    play_weapon_sound(.SWING);
    wake_for_weapon();
    matrix := get_weapon_matrix(-p.pitch, -p.object_yaw);
    eye_y := get_eye_y();
    for 0..2 {
        side := cast(s32) it - 1;
        proj := create_projectile(.PUNCH, p.sector, .{p.position.x, eye_y, p.position.z}, OBJECT_IS_PLAYER);
        if !proj break;
        w.fire_pitch = p.pitch + 0x638;
        w.fire_yaw = p.object_yaw + side * 0x38E;
        turn_projectile(proj, w.fire_pitch, w.fire_yaw);
        proj.hit_effect = 8;
        proj.last_hit = OBJECT_IS_PLAYER;
        proj.exclude = OBJECT_IS_PLAYER;
        proj.delta = rotate_vector(.{side * 0x1C000, 0x18000, 0x60000}, matrix);
        hit := move_projectile(proj);
        if hit != .NONE  end_projectile(proj, hit);
    }
}

// A weapon firing one projectile a shot owed from the eye, aimed by the aiming help or
// scattered: the pistol, rifle, repeater, concussion rifle and both of the cannon's.
Bolt_Weapon :: struct {
    weapon: s32;
    type: Projectile_Type;
    offset: Fixed3;             // From the eye, turned with the view.
    cost: s32;                  // Ammo a shot.
    // A second shot owed goes a shot's length ahead: the animation's ticks of flight at the
    // projectile's speed, truncated (0x8eed8), and supercharged.
    ahead, supercharged_ahead: s32;
    secondary: bool;            // Its ammo and shots owed are the secondary's.
    // The concussion rifle and mortar add each shot's length to a z they never set: taken
    // from 0 here.
    adds_up: bool;
    sound, empty_sound: Weapon_Sound;
    after_sound: Weapon_Sound;  // Played after the shots, if not the fire sound.
    steps: [] Fire_Step;
}

// The pistol (0x43950): the flash, the slide, back to rest.
PISTOL :: Bolt_Weapon.{WEAPON_PISTOL, .PISTOL_BOLT, .{0x6666, 0x9999, 0x33333}, 1, 121, 60, false, false,
                       .PISTOL, .PISTOL_EMPTY, .PISTOL, PISTOL_STEPS};
PISTOL_STEPS :: Fire_Step.[
    .{1, 40, 14, 7, .NONE},
    .{2, 0, 14, 7, .NONE},
    .{0, -1, 43, 21, .NONE},
];

// The rifle (0x43fe4): two of energy a shot, the flash, back to rest.
RIFLE :: Bolt_Weapon.{WEAPON_RIFLE, .RIFLE_BOLT, .{0x6666, 0xC000, 0x40000}, 2, 36, 17, false, false,
                      .RIFLE, .RIFLE_EMPTY, .RIFLE, RIFLE_STEPS};
RIFLE_STEPS :: Fire_Step.[
    .{1, 40, 7, 3, .NONE},
    .{0, 0, 14, 7, .NONE},
];

// The concussion rifle (0x4693c): four of power, a second sound, the flash, the recoil.
CONCUSSION :: Bolt_Weapon.{WEAPON_CONCUSSION, .CONCUSSION, .{0x10000, 0x8000, 0x30000}, 4, 150, 74, false, true,
                           .CONCUSSION, .CONCUSSION_EMPTY, .CONCUSSION_AFTER, CONCUSSION_STEPS};
CONCUSSION_STEPS :: Fire_Step.[
    .{1, 36, 43, 21, .LIGHT_OFF},
    .{2, -1, 14, 7, .NONE},
    .{0, -1, 58, 29, .NONE},
];

// The repeater's primary (0x44968): a bolt after frame 1, then frame 2 until it's let go.
REPEATER :: Bolt_Weapon.{WEAPON_REPEATER, .REPEATER, .{0xCCCC, 0xFAE1, 0x50000}, 1, 55, 25, false, false,
                         .REPEATER, .REPEATER_EMPTY, .REPEATER, .[]};
REPEATER_STEPS :: Fire_Step.[.{1, -1, 5, 2, .SHOOT_REPEATER}];
REPEATER_AFTER_STEPS :: Fire_Step.[.{2, 33, 11, 5, .LIGHT_OFF}];

// The assault cannon's plasma (0x46ff0): its frame held again while fire is.
CANNON :: Bolt_Weapon.{WEAPON_CANNON, .CANNON, .{0x10000, 0x9999, 0x30000}, 1, 24, 11, false, false,
                       .CANNON, .CANNON_EMPTY, .CANNON, CANNON_STEPS};
CANNON_STEPS       :: Fire_Step.[.{1, 34, 10, 5, .CANNON_AGAIN}];
CANNON_AGAIN_STEPS :: Fire_Step.[.{1, -1, 10, 5, .NONE}];
CANNON_REST_STEPS  :: Fire_Step.[.{0, -1, 14, 7, .NONE}];

// Its missiles, after frame 2.
MISSILE :: Bolt_Weapon.{WEAPON_CANNON, .MISSILE, .{0x20000, 0x4000, 0x40000}, 1, 88, 43, true, false,
                        .MISSILE, .MISSILE, .MISSILE, .[]};
MISSILE_STEPS       :: Fire_Step.[.{2, -1, 29, 14, .SHOOT_MISSILE}];
MISSILE_AFTER_STEPS :: Fire_Step.[
    .{3, 33, 87, 43, .LIGHT_OFF},
    .{0, -1, 58, 29, .NONE},
];

// With ammo, the shots, the sounds, enemies within the weapon's range woken, then the
// animation; without, a click.
fire_bolt_weapon :: (b: *Bolt_Weapon) {
    w := *world.weapon;
    weapon := *w.weapons[b.weapon];
    if !agent.ammo[weapon.ammo] {
        play_weapon_sound(b.empty_sound);
        play_fire_steps(EMPTY_STEPS);
        return;
    }
    play_weapon_sound(b.sound);
    wake_for_weapon();
    shoot_bolts(b);
    if b.after_sound != b.sound  play_weapon_sound(b.after_sound);
    play_fire_steps(b.steps);
}

// A bolt for each shot owed while there's ammo, from the eye toward the aim. Late frames
// owe more than one: all but the last go a shot's length ahead, more for each still owed.
shoot_bolts :: (b: *Bolt_Weapon) {
    w := *world.weapon;
    weapon := *w.weapons[b.weapon];
    p := *world.player;
    s := *world.player_state;
    kind := ifx b.secondary then weapon.secondary_ammo else weapon.ammo;
    ammo := *agent.ammo[kind];
    matrix := get_weapon_matrix(-p.pitch, -p.object_yaw);
    out := rotate_vector(b.offset, matrix);
    eye_y := get_eye_y();
    at := Fixed3.{p.position.x + out.x, out.y + eye_y, p.position.z + out.z};
    aimed := aim_at_drawn(at, p.pitch, p.object_yaw, weapon.variation);
    if !aimed {
        v := weapon.variation;
        w.fire_pitch = p.pitch + fixed_random(v * 2) - v;
        w.fire_yaw = p.object_yaw + fixed_random(v * 2) - v;
    }
    owed := ifx b.secondary then *w.owed_secondary else *w.owed;
    count := owed.*;
    owed.* = 0;
    second: [9] Fixed;
    if count > 1  second = get_weapon_matrix(-w.fire_pitch, -w.fire_yaw);
    ahead_z: Fixed;
    while count > 0 && ammo.* {
        count -= 1;
        if !s.supercharged || (w.fire_frame & 1)  ammo.* = clamp(ammo.* - b.cost, 0, AMMO_MAX[kind]);
        proj := create_projectile(b.type, p.sector, .{p.position.x, eye_y, p.position.z}, OBJECT_IS_PLAYER);
        if !proj break;
        proj.flags &= ~PROJECTILE_PASS_SOUND;
        proj.last_hit = OBJECT_IS_PLAYER;
        if aimed {
            set_projectile_heading(proj, w.aim_sin_pitch, w.aim_cos_pitch, w.aim_x, w.aim_z);
            o := world.objects[proj.object];
            o.pitch = cast,no_check(s16) w.fire_pitch;
            o.yaw = cast,no_check(s16) w.fire_yaw;
        } else {
            turn_projectile(proj, w.fire_pitch, w.fire_yaw);
        }
        proj.delta = out;
        hit := move_projectile(proj);
        if count > 0 {
            if hit != .NONE { end_projectile(proj, hit); continue; }
            d := (ifx s.supercharged then b.supercharged_ahead else b.ahead) << 16;
            if count >= 2  d = mul16(count << 16, d);
            if b.adds_up { ahead_z += d; d = ahead_z; }
            proj.delta = rotate_vector(.{0, 0, d}, second);
            hit = move_projectile(proj);
        }
        if hit != .NONE  end_projectile(proj, hit);
    }
}

// A weapon firing several projectiles a shot, spread: the repeater's and fusion cutter's
// secondaries. The shots owed go one after another while there's ammo, then the animation.
Spread_Weapon :: struct {
    weapon: s32;
    type: Projectile_Type;
    cost: s32;
    offsets: [] Fixed3;         // Each projectile's from the eye, turned with the view,
    pitch_offsets, yaw_offsets: [] s32;     // and its turn from the aim.
    ahead, supercharged_ahead: s32;
    // The fusion cutter moves the shots still owed by a vector it never sets: none here.
    no_ahead: bool;
    steps: [] Fire_Step;
}

REPEATER_SPREAD :: Spread_Weapon.{WEAPON_REPEATER, .REPEATER, 3,
    .[.{0xE666, 0xFAE1, 0x50000}, .{0x8000, 0x18000, 0x50000}, .{0x18000, 0x18000, 0x50000}],
    .[136, -136, -136], .[0, 136, -136], 68, 33, false, REPEATER_SPREAD_STEPS};
REPEATER_SPREAD_STEPS :: Fire_Step.[
    .{2, 33, 11, 5, .LIGHT_OFF},
    .{0, -1, 29, 14, .NONE},
];

// The fusion cutter's barrels (0xe6b64), the primary's one at a time.
FUSION_BARREL_OFFSETS :: Fixed3.[.{-0x10000, 0x8000, 0x30000}, .{-0x4CCC, 0xCCCC, 0x30000},
                                 .{0x4CCC, 0x11999, 0x30000}, .{0xCCCC, 0x14CCC, 0x30000}];

FUSION_SPREAD :: Spread_Weapon.{WEAPON_FUSION, .PLASMA, 8, FUSION_BARREL_OFFSETS,
    .[0, 0, 0, 0], .[-375, -125, 125, 375], 0, 0, true, FUSION_SPREAD_STEPS};
FUSION_SPREAD_STEPS :: Fire_Step.[
    .{5, 34, 29, 14, .LIGHT_OFF},
    .{0, -1, 39, 19, .NONE},
];

shoot_spread :: (b: *Spread_Weapon) {
    w := *world.weapon;
    weapon := *w.weapons[b.weapon];
    p := *world.player;
    s := *world.player_state;
    matrix := get_weapon_matrix(-p.pitch, -p.object_yaw);
    v := weapon.secondary_variation;
    w.fire_pitch = p.pitch + fixed_random(v * 2) - v;
    w.fire_yaw = p.object_yaw + fixed_random(v * 2) - v;
    count := w.owed_secondary;
    w.owed_secondary = 0;
    second: [9] Fixed;
    if count > 1  second = get_weapon_matrix(-w.fire_pitch, -w.fire_yaw);
    ammo := *agent.ammo[weapon.ammo];
    eye_y := get_eye_y();
    while count > 0 && ammo.* {
        count -= 1;
        if !s.supercharged || (w.fire_frame & 1)  ammo.* = clamp(ammo.* - b.cost, 0, AMMO_MAX[weapon.ammo]);
        projs: [4] *Projectile;
        for i: 0..b.offsets.count-1 {
            proj := create_projectile(b.type, p.sector, .{p.position.x, eye_y, p.position.z}, OBJECT_IS_PLAYER);
            projs[i] = proj;
            if !proj continue;
            proj.flags &= ~PROJECTILE_PASS_SOUND;
            turn_projectile(proj, w.fire_pitch + b.pitch_offsets[i], w.fire_yaw + b.yaw_offsets[i]);
            proj.last_hit = OBJECT_IS_PLAYER;
        }
        for i: 0..b.offsets.count-1 {
            proj := projs[i];
            if !proj continue;
            proj.delta = rotate_vector(b.offsets[i], matrix);
            hit := move_projectile(proj);
            if count > 0 && hit == .NONE {
                d := (ifx s.supercharged then b.supercharged_ahead else b.ahead) << 16;
                if count >= 2  d = mul16(count << 16, d);
                if b.no_ahead  d = 0;
                proj.delta = rotate_vector(.{0, 0, d}, second);
                hit = move_projectile(proj);
            }
            if hit != .NONE  end_projectile(proj, hit);
        }
    }
    play_fire_steps(b.steps);
}

// The thermal detonator (0x445c8): one taken, the arm drawn back, then held out of sight
// while fire is held; thrown the frame after it's let go, faster the longer it was held.
// Out of detonators, the fists.
DETONATOR_STEPS       :: Fire_Step.[.{1, -1, 11, 11, .CHARGE}];
DETONATOR_THROWN_STEPS :: Fire_Step.[.{2, -1, 58, 58, .AFTER_THROW}];
DETONATOR_NEXT_STEPS  :: Fire_Step.[.{1, -1, 29, 29, .NONE}, .{0, -1, 29, 29, .NONE}];
DETONATOR_EMPTY_STEPS :: Fire_Step.[.{3, -1, 29, 29, .NONE}];

fire_detonator :: () {
    ammo := *agent.ammo[Ammo.DETONATOR];
    if !ammo.* {
        switch_from_empty_hand();
        return;
    }
    ammo.* = clamp(ammo.* - 1, 0, AMMO_MAX[Ammo.DETONATOR]);
    play_fire_steps(DETONATOR_STEPS);
}

// Held for 58 to 116 ticks, the primary at 50 to 100 units a second, going off where it
// first hits; the secondary from 23 ticks, on its three-second fuse, bouncing. Thrown up
// from half the view's pitch.
throw_detonator :: () {
    w := *world.weapon;
    weapon := *w.weapons[WEAPON_DETONATOR];
    p := *world.player;
    held := cast(s64) (world.clock.tick - w.charge_start) << 16;
    wake_for_weapon();
    proj := create_projectile(.THERMAL_DETONATOR, p.sector, .{p.position.x, get_eye_y(), p.position.z}, OBJECT_IS_PLAYER);
    if proj {
        if !w.secondary {
            proj.duration = NEVER;
            proj.bounces = 0;
            held = max(held, 0x3A0000);
        } else {
            held = max(held, 0x170000);
        }
        held = min(held, 0x740000);
        proj.speed = cast(Fixed) (((held << 16) / 0x740000) * 0x640000 >> 16);
        v := weapon.variation;
        w.fire_pitch = (p.pitch >> 1) + 0x638 + fixed_random(v * 2) - v;
        w.fire_yaw = p.object_yaw + fixed_random(v * 2) - v;
        turn_projectile(proj, w.fire_pitch, w.fire_yaw);
        proj.last_hit = OBJECT_IS_PLAYER;
        matrix := get_weapon_matrix(-(p.pitch + 0x638), -p.object_yaw);
        proj.delta = rotate_vector(.{0x20000, 0x20000, 0x20000}, matrix);
        hit := move_projectile(proj);
        if hit != .NONE  end_projectile(proj, hit);
    }
    weapon.x_offset, weapon.y_offset = 0, 0;
    play_fire_steps(DETONATOR_THROWN_STEPS);
}

// The mines (0x46108): one taken, the hand lowered over five steps of 7 ticks, the mine set
// on the floor under the player (going off in three seconds, or the secondary's armed then
// to go off when something comes near), the hand raised again.
fire_mines :: () {
    ammo := *agent.ammo[Ammo.MINE];
    if !ammo.* {
        switch_from_empty_hand();
        return;
    }
    ammo.* = clamp(ammo.* - 1, 0, AMMO_MAX[Ammo.MINE]);
    wake_for_weapon();
    start_move(1, 0, 0, 0, 20, .MINE_SET, 5, 7);
}

set_mine :: () {
    w := *world.weapon;
    p := *world.player;
    floor := get_floor_and_ceiling(*world.level.sectors[p.sector], p.position.y);
    type := ifx w.secondary then Projectile_Type.LAND_MINE_PROXIMITY else .LAND_MINE;
    proj := create_projectile(type, p.sector, .{p.position.x, floor, p.position.z}, OBJECT_IS_PLAYER);
    if proj  proj.velocity = .{};
    play_weapon_sound(.MINE);
    start_move(ifx agent.ammo[Ammo.MINE] then cast(s32) 0 else 2, 0, 100, 0, -20, .AFTER_FIRE, 5, 7);
}

// The repeater (0x44968): the primary a bolt at a time, with its sound looping until the
// weapon rests; the secondary three at once.
fire_repeater :: () {
    w := *world.weapon;
    if !agent.ammo[Ammo.POWER] {
        if !w.secondary {
            stop_sound(w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP]);
            w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP] = 0;
        }
        play_weapon_sound(.REPEATER_EMPTY);
        play_fire_steps(ifx w.secondary then EMPTY_SECONDARY_STEPS else EMPTY_PRIMARY_STEPS);
        return;
    }
    if !w.secondary {
        if !w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP] {
            play_weapon_sound(.REPEATER);
            w.playing[cast(s32) Weapon_Sound.REPEATER_LOOP] = play_sound(w.sounds[cast(s32) Weapon_Sound.REPEATER_LOOP]);
        }
        wake_for_weapon();
        play_fire_steps(REPEATER_STEPS);
        return;
    }
    play_weapon_sound(.REPEATER);
    wake_for_weapon();
    play_fire_steps(REPEATER_SPREAD_START_STEPS);
}

REPEATER_SPREAD_START_STEPS :: Fire_Step.[.{1, -1, 8, 4, .SHOOT_REPEATER_SPREAD}];

// The fusion cutter (0x45568): the primary from one barrel a shot, the next barrel each shot
// back and forth across the four; the secondary from all four, spread.
fire_fusion_cutter :: () {
    w := *world.weapon;
    weapon := *w.weapons[WEAPON_FUSION];
    p := *world.player;
    s := *world.player_state;
    ammo := *agent.ammo[Ammo.POWER];
    if !ammo.* {
        play_weapon_sound(.FUSION_EMPTY);
        play_fire_steps(ifx w.secondary then EMPTY_SECONDARY_STEPS else EMPTY_PRIMARY_STEPS);
        return;
    }
    play_weapon_sound(.FUSION);
    wake_for_weapon();
    if w.secondary {
        shoot_spread(*FUSION_SPREAD);
        return;
    }
    matrix := get_weapon_matrix(-p.pitch, -p.object_yaw);
    count := w.owed;
    w.owed = 0;
    w.shots = count;
    // Before this shot's aim: the last shot's.
    second: [9] Fixed;
    if count > 1  second = get_weapon_matrix(-w.fire_pitch, -w.fire_yaw);
    eye_y := get_eye_y();
    while count > 0 && ammo.* {
        out := rotate_vector(FUSION_BARREL_OFFSETS[fusion_barrel - 1], matrix);
        at := Fixed3.{p.position.x + out.x, out.y + eye_y, p.position.z + out.z};
        count -= 1;
        aimed := aim_at_drawn(at, p.pitch, p.object_yaw, weapon.variation);
        if !aimed {
            v := weapon.variation;
            w.fire_pitch = p.pitch + fixed_random(v * 2) - v;
            w.fire_yaw = p.object_yaw + fixed_random(v * 2) - v;
        }
        if !s.supercharged || (w.fire_frame & 1)  ammo.* = clamp(ammo.* - 1, 0, AMMO_MAX[Ammo.POWER]);
        proj := create_projectile(.PLASMA, p.sector, .{p.position.x, eye_y, p.position.z}, OBJECT_IS_PLAYER);
        if !proj break;
        proj.flags &= ~PROJECTILE_PASS_SOUND;
        if aimed {
            set_projectile_heading(proj, w.aim_sin_pitch, w.aim_cos_pitch, w.aim_x, w.aim_z);
            o := world.objects[proj.object];
            o.pitch = cast,no_check(s16) w.fire_pitch;
            o.yaw = cast,no_check(s16) w.fire_yaw;
        } else {
            turn_projectile(proj, w.fire_pitch, w.fire_yaw);
        }
        proj.last_hit = OBJECT_IS_PLAYER;
        proj.delta = out;
        hit := move_projectile(proj);
        if count > 0 && hit == .NONE {
            d := (ifx s.supercharged then cast(s32) 11 else 24) << 16;
            if count >= 2  d = mul16(count << 16, d);
            proj.delta = rotate_vector(.{0, 0, d}, second);
            hit = move_projectile(proj);
        }
        if hit != .NONE  end_projectile(proj, hit);
    }
    w.steps_buffer[0] = .{fusion_barrel, 34, 21, 10, .FUSION_BARRELS};
    w.steps_buffer[1] = .{0, -1, 14, 7, .NONE};
    play_fire_steps(w.steps_buffer);
}

step_fusion_barrel :: () {
    if fusion_barrel_rising {
        fusion_barrel += 1;
        if fusion_barrel > 4 { fusion_barrel = 3; fusion_barrel_rising = false; }
    } else {
        fusion_barrel -= 1;
        if fusion_barrel < 1 { fusion_barrel = 2; fusion_barrel_rising = true; }
    }
}

// The mortar (0x462bc): a shell lobbed up from the eye, a shot owed of shells; the flash,
// its reloading sound, back to rest.
MORTAR_STEPS :: Fire_Step.[
    .{1, 36, 58, 29, .MORTAR_RELOAD},
    .{2, -1, 14, 7, .NONE},
    .{3, -1, 14, 7, .LIGHT_OFF},
    .{0, -1, 14, 7, .NONE},
];

fire_mortar :: () {
    w := *world.weapon;
    weapon := *w.weapons[WEAPON_MORTAR];
    p := *world.player;
    s := *world.player_state;
    ammo := *agent.ammo[Ammo.SHELL];
    if !ammo.* {
        play_weapon_sound(.MORTAR_EMPTY);
        play_fire_steps(EMPTY_STEPS);
        return;
    }
    play_weapon_sound(.MORTAR);
    wake_for_weapon();
    count := w.owed;
    w.owed = 0;
    matrix := get_weapon_matrix(-p.pitch, -p.object_yaw);
    v := weapon.variation;
    // Late frames' shells go up less: a quarter of the lift and scatter.
    if count < 2  w.fire_pitch = p.pitch + 0x333 + fixed_random(v * 2) - v;
    else          w.fire_pitch = p.pitch + (fixed_random(v * 2) - v + 0x333) / 4;
    w.fire_yaw = p.object_yaw + fixed_random(v * 2) - v;
    out := rotate_vector(.{0xB333, 0x1B333, 0x20000}, matrix);
    second: [9] Fixed;
    if count > 1  second = get_weapon_matrix(-w.fire_pitch, -w.fire_yaw);
    eye_y := get_eye_y();
    ahead_z: Fixed;
    while count > 0 && ammo.* {
        count -= 1;
        if !s.supercharged || (w.fire_frame & 1)  ammo.* = clamp(ammo.* - 1, 0, AMMO_MAX[Ammo.SHELL]);
        proj := create_projectile(.MORTAR, p.sector, .{p.position.x, eye_y, p.position.z}, OBJECT_IS_PLAYER);
        if !proj break;
        proj.flags &= ~PROJECTILE_PASS_SOUND;
        turn_projectile(proj, w.fire_pitch, w.fire_yaw);
        proj.last_hit = OBJECT_IS_PLAYER;
        proj.delta = out;
        hit := move_projectile(proj);
        if count > 0 {
            if hit != .NONE { end_projectile(proj, hit); continue; }
            d := (ifx s.supercharged then cast(s32) 37 else 75) << 16;
            if count >= 2  d = mul16(count << 16, d);
            ahead_z += d;
            proj.delta = rotate_vector(.{0, 0, ahead_z}, second);
            hit = move_projectile(proj);
        }
        if hit != .NONE  end_projectile(proj, hit);
    }
    play_fire_steps(MORTAR_STEPS);
}

// The assault cannon (0x46ff0): plasma, its frame held again while fire is; missiles from
// the secondary, after frame 2, with no click when out of them.
fire_cannon :: () {
    w := *world.weapon;
    if w.secondary {
        if !agent.ammo[Ammo.MISSILE] {
            play_fire_steps(EMPTY_MISSILE_STEPS);
            return;
        }
        play_fire_steps(MISSILE_STEPS);
        return;
    }
    if !agent.ammo[Ammo.PLASMA] {
        play_weapon_sound(.CANNON_EMPTY);
        play_fire_steps(EMPTY_PRIMARY_STEPS);
        return;
    }
    play_weapon_sound(.CANNON);
    wake_for_weapon();
    shoot_bolts(*CANNON);
    play_fire_steps(CANNON_STEPS);
}

EMPTY_MISSILE_STEPS :: Fire_Step.[.{0, -1, 7, 3, .EMPTY_MISSILES}];

// The aiming help (0x48028): of the objects drawn last frame that can be aimed at, within
// about 5 degrees of the yaw, the nearest gives the shot's pitch and yaw, toward three
// quarters of its height. The direction the shot flies is set by each one in the cone in
// turn, so it's the last one's: the original's.
aim_at_drawn :: (from: Fixed3, pitch: s32, yaw: s32, variation: s32) -> bool {
    w := *world.weapon;
    closest := FIXED_INFINITY;
    for index: world.drawn_objects {
        o := world.objects[index];
        if !o.used || !o.aimable continue;
        height := (o.height >> 1) + (o.height >> 2);
        dx := o.position.x - from.x;
        dy := o.position.y - height - from.y;
        dz := o.position.z - from.z;
        angle := vec2_to_angle(dx, dz) & ANGLE_MASK;
        off := (angle - yaw) & ANGLE_MASK;
        if off > 227 && off < 16111 continue;
        dir_x, dir_z, distance := get_direction_and_length(dx, dz);
        w.aim_x, w.aim_z = dir_x, dir_z;
        if distance < closest {
            closest = distance;
            w.fire_yaw = angle;
            w.fire_pitch = vec2_to_angle(-dy, distance) & ANGLE_MASK;
        }
    }
    if closest == FIXED_INFINITY return false;
    if variation {
        r := fixed_random(variation << 6) - (variation << 5);
        w.aim_x += r;
        w.aim_z += r;
        w.fire_pitch += fixed_random(variation * 2) + (pitch >> 3) - variation;
    }
    w.aim_sin_pitch, w.aim_cos_pitch = sin_cos(w.fire_pitch);
    return true;
}

#scope_module

// 0x43134: the weapon in hand at its resting frame, after the cheats change the ammo.
reset_weapon_frame :: () {
    w := *world.weapon;
    w.weapons[w.current].frame = get_rest_frame();
}

// The weapon's turn (0x896b8) and a vector turned by it (0x89868).
get_weapon_matrix :: (pitch: s32, yaw: s32) -> [9] Fixed {
    sin_pitch, cos_pitch := sin_cos(pitch);
    sin_yaw, cos_yaw := sin_cos(yaw);
    return .[cos_yaw, 0, sin_yaw,
             mul16(sin_yaw, sin_pitch), cos_pitch, -mul16(cos_yaw, sin_pitch),
             -mul16(sin_yaw, cos_pitch), sin_pitch, mul16(cos_pitch, cos_yaw)];
}

rotate_vector :: (v: Fixed3, m: [9] Fixed) -> Fixed3 {
    return .{mul16(v.x, m[0]) + mul16(v.y, m[3]) + mul16(v.z, m[6]),
             mul16(v.x, m[1]) + mul16(v.y, m[4]) + mul16(v.z, m[7]),
             mul16(v.x, m[2]) + mul16(v.y, m[5]) + mul16(v.z, m[8])};
}

#scope_file
