// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// A level being played: its geometry and objects with what they draw with on the GPU, the
// player walking in it, and the 3D view through the player's eyes.
//
// world_load loads a level by name (JEDI.LVL's, "SECBASE"); each frame world_update runs the
// game's clock and logic by the time passed and world_draw draws the view into a View;
// world_unload frees it all. The logic and the drawing follow DARK.EXE's: see player.jai,
// collision.jai and draw.jai.
//
// The clock is the original's: a timer at 145.65 Hz whose ticks run some of the game (the
// player's turning and gravity, in its interrupt) and a frame loop (0x10bd6) that runs the
// rest once at least two ticks have passed since the last frame, with the time between them
// as the frame's time, in 16.16 seconds of 145 ticks.

World_Input :: struct {
    forward, back, left, right: bool;   // Move; left and right strafe.
    turn_left, turn_right: bool;
    look_up, look_down, center_view: bool;
    run, walk, jump, crouch, use: bool;
    fire, fire_secondary: bool;
    weapon_keys: [10] bool;             // 1 to 0, held.
    // The Tab map's held keys (automap.jai): = and -, `, and the arrows when it's scrolled.
    map_zoom_in, map_zoom_out, map_scroll: bool;
    map_up, map_down, map_left, map_right: bool;
    revive: bool;                       // The key that brings the player back after dying.
    mouse_x, mouse_y: float;            // Mouse motion since the last update, in counts.
}

// The game's clock (0x1ef6c, 0x10bd6).
World_Clock :: struct {
    tick: s32;                  // Game ticks since the level started.
    frame_tick: s32;            // The tick the last frame started at.
    dt: Fixed;                  // The last frame's time.
    time: float64;              // Real time in ticks, for the fraction of a tick.
}

TIMER_HZ :: 1193182.0 / 8192.0;

DIFFICULTY_EASY   :s32: 0;
DIFFICULTY_MEDIUM :s32: 1;
DIFFICULTY_HARD   :s32: 2;   // The timer's divisor is 0x2000.

// Runs the game's clock on by dt seconds, the ticks that fall in it, and a frame of the
// logic if one is due, the input held throughout. With fixed_step, exactly one frame of two ticks, as on a
// machine fast enough for every frame to take the least the original allows: for runs that
// must come out the same every time.
world_update :: (dt: float, input: World_Input, fixed_step := false) {
    if !world.loaded return;
    clock := *world.clock;
    if fixed_step {
        clock.time = cast(float64) (clock.frame_tick + FRAME_TICKS);
    } else {
        // A long stall counts as the original's longest frame, not as hours of ticks.
        clock.time += min(cast(float64) dt, 0.25) * TIMER_HZ;
    }
    target := cast(s32) clock.time;
    while clock.tick < target {
        clock.tick += 1;
        tick_player(input);
        fade_screen_effects();
        advance_animation_clocks();
        count_fire_delay();
    }
    // One frame per call, once the least time a frame takes has passed: the original's loop
    // waits for it.
    if clock.tick - clock.frame_tick >= FRAME_TICKS  run_frame(input);
    world.time += dt;
}

// The world's logic for one frame: the main loop's part (0x10bd6), the held keys and the
// HUD, and then the lap of the game's tasks back round to it (tasks.jai). The view is drawn
// after it, as the main loop draws first in its turn.
run_frame :: (input: World_Input) {
    clock := *world.clock;
    ticks := clock.tick - clock.frame_tick;
    clock.dt = cast(Fixed) min(((cast(s64) ticks) << 32) / 0x910000, 0x4000);
    clock.frame_tick = clock.tick;
    update_automap(input);
    update_hud();
    world.tasks.input = input;
    run_tasks();
}

FRAME_TICKS :: 2;               // The least a level frame takes (0x10bd6).

World_Draw_Options :: struct {
    original := true;   // The original's 320x200 view; otherwise the view's own size.
    palette: *Palette;  // Shown in place of the level's (the Esc menu's grey, fades).
    light_only: bool;   // Enhanced: lit drawing white, to show the light alone (debug).
}

// The palette the level shows in this frame: its own, with the HUD's colors and the screen's
// tint.
world_get_palette :: () -> Palette {
    palette := world.palette;
    apply_hud_colors(*palette);
    apply_goggles_palette(*palette);
    apply_screen_effects(*palette);
    return palette;
}

world_is_loaded :: () -> bool { return world.loaded; }

world_get_name :: () -> string { return world.name; }

// The game's tick: 145.65 a second since the level started.
world_get_tick :: () -> s32 { return world.clock.tick; }

world_get_level :: () -> *Level { return *world.level; }

// difficulty is the agent's: 0 easy, 1 medium, 2 hard.
world_load :: (name: string, difficulty: s32 = DIFFICULTY_MEDIUM) -> bool {
    world_unload();
    if !fixed_are_tables_loaded() { log_error("No tables from DARK.EXE: levels can't run."); return false; }
    upper := to_upper_copy(name,, temp);

    text, found := gob_find(tprint("%.LEV", upper));
    if !found { log_error("No %.LEV.", upper); return false; }
    level, ok := lev_parse(cast(string) text);
    if !ok { log_error("Couldn't read %.LEV.", upper); return false; }
    world.level = level;
    world.name = copy_string(upper);
    // The O file's DIFF counts from 1 for easy.
    world.object_difficulty = difficulty + 1;

    text, found = gob_find(tprint("%.O", upper));
    if found {
        objects, objects_ok := o_parse(cast(string) text);
        if objects_ok  world.level_objects = objects;
        else log_error("Couldn't read %.O.", upper);
    }

    palette_data, palette_found := gob_find(level.palette);
    if palette_found  world.palette = pal_parse(palette_data);
    cmp_data, cmp_found := gob_find(tprint("%.CMP", upper));
    if !cmp_found  cmp_data, cmp_found = gob_find("SECBASE.CMP");
    if cmp_found  world.colormap = cmp_parse(cmp_data);
    world.gpu_colormap = render_upload_colormap(*world.colormap);
    world.smooth_ramp = smooth_light_ramp(world.colormap.light_ramp);

    load_textures();
    place_objects();
    load_object_art();
    start_player();
    register_player_sounds();
    register_item_sounds();
    set_object_sizes();
    start_level_animations();
    start_update_logics();
    load_vues();
    load_inf();
    load_projectile_assets();
    load_item_art();
    // The stats first: they say which weapon goes in hand.
    start_player_stats();
    load_weapons();
    create_actors();
    load_goals();
    load_hud();
    load_automap();
    build_tasks();
    world.loaded = true;
    return true;
}

world_unload :: () {
    if !world.loaded && !world.name return;
    for * world.textures  release_world_texture(it);
    array_free(world.textures);
    for * world.sprites {
        sprite_free(*it.sprite);
        for * it.images  render_release_image(it);
        array_free(it.images);
    }
    array_free(world.sprites);
    for * world.frames {
        sprite_free(*it.sprite);
        for * it.images  render_release_image(it);
        array_free(it.images);
    }
    array_free(world.frames);
    for * world.models {
        model_free(*it.model);
        for * it.images  render_release_image(it);
        array_free(it.images);
    }
    array_free(world.models);
    free_tasks();
    // Before the actors, which tell their generators as they go.
    unload_generators();
    unload_turrets();
    unload_mousebots();
    unload_welders();
    unload_dark_troopers();
    unload_boba_fetts();
    unload_kell_dragons();
    unload_actors();
    unload_projectiles();
    unload_weapons();
    array_free(world.drawn_objects);
    array_free(world.music_events);
    unload_objects();
    array_free(world.safes);
    unload_hud();
    unload_automap();
    unload_vues();
    unload_inf();
    free_world_sounds();
    render_release_colormap(*world.gpu_colormap);
    render_release_view(*world.view);
    level_objects_free(*world.level_objects);
    level_free(*world.level);
    free(world.name);
    world = .{};
}

// The level's view, for showing; null before the first world_draw.
world_get_view_texture :: () -> *SDL_GPUTexture { return world.view.color; }

// The game's levels in order, from JEDI.LVL; empty when it can't be read.
world_get_level_list :: () -> [] Level_Entry {
    if !level_list.read {
        level_list.read = true;
        text, found := gob_find("JEDI.LVL");
        if found  level_list.entries = lvl_parse(cast(string) text);
    }
    return level_list.entries;
}

#load "objects.jai";
#load "actors.jai";
#load "generators.jai";
#load "turrets.jai";
#load "mousebots.jai";
#load "welders.jai";
#load "dark_troopers.jai";
#load "boba_fett.jai";
#load "kell_dragons.jai";
#load "projectiles.jai";
#load "weapons.jai";
#load "player.jai";
#load "stats.jai";
#load "hud.jai";
#load "sound.jai";
#load "pickups.jai";
#load "inf.jai";
#load "vue.jai";
#load "goals.jai";
#load "collision.jai";
#load "visibility.jai";
#load "automap.jai";
#load "draw.jai";
#load "bot.jai";
#load "tasks.jai";
#load "debug.jai";

#scope_module

World_Texture :: struct {
    frames: [..] Gpu_Image;
    frame_rate: u8;
    transparent: bool;
}

World_Art :: struct {
    sprite: Sprite;
    model:  Model;
    images: [..] Gpu_Image;     // The sprite's cells, or the model's textures.
}

level_list: struct {
    read: bool;
    entries: [..] Level_Entry;
};

world: struct {
    loaded: bool;
    name:   string;
    level:  Level;
    level_objects: Level_Objects;  // The O file.
    palette: Palette;
    colormap: Colormap;
    gpu_colormap: Gpu_Colormap;
    smooth_ramp: [LIGHT_RAMP_COUNT] float;  // The colormap's light ramp smoothed, for Enhanced.
    textures: [..] World_Texture;   // By the level's texture index.
    sprites, frames, models: [..] World_Art;    // By the O file's lists.
    objects: [..] *Object;          // objects.jai
    free_objects: [..] s32;         // Free slots in objects.
    sector_objects: [..] [..] s32;  // Objects by sector, into objects.
    player: Player;
    player_state: Player_State;
    hud:    Hud;
    inf:    Inf_State;
    sounds: [..] World_Sound;
    next_sound: s32;
    sound_objects: [..] Sound_Object;   // sound.jai
    sound_objects_wake: s32;
    level_sounds: [..] Level_Sound;
    level_sounds_wake: s32;
    player_sounds: [Player_Sound.CHOKE + 1] Sound_Handle;
    safes:  [..] Safe;
    clock:  World_Clock;
    collision: Collision;
    view:   View;
    time:   float64;                // Seconds since the level started.
    vues: [..] Vue_Logic;
    object_difficulty: s32;
    goals: Level_Goals;
    mission_complete: bool;
    end_messages: End_Messages;
    objects_collide := true;
    item_sounds: [4] Sound_Handle;
    // What Jabba's ship takes at the start, for the pile (0xfe244): the item slots and ammo.
    pile: struct {
        taken: bool;
        items: [ITEM_SLOTS] s32;
        ammo:  [AMMO_KINDS] s32;
    };

    actors: [..] *World_Actor;            // actors.jai; null for a free slot.
    actor_state: Actor_State;
    actor_sounds: Actor_Sounds;
    anim_clocks: [13] Fixed;        // The animations' clocks by frame rate (0x1ef6c).
    music_events: [..] Music_Event;
    generators: [..] *Generator;    // generators.jai
    free_moves: [..] *Free_Move;    // Movement outside the actors (actors.jai).
    turrets: [..] *Turret;          // turrets.jai; null for a free slot.
    turret_sound: Sound_Handle;
    mousebots: [..] *Mousebot;      // mousebots.jai; null for a free slot.
    mousebot_assets: Mousebot_Assets;
    welders: [..] *Welder;          // welders.jai; null for a free slot.
    welder_assets: Welder_Assets;
    dark_troopers: [..] *Dark_Trooper;  // dark_troopers.jai; null for a free slot.
    dark_trooper_assets: Dark_Trooper_Assets;
    boba_fetts: [..] *Boba_Fett;    // boba_fett.jai; null for a free slot.
    boba_fett_assets: Boba_Fett_Assets;
    kell_dragons: [..] *Kell_Dragon;    // kell_dragons.jai; null for a free slot.
    kell_assets: Kell_Assets;

    projectiles: [..] *Projectile;  // projectiles.jai; null for a free slot.
    projectile_assets: Projectile_Assets;
    projectile_move: Projectile_Move;
    hit_effects: [18] Hit_Effect;
    effect_puffs: s32;              // Plasma and cannon puffs playing (0x4b890).
    item_art: [ITEM_ART.count] s32; // The items' art by kind, into sprites or frames.
    weapon: Weapon_State;           // weapons.jai
    drawn_objects: [..] s32;        // Drawn last frame, for the aiming help.
    explosion_at: Fixed3;           // The explosion being dealt out (0xff0bc),
    explosion_type: s32;            // and its kind (0xff0c8).
    hit_queue: [..] Queued_Hit;     // Hit effects waiting for their task (0xff0b4).
    animations: [..] s32;           // The sprite animations' objects, in the order begun (0xff0cc).
    tasks: Tasks;                   // tasks.jai
};
release_world_texture :: (texture: *World_Texture) {
    for * texture.frames  render_release_image(it);
    array_free(texture.frames);
}

load_bm :: (name: string) -> World_Texture {
    result: World_Texture;
    data, found := gob_find(name);
    if !found  data, found = gob_find("DEFAULT.BM");
    if !found return result;
    texture, ok := bm_parse(data);
    if !ok return result;
    defer texture_free(*texture);
    for texture.frames  array_add(*result.frames, render_upload_image(it));
    result.frame_rate  = texture.frame_rate;
    result.transparent = texture.transparent;
    return result;
}

load_textures :: () {
    for world.level.textures {
        if !it { array_add(*world.textures, .{}); continue; }
        array_add(*world.textures, load_bm(it));
    }
}

load_object_art :: () {
    for world.level_objects.sprites  array_add(*world.sprites, load_art(it, .SPRITE));
    for world.level_objects.frames   array_add(*world.frames, load_art(it, .FRAME));
    for world.level_objects.pods     array_add(*world.models, load_art(it, .MODEL));
}

// A WAX, FME or 3DO with its images on the GPU; empty when it can't be read.
load_art :: (name: string, class: Object_Class) -> World_Art {
    art: World_Art;
    data, found := gob_find(name);
    if class == .MODEL && !found  data, found = gob_find("DEFAULT.3DO");
    if !found return art;
    if class == {
        case .SPRITE;
            sprite, ok := wax_parse(data);
            if !ok return art;
            art.sprite = sprite;
            for sprite.cells  array_add(*art.images, render_upload_image(it));
        case .FRAME;
            sprite, ok := fme_parse(data);
            if !ok return art;
            art.sprite = sprite;
            for sprite.cells  array_add(*art.images, render_upload_image(it));
        case .MODEL;
            model, ok := model_parse(cast(string) data, get_bm_size);
            if !ok return art;
            art.model = model;
            for model.textures {
                image: Gpu_Image;
                if it {
                    bm_data, bm_found := gob_find(it);
                    if bm_found {
                        texture, bm_ok := bm_parse(bm_data);
                        if bm_ok && texture.frames  image = render_upload_image(texture.frames[0]);
                        texture_free(*texture);
                    }
                }
                array_add(*art.images, image);
            }
    }
    return art;
}

get_bm_size :: (name: string) -> s32, s32, bool {
    data, found := gob_find(name);
    if !found return 0, 0, false;
    texture, ok := bm_parse(data);
    defer texture_free(*texture);
    if !ok || !texture.frames return 0, 0, false;
    return texture.frames[0].width, texture.frames[0].height, true;
}

to_upper_copy :: (s: string) -> string {
    result := copy_string(s);
    to_upper_in_place(result);
    return result;
}

#import "Basic";
#import "Math";
#import "String";
#import "engine/vendor/SDL3";
#import "engine/dfArchive";
#import "engine/dfImage";
#import "engine/df3do";
#import "engine/dfLevel";
#import "engine/dfFixed";
#import "engine/dfMessage";
#import "engine/dfRender";
#import "engine/dfVue";

