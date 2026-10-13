// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The cheat codes, as DARK.EXE takes them in a level (0x120b2, 0x132ca): L, then A, arms
// it; each key after goes on the end of what's been typed, matched against the 27 codes
// (kept in the executable without their LA, each letter less 0x3c). A whole code runs it, a
// start of one waits for more, anything else ends it, and it takes L and A again. The keys
// still do what they do in the game.
//
// The toggles are the original's globals, which nothing resets: they outlast the level and
// the agent.

Cheat :: enum s32 {
    NONE;
    CDS;            // The map's reveal modes.
    NTFH;           // To the map's centre.
    POGO;           // The step height.
    RANDY;          // Supercharge.
    IMLAME;         // Invincibility.
    POSTAL;         // Weapons and ammo.
    DATA;           // Coordinates.
    BUG;            // Insect mode.
    REDLITE;        // The AI.
    SECBASE; TALAY; SEWERS; TESTBASE; GROMAS; DTENTION; RAMSHED; ROBOTICS; NARSHADA; JABSHIP;
    IMPCITY; FUELSTAT; EXECUTOR; ARC;
    SKIP;           // The mission complete.
    BRADY;          // Ammo.
    UNLOCK;         // Keys and items.
    MAXOUT;         // Everything.
}

// The codes after their LA, in the table's order (0xe4d11).
CHEAT_CODES :: string.["cds", "ntfh", "pogo", "randy", "imlame", "postal", "data", "bug",
    "redlite", "secbase", "talay", "sewers", "testbase", "gromas", "dtention", "ramshed",
    "robotics", "narshada", "jabship", "impcity", "fuelstat", "executor", "arc", "skip",
    "brady", "unlock", "maxout"];

cheats: struct {
    height_check := true;           // 0xe48d0: off (LAPOGO), any step is climbed.
    bug: bool;                      // 0xe48d4: LABUG, the player 0.3 across and low.
    ai := true;                     // 0xe48bc: off (LAREDLITE), the enemies' tasks stand still.
    data: bool;                     // 0xe5608: LADATA's readout on the HUD.
};

// A key pressed in a level, as the character the original's table gives its scan code
// (0x2129c): the letter, lower case, a digit or sign, 0 for keys without one.
world_type_cheat_key :: (c: u8) {
    if !world.loaded return;
    t := *world.cheat_typing;
    // What's been typed goes first, from its own queue, then the keys' (0x120b2).
    if t.state == .TYPING {
        if t.count < t.typed.count - 1 {
            t.typed[t.count] = c;
            t.count += 1;
        }
        cheat := match_cheat();
        if cheat != .NONE  run_cheat(cheat);
    }
    if t.state == .ARMED {
        if c == #char "a" {
            t.state = .TYPING;
            t.count = 0;
        } else {
            t.state = .IDLE;
        }
    }
    if c == #char "l" && t.state != .TYPING  t.state = .ARMED;
}

// For tests.
world_get_cheats :: () -> type_of(cheats) { return cheats; }

world_reset_cheats :: () { cheats = .{}; }

// A cheat's way out of the level (0xe495b), once the frame after it has run, as the main
// loop looks for it at the start of its next turn: the mission to go to, or 0 to go on
// from this one (LASKIP).
world_get_level_exit :: () -> bool, s32 {
    e := *world.level_exit;
    return e.state == .DUE, e.mission;
}

// LADATA's readout (0x1bb43): the player's x and z in whole units, or the map's centre while
// the map is up; the feet's height and the eye's above them to a tenth; the secrets found.
world_get_data_readout :: () -> string {
    p := *world.player;
    x, z := p.position.x, p.position.z;
    if automap.on  x, z = automap.center_x, automap.center_z;
    return tprint("X:% Y:% Z:% H:% S:%\%", format_zero_padded(x >> 16), format_tenths(-p.position.y),
                  format_zero_padded(z >> 16), format_tenths(p.height), world.player_state.secrets_percent);
}

#scope_module

Cheat_Typing :: struct {
    state: enum u8 { IDLE; ARMED; TYPING; };  // 0xe4d7d: 0, L pressed, L and A.
    typed: [16] u8;                 // 0xf9afc
    count: s32;                     // 0xfa01c
}

Level_Exit :: struct {
    state: enum u8 { NONE; ASKED; DUE; };
    mission: s32;
}

// A frame has run: a way out asked for before it is due now.
pass_level_exit :: () {
    if world.level_exit.state == .ASKED  world.level_exit.state = .DUE;
}

// A yield of an enemy's task, or anything else the AI covers (0x338c8). With the AI on it
// sleeps the ticks asked for (-1 until a message); off, it wakes every 291 ticks to look
// again, and goes on only when it's back on. A message yields without touching the wake, but
// still as the AI is.
yield_ai_task :: (wake: *s32, polling: *bool, ticks: s32, in_message: bool) {
    polling.* = !cheats.ai;
    if in_message return;
    if polling.*      wake.* = world.clock.tick + AI_POLL_TICKS;
    else if ticks < 0 wake.* = -1;
    else              wake.* = world.clock.tick + ticks;
}

// Whether a task waiting at such a yield runs on its own in this turn.
is_ai_task_due :: (wake: *s32, polling: *bool) -> bool {
    if wake.* < 0 || wake.* > world.clock.tick return false;
    if polling.* {
        if !cheats.ai {
            wake.* = world.clock.tick + AI_POLL_TICKS;
            return false;
        }
        polling.* = false;
    }
    return true;
}

AI_POLL_TICKS :: 0x123;

#scope_file

// What's been typed against the codes (0x132ca): a code it spells out, or none, and when it
// doesn't start one, the typing ended.
match_cheat :: () -> Cheat {
    t := *world.cheat_typing;
    longest: s32;
    for code, index: CHEAT_CODES {
        for i: 0..t.count {
            want := ifx i < code.count then code[i] else 0;
            got := ifx i < t.count then t.typed[i] else 0;
            if want != got break;
            longest = max(longest, i + 1);
            if want == 0 {
                end_cheat_typing();
                return xx (index + 1);
            }
        }
    }
    if longest != t.count  end_cheat_typing();
    return .NONE;
}

end_cheat_typing :: () {
    world.cheat_typing = .{};
}

// What each code does (0x120b2).
run_cheat :: (cheat: Cheat) {
    s := *world.player_state;
    if cheat == {
        case .CDS;
            world_send_automap_message(.REVEAL);
        case .NTFH;
            world_send_automap_message(.TELEPORT);
            // The map locked again (0x13590), the arrows the player's.
            automap.locked = true;
        case .POGO;
            cheats.height_check = !cheats.height_check;
            send_message(MSG_CHEAT_HEIGHT_CHECK);
        case .RANDY;
            // Made in the main loop's turn, so its child.
            start_supercharge(world.tasks.main);
            send_message(MSG_CHEAT_SUPERCHARGE);
        case .IMLAME;
            s.invincible = ifx s.invincible == -2 then cast(s32) 0 else -2;
            send_message(MSG_CHEAT_INVINCIBLE);
        case .POSTAL;
            give_weapons_and_ammo();
            send_message(MSG_CHEAT_WEAPONS);
        case .DATA;
            cheats.data = !cheats.data;
        case .BUG;
            cheats.bug = !cheats.bug;
            send_message(MSG_CHEAT_BUG);
        case .REDLITE;
            cheats.ai = !cheats.ai;
            send_message(MSG_CHEAT_AI);
        case .SKIP;
            // As a COMPLETE stop, without its messages (0x10867).
            world.mission_complete = true;
            world.level_exit = .{state = .ASKED};
        case .BRADY;
            give_ammo();
            send_message(MSG_CHEAT_AMMO);
        case .UNLOCK;
            give_inventory();
            send_message(MSG_CHEAT_INVENTORY);
        case .MAXOUT;
            give_weapons_and_ammo();
            give_inventory();
            send_message(MSG_CHEAT_EVERYTHING);
        case;
            // The missions, SECBASE to ARC (0x108eb).
            world.level_exit = .{state = .ASKED, mission = cast(s32) cheat - cast(s32) Cheat.SECBASE + 1};
    }
}

// "%04d": negative, the sign takes one of the four.
format_zero_padded :: (n: s32) -> string {
    if n < 0  return tprint("-%", formatInt(-n, minimum_digits = 3));
    return tprint("%", formatInt(n, minimum_digits = 4));
}

// "%.1f" of a 16.16 value: rounded to the nearest tenth (never halfway), a negative value
// keeping its sign even when it rounds to 0.
format_tenths :: (v: Fixed) -> string {
    magnitude := abs(cast(s64) v) * 10;
    tenths := (magnitude + 0x8000) >> 16;
    text := tprint("%.%", tenths / 10, tenths % 10);
    if v < 0  text = tprint("-%", text);
    return text;
}

MSG_CHEAT_HEIGHT_CHECK :: 700;
MSG_CHEAT_SUPERCHARGE  :: 701;
MSG_CHEAT_INVINCIBLE   :: 702;
MSG_CHEAT_WEAPONS      :: 703;
MSG_CHEAT_BUG          :: 705;
MSG_CHEAT_AI           :: 706;
MSG_CHEAT_AMMO         :: 708;
MSG_CHEAT_INVENTORY    :: 709;
MSG_CHEAT_EVERYTHING   :: 710;

#import "Basic";
#import "Math";
#import "engine/dfFixed";
