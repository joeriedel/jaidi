// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The level's objects as the game runs them. The O file's become the first ones when the
// level loads, by the same index; the game adds more as it plays (shots, corpses, dropped
// items) and frees them, their slots then reused. Each is allocated on its own, so a pointer
// to one stays good while others come and go. An object is in at most one sector; one in
// none isn't drawn, collided with or picked up.

Object :: struct {
    class: Object_Class;
    data: s32 = -1;             // Into the level's sprites, frames or models, by its class.
    position: Fixed3;           // Its feet, y down.
    pitch, yaw, roll: s32;      // 16384 to a turn.
    sector: s32 = -1;           // -1 for none.
    width, height: Fixed;       // The room it takes up; no width, none.
    flags: u32;
    entity: u32;                // What it is to the INF's links: ENTITY_ flags.
    lit: bool;                  // Drawn at full light (an enemy firing).
    aimable: bool;              // The aiming help looks for it (an enemy).
    item: s32 = -1;             // A pickup's kind, into ITEMS.
    anim: s32;                  // The WAX action shown,
    frame: s32;                 // and its frame.
    sprite_anim: Sprite_Anim;   // LOGIC: ANIM and effects: action 0 played by itself.
    update: Update_Logic;       // LOGIC: UPDATE.
    matrix_set: bool;           // Turned by this matrix rather than by its angles.
    matrix: [9] Fixed;
    actor: *World_Actor;              // What acts on it, if anything,
    turret: *Turret;                  // or the turret it is,
    mousebot: *Mousebot;              // or the mousebot,
    welder: *Welder;                  // or the welder,
    dark_trooper: *Dark_Trooper;      // or the dark trooper,
    boba_fett: *Boba_Fett;            // or Boba Fett,
    kell_dragon: *Kell_Dragon;        // or a Kell dragon.
    used: bool;                 // False for a free slot.
}

// The sprite animation logic (0x4c00c, its task 0x4c1c8): a frame every delay ticks from
// the first to the last, then again; with a loop count, freed after that many.
Sprite_Anim :: struct {
    on: bool;
    first, last: s32;
    loops: s32;                 // 0 for forever.
    delay: s32;
    next_tick: u32;
    puff: bool;                 // A plasma or cannon puff, counted while it plays.
}

// LOGIC: UPDATE (0x8ac28): an object that spins, falls and rides scrolling floors.
Update_Logic :: struct {
    on: bool;
    velocity: Fixed3;
    pitch_rate, yaw_rate, roll_rate: s16;   // Angle units a second.
    flags: u32 = 0xFFFF_FFFF;   // UPDATE_ bits; with none at all, it rides only along z.
}

UPDATE_GRAVITY :: 0x2;
UPDATE_PITCH   :: 0x8;
UPDATE_YAW     :: 0x10;
UPDATE_ROLL    :: 0x20;

// What an object is, for links' entity masks (the original's object +8).
ENTITY_AI_ACTOR :: 0x1;
ENTITY_GRAVITY  :: 0x2;         // Walks rather than flies.
ENTITY_FLYING   :: 0x4;
ENTITY_PROJECTILE :: 0x8;
ENTITY_SCENERY  :: 0x100;
ENTITY_CORPSE   :: 0x200;
ENTITY_GENERATOR :: 0x400;      // Takes the INF's MASTER_ON and MASTER_OFF.
ENTITY_SMART    :: 0x800;       // Opens doors.
ENTITY_REMOTE   :: 0x1000;      // A training remote: hums as it moves.
ENTITY_LANDMINE :: 0x2000;      // A mine the level placed.
ENTITY_KEPT_CORPSE :: 0x4000;   // A boss's corpse, which generators don't clear away.
ENTITY_MOHC     :: 0x8000;      // General Mohc: his death tells the "mohc" sector.
ENTITY_LANDMINE_WEAPON :: 0x10000;  // A mine thrown.
ENTITY_PLAYER   :: 0x8000_0000;

OBJECT_HIDDEN :u32: 0x4;        // Not drawn (the original's object +0x68 bit 4 clear).
OBJECT_PICKUP :: 0x80;
OBJECT_MOVABLE :: 0x10;         // Carried and turned by moving walls (the original's +0x68 bit 0x10).
OBJECT_STAYS  :: 0x40;          // Not cleared away by an elevator (objectives, codes).
OBJECT_BOSS   :: 0x20;          // BOSS: in the O file: its death tells the "boss" sector.

world_get_objects :: () -> [] *Object { return world.objects; }

// An object put at a place, in the sector holding it; false if none: for tests.
world_place_object :: (index: s32, at: Fixed3) -> bool {
    sector := level_find_sector(*world.level, at);
    if sector < 0 return false;
    world.objects[index].position = at;
    move_object_to_sector(index, sector);
    return true;
}

// A sector's slots, -1 for an empty one: for tests.
world_get_sector_slots :: (sector: s32) -> [] s32 { return world.sector_objects[sector]; }

// The O file's objects, by the same index as theirs in world_get_objects.
world_get_level_objects :: () -> [] Level_Object { return world.level_objects.objects; }

#scope_module

// A new object in a sector (or none, -1), in a free slot if there is one.
add_object :: (class: Object_Class, data: s32, position: Fixed3, sector: s32) -> s32 {
    index: s32;
    if world.free_objects {
        index = pop(*world.free_objects);
    } else {
        index = xx world.objects.count;
        array_add(*world.objects, New(Object));
    }
    o := world.objects[index];
    o.* = .{class = class, data = data, position = position, flags = OBJECT_MOVABLE, used = true};
    move_object_to_sector(index, sector);
    return index;
}

// An object moved into another sector, which its leaving and entering tell (0x59ec4).
change_object_sector :: (index: s32, sector: s32) {
    o := world.objects[index];
    from := o.sector;
    if from == sector return;
    move_object_to_sector(index, sector);
    send_object_sector_events(o.entity, from, sector);
}

free_object :: (index: s32) {
    o := world.objects[index];
    if !o.used return;
    move_object_to_sector(index, -1);
    if o.sprite_anim.on {
        for * world.animations  if it.* == index { it.* = -1; break; }
    }
    o.* = .{};
    array_add(*world.free_objects, index);
}

// A sector's objects are slots, as the original's (0x59ec4): one leaving empties its slot
// (-1); one coming in takes the first empty one, five more slots made when there's none.
move_object_to_sector :: (index: s32, sector: s32) {
    o := world.objects[index];
    if o.sector == sector return;
    if o.sector >= 0 {
        list := *world.sector_objects[o.sector];
        for * list.*  if it.* == index { it.* = -1; break; }
    }
    o.sector = sector;
    if sector < 0 return;
    list := *world.sector_objects[sector];
    for * list.*  if it.* < 0 { it.* = index; return; }
    first := list.count;
    for 1..5  array_add(list, -1);
    list.*[first] = index;
}

count_sector_objects :: (sector: s32) -> s32 {
    count: s32;
    for world.sector_objects[sector]  if it >= 0  count += 1;
    return count;
}

// A sector's objects as the original walks them: the slots in order, as they are at each
// step, the empty ones passed over, until as many objects have been seen as the sector holds.
// Most walks count what it held at the start (0x5add0, 0x5af40): one coming in on the way
// into a slot still ahead is reached and leaves the last out, and one leaving sends the walk
// on to the end of the slots. With live, the count is the sector's as it goes (0x5c3c4,
// 0x5c66c, 0x5c8f8, 0x33a38), which one leaving lowers. Where the original would read on
// past the slots, this stops.
Sector_Walk :: struct { sector: s32; live: bool; }

walk_sector :: (sector: s32, live := false) -> Sector_Walk { return .{sector, live}; }

for_expansion :: (w: Sector_Walk, body: Code, flags: For_Flags) #expand {
    #assert(!(flags & .REVERSE) && !(flags & .POINTER));
    `it_index := -1;
    count := count_sector_objects(w.sector);
    seen, slot := 0, 0;
    while true {
        if w.live  count = count_sector_objects(w.sector);
        if seen >= count break;
        slots := world.sector_objects[w.sector];
        if slot >= slots.count break;
        `it := slots[slot];
        slot += 1;
        if it < 0 continue;
        seen += 1;
        it_index += 1;
        #insert body;
    }
}

// The O file's objects become the level's first ones, by the same index. Objects go in the
// smallest sector holding them; those in none, outside the difficulty, and spirits, sounds,
// safes and the player's start aren't placed, as in the original.
place_objects :: () {
    array_resize(*world.sector_objects, world.level.sectors.count);
    for * l: world.level_objects.objects {
        index := add_object(l.class, l.data, l.position, -1);
        o := world.objects[index];
        o.pitch, o.yaw, o.roll = l.pitch, l.yaw, l.roll;
        // Whatever its value (0x15dd3).
        for l.params  if it.key == "BOSS:"  o.flags |= OBJECT_BOSS;
        if !is_object_in_difficulty(l, world.object_difficulty) continue;
        if l.class == .SPIRIT || l.class == .SOUND || l.class == .SAFE || has_logic(l, "PLAYER") continue;
        move_object_to_sector(index, level_find_sector(*world.level, l.position));
    }
}

// The O file's LOGIC: ANIM sprites, once their art is in.
start_level_animations :: () {
    for * l, index: world.level_objects.objects {
        if world.objects[index].sector >= 0 && has_logic(l, "ANIM")  start_sprite_animation(xx index);
    }
}

// The O file's LOGIC: UPDATE objects (0x8ac28), with the lines after the logic: D_PITCH:,
// D_YAW: and D_ROLL: in degrees a second, FLAGS:. Moving walls don't carry these: they take
// the floor's speed themselves.
start_update_logics :: () {
    for * l, index: world.level_objects.objects {
        o := world.objects[index];
        if o.sector < 0 continue;
        logic := -1;
        for l.logics  if it == "UPDATE"  logic = it_index;
        if logic < 0 continue;
        u := *o.update;
        u.* = .{on = true};
        for l.params {
            if it.logic != logic continue;
            // Truncated into 16 bits, as the original's float reads are.
            degrees := string_to_float64(it.value);
            rate := cast,no_check(s16) cast,no_check(s32) (degrees * 45.5111);
            if it.key == {
                case "D_PITCH:";  u.pitch_rate = rate;
                case "D_YAW:";    u.yaw_rate = rate;
                case "D_ROLL:";   u.roll_rate = rate;
                case "FLAGS:";    u.flags = cast,no_check(u32) read_seq_int(it.value);
            }
        }
        o.flags &= ~cast(u32) OBJECT_MOVABLE;
    }
}

// The number at the start of a word, as the original reads one (0x8eae0): spaces, a sign,
// digits, and anything after them ignored.
read_seq_int :: (s: string) -> s32 {
    i := 0;
    while i < s.count && (s[i] == #char " " || s[i] == #char "\t")  i += 1;
    negative := false;
    if i < s.count && (s[i] == #char "+" || s[i] == #char "-") { negative = s[i] == #char "-"; i += 1; }
    value: s32;
    while i < s.count && s[i] >= #char "0" && s[i] <= #char "9" {
        value = value * 10 + cast(s32) (s[i] - #char "0");
        i += 1;
    }
    return ifx negative then -value else value;
}

// Every frame (0x8ae8c). On a floor that moves sideways it goes at the floor's speed, which
// stops when the floor does, then slows by friction off it; it falls to the floor it had at
// the start of the frame, with no ceiling; it spins by its rates.
update_update_logics :: () {
    dt := world.clock.dt;
    for o, index: world.objects {
        u := *o.update;
        if !u.on || o.sector < 0 continue;
        floor := get_floor_and_ceiling(*world.level.sectors[o.sector], o.position.y);
        e := get_floor_elevator(o);
        if e {
            v := get_elevator_velocity(e);
            u.velocity.x, u.velocity.z = v.x, v.z;
        }
        if u.velocity.x || u.velocity.z {
            dx := mul16(dt, u.velocity.x);
            dz := mul16(dt, u.velocity.z);
            if !u.flags  dx = 0;
            sector := find_move_sector(o.sector, o.position.x, o.position.z, o.position.x + dx, o.position.z + dz);
            if sector >= 0 {
                o.position.x += dx;
                o.position.z += dz;
                change_object_sector(xx index, sector);
            }
        }
        if u.flags & UPDATE_GRAVITY {
            u.velocity.y += mul16(dt, 150 * FIXED_ONE);
            o.position.y += mul16(dt, u.velocity.y);
            if o.position.y > floor {
                u.velocity.y = 0;
                o.position.y = floor;
            }
        }
        if u.velocity.x || u.velocity.z {
            friction := FIXED_ONE - 2 * dt;
            u.velocity.x = mul16(u.velocity.x, friction);
            u.velocity.z = mul16(u.velocity.z, friction);
        }
        if u.pitch_rate && (u.flags & UPDATE_PITCH)  o.pitch = (o.pitch + cast,no_check(s16) mul16(u.pitch_rate, dt)) & ANGLE_MASK;
        if u.yaw_rate && (u.flags & UPDATE_YAW)      o.yaw = (o.yaw + cast,no_check(s16) mul16(u.yaw_rate, dt)) & ANGLE_MASK;
        if u.roll_rate && (u.flags & UPDATE_ROLL)    o.roll = (o.roll + cast,no_check(s16) mul16(u.roll_rate, dt)) & ANGLE_MASK;
    }
}

// Starts the sprite animation logic on a sprite (0x4c00c): action 0 from its first frame,
// a frame every 145.65 / rate ticks, truncated.
start_sprite_animation :: (index: s32, loops: s32 = 0) {
    o := world.objects[index];
    wax := get_object_sprite(o);
    if !wax || !wax.actions return;
    action := *wax.actions[0];
    a := *o.sprite_anim;
    // Into the task's list at its end (0x4c00c), the task made with the first.
    need_sprite_animation_task();
    if !a.on  array_add(*world.animations, index);
    a.on = true;
    a.first = 0;
    a.last = (ifx action.views then cast(s32) action.views[0].frames.count else 0) - 1;
    a.loops = loops;
    a.delay = ifx action.frame_rate > 0 then cast(s32) (145.65 / action.frame_rate) else 0x7FFF_FFFF;
    a.next_tick = cast(u32) world.clock.tick + cast(u32) a.delay;
    o.anim = 0;
    o.frame = 0;
}

// Every frame (0x4c1c8), in the order begun: at most a frame each.
update_sprite_animations :: () {
    tick := cast(u32) world.clock.tick;
    remove_animations_ended();
    for i: 0..world.animations.count-1 {
        index := world.animations[i];
        if index < 0 continue;
        o := world.objects[index];
        a := *o.sprite_anim;
        if !a.on || a.next_tick >= tick continue;
        o.frame += 1;
        a.next_tick += cast(u32) a.delay;
        if cast(u32) o.frame <= cast(u32) a.last continue;
        a.loops -= 1;
        if a.loops == 0 {
            if a.puff  world.effect_puffs -= 1;
            free_object(index);
        }
        else             o.frame = a.first;
    }
}

remove_animations_ended :: () {
    n := 0;
    for world.animations  if it >= 0 { world.animations[n] = it; n += 1; }
    world.animations.count = n;
}

// The art an object shows as a sprite or frame.
get_object_sprite :: (o: *Object) -> *Sprite {
    if o.class == .SPRITE && o.data >= 0 && o.data < world.sprites.count return *world.sprites[o.data].sprite;
    if o.class == .FRAME && o.data >= 0 && o.data < world.frames.count return *world.frames[o.data].sprite;
    return null;
}

// Art the game needs that the O file may not list (shots, effects, items), loaded once, as
// the level loads.
find_or_load_sprite :: (name: string) -> s32 { return find_or_load_art(*world.level_objects.sprites, *world.sprites, name, .SPRITE); }
find_or_load_frame  :: (name: string) -> s32 { return find_or_load_art(*world.level_objects.frames, *world.frames, name, .FRAME); }
find_or_load_model  :: (name: string) -> s32 { return find_or_load_art(*world.level_objects.pods, *world.models, name, .MODEL); }

unload_objects :: () {
    for * world.sector_objects  array_free(it.*);
    array_free(world.sector_objects);
    for world.objects  free(it);
    array_free(world.objects);
    array_free(world.free_objects);
    array_free(world.animations);
}

// The room an object takes up (0x8a31c, 0x8a3dc): a sprite or frame half its first cell's
// width across and its height up, in tenths of a unit (a sprite's scaled by its world
// size), unless radius or height is given (not -1); 3D objects and spirits none.
set_object_size :: (o: *Object, radius: Fixed = -1, height: Fixed = -1) {
    width := radius;
    if o.class == {
        case .SPRITE;
            art := ifx o.data >= 0 && o.data < world.sprites.count then *world.sprites[o.data] else null;
            cell, scale_x, scale_y := get_first_cell(art);
            if width == -1   width = ifx cell then div16(mul16(scale_x, (cell.width / 2) << 16), 10 * FIXED_ONE) else 0;
            if height == -1  height = ifx cell then div16(mul16(scale_y, cell.height << 16), 10 * FIXED_ONE) else 0;
        case .FRAME;
            art := ifx o.data >= 0 && o.data < world.frames.count then *world.frames[o.data] else null;
            cell := get_first_cell(art);
            if width == -1   width = ifx cell then div16((cell.width / 2) << 16, 10 * FIXED_ONE) else 0;
            if height == -1  height = ifx cell then div16(cell.height << 16, 10 * FIXED_ONE) else 0;
        case;
            if width == -1   width = 0;
            if height == -1  height = 0;
    }
    o.width, o.height = width, height;
}

#scope_file

find_or_load_art :: (names: *[..] string, arts: *[..] World_Art, name: string, class: Object_Class) -> s32 {
    for names.*  if equal_nocase(it, name) return xx it_index;
    array_add(names, copy_string(name));
    array_add(arts, load_art(name, class));
    return xx (arts.count - 1);
}

get_first_cell :: (art: *World_Art) -> *Gpu_Image, Fixed, Fixed {
    if !art || !art.sprite.actions return null, 0, 0;
    action := *art.sprite.actions[0];
    if !action.views || !action.views[0].frames return null, 0, 0;
    frame := *action.views[0].frames[0];
    if frame.cell < 0 || frame.cell >= art.images.count return null, 0, 0;
    return *art.images[frame.cell], action.world_width, action.world_height;
}
