// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The game's sounds, as DARK.EXE plays them through iMUSE's digital side (0x23171-0x23f9a).
//
// A sound is registered by its VOC's name with a priority, once (registering it again shares
// it), and loaded from the GOBs the first time it plays. Each play is a new instance of it
// in group 1 (sound effects). A sound at a place is heard by the camera: full volume within 30
// units (counting height and the quick distance across), fading to nothing at 150, panned by
// its direction from the camera's facing in 32 steps. A looping sound is kept going while it
// can be heard and stopped when it can't.

Sound_Handle :: s32;            // A registered sound; 0 for none.

// The O file's sounds kept going (0x153d7): their places, sounds' names and whether each is
// playing now. For tests.
world_get_sound_objects :: () -> [..] World_Sound_Object {
    result: [..] World_Sound_Object;
    result.allocator = temp;
    for world.sound_objects {
        name := ifx it.handle > 0 then world.sounds[it.handle - 1].name else "";
        array_add(*result, .{it.at, name, it.playing != 0});
    }
    return result;
}

World_Sound_Object :: struct {
    at: Fixed3;
    name: string;
    playing: bool;
}
Sound_Instance :: Imuse_Song;   // A sound playing; 0 for none.

// Registers a VOC by name (0x23171).
register_sound :: (name: string, priority: s32) -> Sound_Handle {
    upper := to_upper_copy(name,, temp);
    for world.sounds  if it.name == upper return xx (it_index + 1);
    sound := array_add(*world.sounds);
    sound.name = copy_string(upper);
    sound.priority = priority;
    sound.volume = 127;
    return xx world.sounds.count;
}

// A registered sound's own volume (0x236a1).
set_sound_level :: (handle: Sound_Handle, volume: s32) {
    if handle <= 0 || handle > world.sounds.count return;
    world.sounds[handle - 1].volume = volume;
}

// Plays a sound at its own volume, centered (0x23475).
play_sound :: (handle: Sound_Handle) -> Sound_Instance {
    if handle <= 0 || handle > world.sounds.count return 0;
    sound := *world.sounds[handle - 1];
    if !sound.data {
        data, found := gob_find(sound.name);
        if !found return 0;
        sound.data = data;
    }
    world.next_sound += 1;
    id := SOUND_IDS + (world.next_sound & 0xFFFFFF);
    audio_lock();
    defer audio_unlock();
    if !imuse_start_digital(id, sound.data, sound.priority) return 0;
    imuse_set_param(id, .GROUP, 1);
    imuse_set_param(id, .VOLUME, sound.volume & 0x7F);
    return id;
}

// Plays a sound at a place (0x23742).
play_sound_at :: (handle: Sound_Handle, at: Fixed3) -> Sound_Instance {
    if handle <= 0 return 0;
    volume, pan := get_sound_volume_and_pan(handle, at);
    id := play_sound(handle);
    set_sound_volume_and_pan(id, volume, pan);
    return id;
}

// A playing sound heard from a place, once (0x237ba).
place_sound :: (id: Sound_Instance, handle: Sound_Handle, at: Fixed3) {
    if handle <= 0 return;
    volume, pan := get_sound_volume_and_pan(handle, at);
    set_sound_volume_and_pan(id, volume, pan);
}

stop_sound :: (id: Sound_Instance) {
    if !id return;
    audio_lock();
    defer audio_unlock();
    imuse_stop_digital(id);
}

// Keeps a looping sound at a place going (0x23817): silent where it can't be heard, started
// again when it has ended (checked every 16 ticks), its volume and pan kept up with the
// camera. Returns the instance to keep.
maintain_sound :: (id: Sound_Instance, handle: Sound_Handle, at: Fixed3) -> Sound_Instance {
    if handle <= 0 return 0;
    volume, pan := get_sound_volume_and_pan(handle, at);
    last_maintained_volume = volume;
    if volume == 0 {
        stop_sound(id);
        return 0;
    }
    if id && (world.clock.tick & 0xF) == 0 {
        audio_lock();
        playing := imuse_is_digital_playing(id);
        audio_unlock();
        if !playing  id = 0;
    }
    if !id  id = play_sound(handle);
    set_sound_volume_and_pan(id, volume, pan);
    return id;
}

// A playing sound's pan, -64 to 63 from the middle (0x2370b).
set_sound_pan :: (id: Sound_Instance, pan: s32) {
    if !id return;
    audio_lock();
    defer audio_unlock();
    imuse_set_param(id, .PAN, (pan + 64) & 0x7F);
}

#scope_module

// The volume maintain_sound last gave its sound (0xfbb98).
last_maintained_volume: s32;

// A playing sound's volume, 0 to 127 (0x236d7).
set_sound_volume :: (id: Sound_Instance, volume: s32) {
    if !id return;
    audio_lock();
    defer audio_unlock();
    imuse_set_param(id, .VOLUME, volume & 0x7F);
}

World_Sound :: struct {
    name: string;
    data: [] u8;
    priority: s32;
    volume: s32;
}

// The level's sounds stopped and let go: the original's cleanup stops them all (0x23630).
free_world_sounds :: () {
    audio_lock();
    imuse_stop_all_digital();
    audio_unlock();
    for world.sounds  free(it.name);
    array_free(world.sounds);
    array_free(world.sound_objects);
    array_free(world.level_sounds);
}

// The O file's sounds (0x153d7): each SOUND object becomes a sound kept going at its place,
// the object itself gone. Its sound is from the O file's list, registered at priority 8.
add_sound_object :: (l: *Level_Object) {
    handle: Sound_Handle;
    if l.data >= 0 && l.data < world.level_objects.sounds.count  handle = register_sound(world.level_objects.sounds[l.data], 8);
    array_add(*world.sound_objects, .{handle = handle, at = l.position});
}

Sound_Object :: struct {
    handle: Sound_Handle;
    playing: Sound_Instance;
    at: Fixed3;
}

// Their task (0x154f8): each kept going, heard from the camera, every 72 ticks.
update_sound_objects :: () {
    if world.clock.tick < world.sound_objects_wake return;
    for * world.sound_objects  it.playing = maintain_sound(it.playing, it.handle, it.at);
    world.sound_objects_wake = world.clock.tick + 0x48;
}

// The INF's amb_sound (0x1533d): played every so many ticks, counted down by random steps,
// its first time a random part of the way in (the time halved while the seed's low two bits
// aren't 0). Priority 0 is 8.
add_level_sound :: (line: Level_Sound_Line) {
    period := cast(s32) floor(line.seconds * 145.65 + 0.5);
    start := period;
    while fixed_random_next() & 3  start >>= 1;
    handle := register_sound(line.name, ifx line.priority then line.priority else 8);
    array_add(*world.level_sounds, .{handle = handle, period = period, countdown = period - start});
}

Level_Sound :: struct {
    handle: Sound_Handle;
    period: s32;
    countdown: s32;
}

// Their task (0x15457): each one's countdown less 81 to 208 at random, played centered when
// it runs out, and the task again in 81 to 208 ticks, by the last one's draw.
update_level_sounds :: () {
    if world.clock.tick < world.level_sounds_wake return;
    delay: s32;
    for * world.level_sounds {
        delay = cast(s32) (fixed_random_next() & 0x7F) - 0x40;
        it.countdown -= delay + 0x91;
        if it.countdown < 0 {
            play_sound(it.handle);
            it.countdown = it.period;
        }
    }
    world.level_sounds_wake = world.clock.tick + delay + 0x91;
}

#scope_file

SOUND_IDS :: IMUSE_DIGITAL_FIRST + 0x1000000;

// How the camera hears a sound at a place (0x23f9a).
get_sound_volume_and_pan :: (handle: Sound_Handle, at: Fixed3) -> s32, s32 {
    sound := *world.sounds[handle - 1];
    p := *world.player;
    eye := Fixed3.{p.position.x, p.position.y + p.bob - p.height, p.position.z};
    distance := eye.y - at.y;
    if distance < 0  distance = -distance;
    distance += dist_approx(at.x, at.z, eye.x, eye.z);
    volume: s32;
    if distance < 150 * FIXED_ONE {
        if distance < 30 * FIXED_ONE {
            volume = sound.volume;
        } else {
            fraction := div16(150 * FIXED_ONE - distance, 120 * FIXED_ONE);
            volume = min(mul16(fraction, sound.volume << 16) >> 16, 127);
        }
    }
    angle := vec2_to_angle(at.x - eye.x, at.z - eye.z);
    turn := get_angle_difference(p.object_yaw, angle);
    pan := PAN_TABLE[((turn + 0x2000) / 512) & 31];
    return volume, pan;
}

set_sound_volume_and_pan :: (id: Sound_Instance, volume: s32, pan: s32) {
    if !id return;
    audio_lock();
    defer audio_unlock();
    imuse_set_param(id, .VOLUME, volume & 0x7F);
    imuse_set_param(id, .PAN, (pan + 64) & 0x7F);
}

PAN_TABLE :: s32.[0, -6, -12, -18, -24, -30, -36, -42, -48, -42, -36, -30, -24, -18, -12, -6,
                  0, 6, 12, 18, 24, 30, 36, 42, 48, 42, 36, 30, 24, 18, 12, 6];

#import "engine/dfIMuse";
#import "engine/dfAudio";
