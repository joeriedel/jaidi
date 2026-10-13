// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The order the game's logic runs in within a frame: the original's tasks (create 0x1d62e and
// 0x1d6db, end 0x1d7de, the scheduler 0x1db78).
//
// Tasks form a tree. One made while another runs is that one's child, put first among its
// children; a few are made with no parent and go round a ring in the order they were made:
// the level's task (0x10969), the main loop (0x10bd1), the player (0x2aac4), and on first use
// the sprite animations (0x4c1c8) and LOGIC: UPDATE (0x8ae8c). Most of the game's tasks are
// the level task's children, made as it sets the level up: the init's, then the O file's in
// order. From a task the scheduler goes to its next older sibling's newest descendant, or
// with no older sibling to its parent: children run before their parent, the newest first,
// and the ring's tasks in the order they were made. A frame is one lap, from the main loop's
// yield back round to it: so the player, the sprite animations and LOGIC: UPDATE, then the
// level's objects last made first, the hit effects, the free movement, the actors, the
// teleporters, the pickups' timers, the elevators, the projectiles and the weapon, then the
// main loop's children and the main loop.
//
// A task that ends in its own turn sends the scheduler on from its next newer sibling, or
// with none from its parent, which then counts as run: when the newest of a family ends, its
// older siblings and the parent wait for the next lap. Each task here runs only if its own
// time has come, as the scheduler checks before switching to it.

Task_Kind :: enum u8 {
    ROOT;               // The ring's head (0xe566c), never run.
    LEVEL;              // 0x10969: sets the level up, then sleeps until it ends.
    MAIN;               // 0x10bd1: the keys, the view, the HUD.
    PLAYER;             // 0x2aac4
    SPRITE_ANIMATIONS;  // 0x4c1c8
    UPDATE_LOGICS;      // 0x8ae8c
    TEXTURES;           // 0x162d0: animated textures, which the drawing takes from the clock here.
    WEAPON;             // 0x428f0
    PROJECTILES;        // 0x4ad84
    ELEVATORS;          // 0x35e70
    END_MESSAGES;       // 0x12a65, the elevators' child once the mission is complete.
    PICKUPS;            // 0x31a11: only messages.
    INVINCIBILITY;      // 0x2fbe8, the pickups' child.
    SUPERCHARGE;        // 0x48238, the pickups' child.
    TELEPORTERS;        // 0x37b80
    TRIGGERS;           // 0x3776c: only messages.
    ACTORS;             // 0x25ef8
    FREE_MOVES;         // 0x267a0
    HIT_EFFECTS;        // 0x4b890
    MUSIC;              // 0x239ae: only messages.
    SOUND_OBJECTS;      // 0x154f8: the O file's sounds.
    LEVEL_SOUNDS;       // 0x15457: the INF's amb_sound.
    VUE;                // 0x301c1
    GENERATOR;          // 0x33c58
    TURRET;             // 0x341b4
    MOUSEBOT;           // 0x3a8f8
    WELDER;             // 0x3b424
    DARK_TROOPER;       // 0x3c078, 0x3da40, 0x3f7f0
    BOBA_FETT;          // 0x37fb8
    KELL_DRAGON;        // 0x38f6c
    BREATHING;          // 0x2fc74, the main loop's child.
    CHOKING;            // 0x2fcb4, the player's child.
}

// The tasks in the order a frame runs them, from the main loop's yield round to it.
world_get_task_order :: () -> [..] Task_Kind {
    order: [..] Task_Kind;
    order.allocator = temp;
    s := *world.tasks;
    if !s.built return order;
    t := get_next_task(s.main);
    while true {
        array_add(*order, t.kind);
        if t == s.main break;
        t = get_next_task(t);
    }
    return order;
}

#scope_module

Task :: struct {
    kind: Task_Kind;
    data: *void;                // What it runs: a turret, a generator...
    index: s32 = -1;            // Into world.vues, for a VUE; -1 for a key with no path.
    parent: *Task;              // None for the ring's.
    child: *Task;               // The newest child.
    older, newer: *Task;        // Siblings; for the ring's, the next and the one before.
}

Tasks :: struct {
    root: Task;
    last: *Task;                // The ring's newest (0xe5658).
    level, main, player, sprite_animations, update_logics: *Task;
    weapon, projectiles, elevators, pickups, actors, free_moves, hit_effects: *Task;
    end_messages, invincibility, supercharge, breathing, choking: *Task;
    current: *Task;             // The task the scheduler is running.
    ended: bool;                // It ended in its turn,
    resume: *Task;              // and the scheduler goes on from here.
    built: bool;                // The level is set up: tasks made now have a parent.
    spawn_parent: *Task;        // The generator making an enemy.
    load_logic: s32;            // The O file's logic being set up.
    pending: [..] Pending_Task; // Made while the level loads, put in the O file's order.
    input: World_Input;         // This frame's, for the player's task.
}

Pending_Task :: struct {
    object, logic: s32;         // Where in the O file; logic -1 before the object's logics.
    kind: Task_Kind;
    data: *void;
    index: s32;
    out: **Task;
}

// A task for one of the O file's objects (0x1582e), or for an enemy a generator makes. While
// the level loads it waits to be put among the level task's children in the O file's order.
create_object_task :: (kind: Task_Kind, data: *void, object: s32, out: **Task, index: s32 = -1) {
    s := *world.tasks;
    if !s.built {
        array_add(*s.pending, .{object = object, logic = s.load_logic, kind = kind, data = data, index = index, out = out});
        return;
    }
    parent := ifx s.spawn_parent then s.spawn_parent else s.level;
    out.* = add_child_task(parent, kind, data);
    out.*.index = index;
}

// The level's tasks as the original makes them: the ring, then the level task's children,
// the init's (0x11e88), the objects' (0x14aaf, 0x1582e) and the INF's level sounds
// (0x1638d). The sprite animations and LOGIC: UPDATE join the ring as the first object that
// needs them is read.
build_tasks :: () {
    s := *world.tasks;
    s.root = .{kind = .ROOT};
    s.root.older = *s.root;
    s.root.newer = *s.root;
    s.last = *s.root;
    s.level = add_top_task(.LEVEL);
    s.main = add_top_task(.MAIN);
    level := s.level;
    add_child_task(level, .TEXTURES);
    s.weapon = add_child_task(level, .WEAPON);
    s.projectiles = add_child_task(level, .PROJECTILES);
    s.player = add_top_task(.PLAYER);
    s.elevators = add_child_task(level, .ELEVATORS);
    s.pickups = add_child_task(level, .PICKUPS);
    add_child_task(level, .TELEPORTERS);
    add_child_task(level, .TRIGGERS);
    s.actors = add_child_task(level, .ACTORS);
    s.free_moves = add_child_task(level, .FREE_MOVES);
    s.hit_effects = add_child_task(level, .HIT_EFFECTS);
    add_child_task(level, .MUSIC);

    // With what the objects made as they were set up, the O file's sounds and the first
    // object of each that needs the ring's.
    for * l, index: world.level_objects.objects {
        if !is_object_in_difficulty(l, world.object_difficulty) continue;
        if l.class == .SOUND {
            add_sound_object(l);
            array_add(*s.pending, .{object = xx index, logic = -1, kind = .SOUND_OBJECTS});
        }
        if world.objects[index].sector < 0 continue;
        anim := find_logic(l, "ANIM");
        if anim >= 0 && l.class == .SPRITE  array_add(*s.pending, .{object = xx index, logic = anim, kind = .SPRITE_ANIMATIONS});
        for l.logics  if it == "UPDATE"  array_add(*s.pending, .{object = xx index, logic = xx it_index, kind = .UPDATE_LOGICS});
    }
    sort_pending :: (a: Pending_Task, b: Pending_Task) -> s64 {
        if a.object != b.object return a.object - b.object;
        return a.logic - b.logic;
    }
    // A stable sort: two tasks for one logic keep the order they were made in.
    for i: 1..s.pending.count-1 {
        p := s.pending[i];
        j := i - 1;
        while j >= 0 && sort_pending(s.pending[j], p) > 0 {
            s.pending[j + 1] = s.pending[j];
            j -= 1;
        }
        s.pending[j + 1] = p;
    }
    sound_objects := false;
    for s.pending {
        if it.kind == {
            case .SOUND_OBJECTS;
                // Made with the first (0x153d7).
                if !sound_objects  add_child_task(level, .SOUND_OBJECTS);
                sound_objects = true;
            case .SPRITE_ANIMATIONS;
                if !s.sprite_animations  s.sprite_animations = add_top_task(.SPRITE_ANIMATIONS);
            case .UPDATE_LOGICS;
                if !s.update_logics  s.update_logics = add_top_task(.UPDATE_LOGICS);
            case;
                t := add_child_task(level, it.kind, it.data);
                t.index = it.index;
                if it.out  it.out.* = t;
        }
    }
    array_reset(*s.pending);
    // Set up as the INF is read, after the objects (0x1638d).
    if world.inf.level_sounds  add_child_task(level, .LEVEL_SOUNDS);
    for world.inf.level_sounds  add_level_sound(it);
    s.built = true;
}

// The sprite animations' task, made on the first (0x4c00c).
need_sprite_animation_task :: () {
    s := *world.tasks;
    if s.built && !s.sprite_animations  s.sprite_animations = add_top_task(.SPRITE_ANIMATIONS);
}

free_tasks :: () {
    s := *world.tasks;
    if s.built {
        t := s.root.older;
        while t != *s.root {
            next := t.older;
            free_task_tree(t);
            t = next;
        }
    }
    for s.pending  if it.out  it.out.* = null;
    array_reset(*s.pending);
}

add_top_task :: (kind: Task_Kind) -> *Task {
    s := *world.tasks;
    t := New(Task);
    t.kind = kind;
    t.older = s.last.older;
    t.newer = s.last;
    s.last.older = t;
    s.last = t;
    return t;
}

add_child_task :: (parent: *Task, kind: Task_Kind, data: *void = null) -> *Task {
    t := New(Task);
    t.kind = kind;
    t.data = data;
    t.parent = parent;
    t.older = parent.child;
    if parent.child  parent.child.newer = t;
    parent.child = t;
    return t;
}

// A task ends (0x1d7de), with its children. Ended in its own turn (or one of its children's),
// the scheduler goes on from its next newer sibling, or its parent.
end_task :: (t: *Task) {
    if !t return;
    s := *world.tasks;
    if !s.ended && is_task_within(s.current, t) {
        s.ended = true;
        s.resume = ifx t.newer then t.newer else t.parent;
    }
    if t.newer {
        t.newer.older = t.older;
    } else if t.parent {
        t.parent.child = t.older;
    }
    if t.older  t.older.newer = t.newer;
    if s.last == t  s.last = t.newer;
    free_task_tree(t);
}

// One frame's lap, from the main loop round to it.
run_tasks :: () {
    s := *world.tasks;
    if !s.built return;
    t := get_next_task(s.main);
    while t != s.main {
        s.current = t;
        s.ended = false;
        run_task(t);
        if s.ended  t = s.resume;
        t = get_next_task(t);
    }
    s.current = null;
    s.ended = false;
}

// A list's gone entries taken out, the rest kept in order: between runs over lists kept in
// the order things were added.
remove_nulls :: (list: *[..] *$T) {
    n := 0;
    for list.*  if it { list.*[n] = it; n += 1; }
    list.count = n;
}

// Which of an object's logics is the one named, by its first word; -1 for none.
find_logic :: (object: *Level_Object, name: string) -> s32 {
    for object.logics {
        found, first := split_from_left(it, #char " ");
        if !found  first = it;
        if first == name return xx it_index;
    }
    return -1;
}

#scope_file

is_task_within :: (t: *Task, ancestor: *Task) -> bool {
    while t {
        if t == ancestor return true;
        t = t.parent;
    }
    return false;
}

// The scheduler's step (0x1db78).
get_next_task :: (t: *Task) -> *Task {
    if !t.older return t.parent;
    n := t.older;
    while n.child  n = n.child;
    return n;
}

free_task_tree :: (t: *Task) {
    c := t.child;
    while c {
        next := c.older;
        free_task_tree(c);
        c = next;
    }
    free(t);
}

run_task :: (t: *Task) {
    if t.kind == {
        case .PLAYER;               update_player(world.tasks.input);
        case .SPRITE_ANIMATIONS;    update_sprite_animations();
        case .UPDATE_LOGICS;        update_update_logics();
        case .WEAPON;               update_weapon();
        case .PROJECTILES;          update_projectiles();
        case .ELEVATORS;            update_elevators();
        case .END_MESSAGES;         update_end_messages();
        case .INVINCIBILITY;        update_invincibility();
        case .SUPERCHARGE;          update_supercharge();
        case .TELEPORTERS;          update_teleports();
        case .ACTORS;               update_actors();
        case .FREE_MOVES;           update_free_moves();
        case .HIT_EFFECTS;          update_hit_effects();
        case .VUE;                  update_vue(t.index);
        case .GENERATOR;            update_generator(cast(*Generator) t.data);
        case .TURRET;               update_turret(cast(*Turret) t.data);
        case .MOUSEBOT;             update_mousebot(cast(*Mousebot) t.data);
        case .WELDER;               update_welder(cast(*Welder) t.data);
        case .DARK_TROOPER;         update_dark_trooper(cast(*Dark_Trooper) t.data);
        case .BOBA_FETT;            update_boba_fett(cast(*Boba_Fett) t.data);
        case .KELL_DRAGON;          update_kell_dragon(cast(*Kell_Dragon) t.data);
        case .BREATHING;            update_breathing();
        case .CHOKING;              update_choking();
        case .SOUND_OBJECTS;        update_sound_objects();
        case .LEVEL_SOUNDS;         update_level_sounds();
    }
}

#import "Basic";
#import "String";
#import "engine/dfLevel";
