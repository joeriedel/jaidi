// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Generators (LOGIC: GENERATOR <enemy>, 0x338f4): a place that sends out enemies of a kind,
// one every interval, while the player is far enough off and can't see it, up to so many at
// once and so many in all. Each enemy comes awake, made in the generator's art, and hunts
// the player for its wander time before it may give up. The generator itself is taken out of
// sight and out of the way.
//
// Its task (0x33c58) is written as the places it waits at. Messages reach it at once, from
// the INF (MASTER_ON and MASTER_OFF to its sector) and from its enemies going; as with every
// task, a message doesn't restart the wait it came in, and messages during the first delay
// are lost.

#scope_module

Generator :: struct {
    object: s32;
    logic: string;              // The enemy it makes: "STORM1".
    art_class: Object_Class;    // Its art, which its enemies take.
    art_data: s32;
    on := true;                 // Any MASTER: line in the O file turns it off.
    delay: s32;                 // Ticks before it starts.
    interval: s32;              // Ticks between enemies.
    max_alive: s32 = 4;
    min_distance: Fixed = 60 * FIXED_ONE;
    max_distance: Fixed = 200 * FIXED_ONE;
    alive: [..] s32;            // Its enemies' objects.
    terminate: s32 = -1;        // How many more it makes; below 0, no end.
    wander: s32 = 0x4446;       // Ticks its enemies hunt before they can give up; -1 forever.

    wait: Generator_Wait;
    wake: s32;                  // When the task runs next: -1 never.
    task: *Task;
}

Generator_Wait :: enum u8 {
    START;                      // Created, not run yet.
    DELAY;                      // The first delay.
    INTERVAL;                   // Between enemies, or for good once it has made them all.
}

// What reaches a generator's task (the original's message ids).
Generator_Message :: enum s32 {
    RUN        :: 0;
    GONE       :: 1;            // One of its enemies went.
    WAKEUP     :: 0x19;
    MASTER_ON  :: 0x1D;
    MASTER_OFF :: 0x1E;
}

// The O file's generator on an object (0x338f4), from its logic (into the object's logics);
// the lines after that logic are its parameters (0x33af4).
create_generator :: (object: s32, logic: string, level_object: *Level_Object, logic_index: s32) {
    g := New(Generator);
    array_add(*world.generators, g);
    create_object_task(.GENERATOR, g, object, *g.task);
    g.object = object;
    g.logic = logic;
    g.interval = (fixed_random(0x2D8_0000) >> 16) + 0xB61;
    for level_object.params {
        if it.logic != logic_index continue;
        value := read_seq_int(it.value);
        if it.key == {
            case "DELAY:";          g.delay = value * 145;
            // The value is read twice: the random part is up to half the seconds, in ticks.
            case "INTERVAL:";       g.interval = value * 145 + (fixed_random((value / 2) << 16) >> 16);
            case "MAX_ALIVE:";      g.max_alive = value;
            case "MIN_DIST:";       g.min_distance = value << 16;
            case "MAX_DIST:";       g.max_distance = value << 16;
            case "NUM_TERMINATE:";  g.terminate = value;
            case "WANDER_TIME:";    g.wander = ifx value == -1 then -1 else value * 145;
            case "MASTER:";         g.on = false;
        }
    }
    o := world.objects[object];
    g.art_class, g.art_data = o.class, o.data;
    o.class = .SPIRIT;
    o.data = -1;
    o.width, o.height = 0, 0;
    o.entity |= ENTITY_GENERATOR;
}

unload_generators :: () {
    for world.generators {
        array_free(it.alive);
        free(it);
    }
    array_free(world.generators);
}

// Its task's turn (tasks.jai), if its time has come.
update_generator :: (g: *Generator) {
    if g.wake < 0 || g.wake > world.clock.tick return;
    run_generator(g, .RUN, -1);
}

// A message to the generators on a sector's objects (0x5add0).
send_sector_generator_message :: (sector: s32, message: Generator_Message) {
    for index: walk_sector(sector) {
        if !(world.objects[index].entity & ENTITY_GENERATOR) continue;
        for world.generators  if it.object == index  run_generator(it, message, -1);
    }
}

// An actor a generator made is going.
tell_generator_gone :: (generator: s32, object: s32) {
    if generator < 0 || generator >= world.generators.count return;
    run_generator(world.generators[generator], .GONE, object);
}

#scope_file

// The task from where it waits, on its own (RUN) or for a message.
run_generator :: (g: *Generator, message: Generator_Message, object: s32) {
    if g.wait == {
        case .START;
            wait_generator(g, .DELAY, g.delay, message);
        case .DELAY;
            if message == .RUN  wait_generator(g, .INTERVAL, g.interval, message);
        case .INTERVAL;
            if message == {
                case .RUN;
                    if g.terminate == 0 {
                        wait_generator(g, .INTERVAL, -1, message);
                        return;
                    }
                    if g.on && g.alive.count < g.max_alive  send_out_enemy(g);
                case .GONE;
                    for g.alive  if it == object { array_ordered_remove_by_index(*g.alive, it_index); break; }
                case .MASTER_ON;
                    g.on = true;
                case .MASTER_OFF;
                    g.on = false;
            }
            wait_generator(g, .INTERVAL, g.interval, message);
    }
}

// A yield (0x1d793): only a run of its own sets when the task runs next.
wait_generator :: (g: *Generator, wait: Generator_Wait, ticks: s32, message: Generator_Message) {
    g.wait = wait;
    if message != .RUN return;
    g.wake = ifx ticks < 0 then -1 else world.clock.tick + ticks;
}

// A new object at the generator, facing at random; when the player is within range and can't
// see it from 7 units up there, an enemy, otherwise freed. One out of range is left where it
// is, an object with nothing to it, as in the original.
send_out_enemy :: (g: *Generator) {
    generator := world.objects[g.object];
    index := add_object(.SPIRIT, -1, generator.position, -1);
    o := world.objects[index];
    o.width, o.height = -1, -1;
    o.yaw = cast(s32) (fixed_random_next() & cast(u32) ANGLE_MASK);
    change_object_sector(index, generator.sector);
    p := *world.player;
    distance := dist_approx(generator.position.x, generator.position.z, p.position.x, p.position.z) + abs(p.position.y - generator.position.y);
    if distance < g.min_distance || distance > g.max_distance return;
    o.height = 7 * FIXED_ONE;
    if can_see_player(o) {
        free_object(index);
        return;
    }
    // Its height stays 7: only the width comes from the art.
    o.class, o.data = g.art_class, g.art_data;
    set_object_size(o, -1, o.height);
    // An enemy with a task of its own is the generator's task's child.
    world.tasks.spawn_parent = g.task;
    create_enemy(index, g.logic);
    world.tasks.spawn_parent = null;
    actor := o.actor;
    if actor {
        actor.flags &= ~ACTOR_IDLE;
        for world.generators  if it == g  actor.generator = xx it_index;
        lost_sight_tick := NEVER;
        if g.wander != -1 {
            spread := fixed_random(cast,no_check(Fixed) ((cast(u32) g.wander >> 1) << 16)) >> 16;
            lost_sight_tick = cast(u32) (world.clock.tick + g.wander + spread);
        }
        attack := get_attack_module(actor);
        if attack  attack.lost_sight_tick = lost_sight_tick;
    }
    array_add(*g.alive, index);
    g.terminate -= 1;
    clear_hidden_corpse();
}

// One corpse out of the player's sight goes (0x33a38), looking from a sector at random on,
// to keep the objects down. The bosses' stay.
clear_hidden_corpse :: () {
    count := world.level.sectors.count;
    start := fixed_random(cast(s32) (count - 1) << 16) >> 16;
    for n: 0..count-1 {
        sector := (start + n) % count;
        for index: walk_sector(xx sector, live = true) {
            o := world.objects[index];
            if !(o.entity & ENTITY_CORPSE) || (o.entity & ENTITY_KEPT_CORPSE) || can_see_player(o) continue;
            free_object(index);
            return;
        }
    }
}

#import "Basic";
#import "engine/dfFixed";
#import "engine/dfLevel";
