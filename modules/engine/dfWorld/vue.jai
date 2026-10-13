// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Objects moved along VUE paths: LOGIC: KEY (0x2fd5b), Kyle's ship taking off and landing,
// the flybys. Its task (0x301c6) runs once a frame, playing the frames on the game's clock,
// 9 ticks a frame unless FRAME_RATE: says otherwise, skipping frames when the game falls
// behind; each frame sets the object's matrix and position, and its yaw to 0x1FFF. With
// PAUSE:, each file's frames wait at their start for a message, any message: the INF's
// wakeup to the sector the object is in. Without, the path loops.
//
// The object's sector follows it along a path through openings from where it was, or by
// the smallest sector holding it at the start of each pass; a path that hits a wall leaves
// it in none for a frame.

// Where Enhanced Mode draws an object on a path: between its frames; false when it isn't
// moving along one. For tests.
world_get_vue_in_between :: (object: s32) -> bool, Fixed3 {
    moving, position := get_vue_in_between(object);
    return moving, position;
}

#scope_module

Vue_State :: enum u8 {
    START;          // A pass through the frames begins.
    EMPTY;          // No frames: asleep for good.
    PAUSED;         // At a file's start, asleep until a message.
    WOKEN;          // Woken: on to the frames next frame.
    SHOWN;          // A frame shown: on by the clock next frame.
}

Vue_Logic :: struct {
    object: s32;
    frames: [..] Vue_Frame;
    delay: s32 = 9;                 // Ticks a frame.
    pause: bool;
    state: Vue_State;
    frame: s32;                     // Into frames.
    start_tick: s32;
    shown: s32;                     // Frames the clock had counted at the last step.
    pause_tick: s32;
    find_sector: bool;
    sector: s32 = -1;
    ran_frame: s32 = -1;            // The frame tick it last ran on.
}

// Objects with LOGIC: KEY and a VUE: get a path. Each KEY has its task, asleep for good
// without one.
load_vues :: () {
    for * object, index: world.level_objects.objects {
        if world.objects[index].sector < 0 continue;
        key := find_logic(object, "KEY");
        if key < 0 continue;
        world.tasks.load_logic = xx key;
        if !object.vues {
            create_object_task(.VUE, null, xx index, null);
            continue;
        }
        v: Vue_Logic;
        v.object = xx index;
        v.pause = object.pause;
        if object.frame_rate  v.delay = cast(s32) ((1.0 / object.frame_rate) * 145.65);
        for object.vues {
            if !it.append  array_reset(*v.frames);
            data, found := gob_find(it.file);
            if !found { log_error("No %.", it.file); continue; }
            vue_parse(cast(string) data, it.name, *v.frames);
        }
        v.sector = world.objects[index].sector;
        create_object_task(.VUE, null, xx index, null, xx world.vues.count);
        array_add(*world.vues, v);
    }
}

unload_vues :: () {
    for * world.vues  array_free(it.frames);
    array_free(world.vues);
}

// Its task's turn (tasks.jai).
update_vue :: (index: s32) {
    if index < 0 return;
    v := *world.vues[index];
    if v.ran_frame == world.clock.frame_tick return;
    if v.state == .WOKEN || v.state == .SHOWN || v.state == .START  run_vue(v);
}

// The INF's wakeup to a sector's objects (0x5add0), in one walk: the enemies and the
// objects on paths, whose task takes any message as a call to go on.
wake_sector_objects :: (sector: s32) {
    for index: walk_sector(sector) {
        for * world.vues  if it.object == index { run_vue(it); break; }
        actor := world.objects[index].actor;
        if actor  send_actor_message(actor, .WAKEUP);
    }
}

// The original's task (0x301c6), from where it last yielded.
run_vue :: (v: *Vue_Logic) {
    v.ran_frame = world.clock.frame_tick;
    tick := world.clock.tick;
    if v.state == {
        case .EMPTY;
            return;
        case .PAUSED;
            v.start_tick += tick - v.pause_tick;
            v.state = .WOKEN;
            return;
        case .WOKEN;
            v.frame += 1;
        case .SHOWN;
            // Frames the clock has reached since the start, unsigned as the original divides.
            now := cast(s32) ((cast(u32) (tick - v.start_tick)) / cast(u32) v.delay);
            while v.shown != now {
                v.frame += 1;
                if v.frame >= v.frames.count || (v.pause && v.frames[v.frame].first) break;
                v.shown += 1;
            }
    }
    while true {
        if v.state == .START || v.frame >= v.frames.count {
            if !v.frames { v.state = .EMPTY; return; }
            v.frame = 0;
            v.find_sector = true;
            v.start_tick = tick;
            v.shown = 0;
            v.state = .SHOWN;
        }
        f := *v.frames[v.frame];
        if f.first {
            if v.pause {
                v.pause_tick = tick;
                v.state = .PAUSED;
                return;
            }
            v.frame += 1;
            continue;
        }
        show_vue_frame(v, f);
        v.state = .SHOWN;
        return;
    }
}

// For Enhanced Mode, not the original: where an object on a path is drawn between the frame
// it shows and the next, by how far the clock has gone toward the next, its matrix blended
// and its axes squared up again at their blended lengths. False when it isn't moving along
// a path, or the next frame starts a file or the path over.
get_vue_in_between :: (object: s32) -> bool, Fixed3, [9] Fixed {
    for * v: world.vues {
        if v.object != object continue;
        if v.state != .SHOWN || v.frame + 1 >= v.frames.count || v.frames[v.frame + 1].first break;
        a, b := *v.frames[v.frame], *v.frames[v.frame + 1];
        since := world.clock.time - cast(float64) (v.start_tick + v.shown * v.delay);
        t := cast(float) clamp(since / v.delay, 0, 1);
        to_fixed :: (f: float) -> Fixed { return cast(Fixed) (f * 65536.0); }
        blend :: (x: Fixed, y: Fixed, t: float) -> float { return fixed_to_float(x) + (fixed_to_float(y) - fixed_to_float(x)) * t; }
        position: Fixed3;
        position.x = to_fixed(blend(a.position.x, b.position.x, t));
        position.y = to_fixed(blend(a.position.y, b.position.y, t));
        position.z = to_fixed(blend(a.position.z, b.position.z, t));
        // The matrix's columns are where the model's axes go.
        axes: [3] Vector3;
        squared: [3] Vector3;
        for j: 0..2 {
            column :: (m: [9] Fixed, j: int) -> Vector3 { return .{fixed_to_float(m[j]), fixed_to_float(m[3 + j]), fixed_to_float(m[6 + j])}; }
            from, to := column(a.matrix, j), column(b.matrix, j);
            axis := from + (to - from) * t;
            size := length(from) + (length(to) - length(from)) * t;
            for k: 0..j-1  axis -= squared[k] * dot(axis, squared[k]);
            squared[j] = normalize(axis);
            axes[j] = squared[j] * size;
        }
        matrix: [9] Fixed;
        for j: 0..2 {
            matrix[j]     = to_fixed(axes[j].x);
            matrix[3 + j] = to_fixed(axes[j].y);
            matrix[6 + j] = to_fixed(axes[j].z);
        }
        return true, position, matrix;
    }
    none: [9] Fixed;
    return false, .{}, none;
}

show_vue_frame :: (v: *Vue_Logic, f: *Vue_Frame) {
    object := world.objects[v.object];
    object.matrix_set = true;
    object.matrix = f.matrix;
    sector: s32 = -1;
    if v.sector >= 0 && !v.find_sector {
        sector = v.sector;
        wall, in_sector := find_path_wall(v.sector, object.position.x, object.position.z, f.position.x, f.position.z);
        while wall {
            if wall.adjoin < 0 { sector = -1; break; }
            sector = wall.adjoin;
            wall, in_sector = find_next_path_wall(sector);
        }
    } else {
        sector = level_find_sector(*world.level, f.position);
        v.find_sector = false;
    }
    move_object_to_sector(v.object, sector);
    v.sector = sector;
    object.position = f.position;
    object.yaw = 0x1FFF;
}
