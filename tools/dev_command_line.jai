// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev builds take a few options for getting straight to a tool and for checking the UI
// without a person at the screen:
//
//   --tool archive|music|fm|cutscene    start in that tool (cutscene: with --scene, playing it)
//   --open NAME                open the named file's viewer in the archive browser
//   --filter TEXT              filter the archive browser
//   --screenshot FILE.png      after a few frames, save the window to FILE and quit; frames run
//                              unsynced to the display and cutscenes on a clock of 1/60 s per
//                              frame, so frame N is N/60 s in, reached as fast as possible
//   --screenshot-frame N       which frame --screenshot saves (default 30)
//   --dump-frames DIR          like --screenshot, but saves --dump-count frames from
//                              --screenshot-frame on, as DIR/frame_NNNNN.png, then quits
//   --dump-count K             how many frames --dump-frames saves (default 1)
//   --click-frame N            on frame N, a left click on the cutscene (the next scene), as
//                              if from the mouse: with --dump-frames, to watch a skip
//   --play                     start the opening cutscene, as Play does
//   --scene N                  start the cutscene chain at scene N (CUTSCENE.LST's ids)
//   --film-filter N            Enhanced cutscene art's filter: 0 EASU, 1 Catmull-Rom (the
//                              default), 2 bilinear, 3 nearest, 4 the pixel-art edge filter
//   --film-sharpen             sharpen Enhanced cutscenes' output (FSR 1's RCAS)
//   --enhanced                 start in Enhanced Mode (the default): cutscenes through the GPU
//                              presenter, levels at the window's resolution
//   --original                 start with Enhanced Mode off: the exact 4:3 cutscenes, levels
//                              at 320x200
//   --cutscene-diff            play the opening comparing the GPU presenter with the CPU, then quit
//   --diff-frames N            stop --cutscene-diff after N frames (with --scene, a quick check)
//   --level NAME               play the level (JEDI.LVL's name, e.g. SECBASE) from its start
//   --hide-status              leave out the level's status line (for screenshots and footage)
//   --level-turn DEGREES       turn the player by that much at the start, clockwise
//   --level-pitch DEGREES      look up (or down, negative) that much at the start
//   --level-walk FRAMES        walk forward for that many frames (with --level-run, running)
//   --level-headlight          switch the headlamp on at the start
//   --level-goggles            give the goggles and put them on at the start
//   --level-mask               give the gas mask and put it on at the start
//   --level-yaw DEGREES        face that way at the start (0 is +z, clockwise from above)
//   --level-use FRAME          press use on that frame
//   --level-fire FRAME         press fire on that frame (--level-fire-secondary: the secondary)
//   --level-weapon N           start holding weapon N (0 fists to 9 assault cannon), given
//                              with ammo if the agent has none
//   --level-turn-frame FRAME   turn (--level-turn) on that frame rather than the first
//   --level-walk-after FRAME   start walking (--level-walk) on that frame
//   --level-strafe FRAMES      strafe right for that many frames
//   --level-at X,Y,Z           start there instead (feet on the floor of the sector holding it)
//   --level-bot                let the bot play: it fights what it sees, else goes to the
//                              nearest enemy (for footage; see dfWorld/bot.jai)
//   --level-god                the player can't be hurt (the cheat's invincibility)
//   --level-input FROM:TO:KEYS hold the level's keys from frame FROM up to TO, joined by +:
//                              forward, back, left, right (strafe), turn_left, turn_right,
//                              look_up, look_down, run, walk, jump, crouch, use, fire,
//                              fire_secondary; may be given more than once
//   --key FRAME:NAME           press the key (SDL's name: Return, Escape, Y) on that frame of
//                              a --screenshot run, as if typed; may be given more than once
// (--cutscene-diff runs unsynced to the display, a fixed 1/60 s a frame; see cutscene_runs.jai.)

// Returns true when the app should start in the tools screen.
parse_dev_command_line :: () -> bool {
    args := get_command_line_arguments();
    i := 1;
    while i < args.count {
        arg := args[i];
        value := ifx i + 1 < args.count then args[i + 1] else "";
        if arg == {
            case "--tool";       dev_options.tool = value; i += 1;
            case "--open";       dev_options.open = value; i += 1;
            case "--screenshot"; dev_options.screenshot = value; i += 1;
            case "--screenshot-frame"; dev_options.screenshot_frame = string_to_int(value); i += 1;
            case "--dump-frames"; dev_options.dump_dir = value; dev_options.screenshot = value; i += 1;
            case "--dump-count";  dev_options.dump_count = max(string_to_int(value), 1); i += 1;
            case "--click-frame"; dev_options.click_frame = string_to_int(value); i += 1;
            case "--play";       dev_options.play = true;
            case "--scene";      dev_options.scene = xx string_to_int(value); dev_options.play = true; i += 1;
            case "--enhanced";   dev_options.enhanced = true;
            case "--original";   dev_options.original = true;
            case "--film-filter"; film_filter = xx string_to_int(value); i += 1;
            case "--film-sharpen"; film_sharpen = true;
            case "--cutscene-diff"; start_cutscene_diff(); dev_options.play = true;
            case "--diff-frames";   set_cutscene_diff_frames(string_to_int(value)); i += 1;
            case "--filter";     set_archive_browser_filter(value); i += 1;
            case "--reload-thumbnails"; set_archive_browser_reload(true);
            case "--level";      dev_options.level = value; i += 1;
            case "--level-turn"; dev_options.level_turn = string_to_float(value); i += 1;
            case "--level-pitch"; dev_options.level_pitch = string_to_float(value); i += 1;
            case "--level-walk"; dev_options.level_walk = string_to_int(value); i += 1;
            case "--level-strafe"; dev_options.level_strafe = string_to_int(value); i += 1;
            case "--level-run";  dev_options.level_run = true;
            case "--hide-status"; dev_options.hide_status = true;
            case "--level-headlight";  dev_options.level_headlight = true;
            case "--level-goggles";    dev_options.level_goggles = true;
            case "--level-mask";       dev_options.level_mask = true;
            case "--level-yaw";  dev_options.level_yaw = string_to_float(value); dev_options.level_yawed = true; i += 1;
            case "--level-use";  dev_options.level_use = string_to_int(value); i += 1;
            case "--level-fire"; dev_options.level_fire = string_to_int(value); i += 1;
            case "--level-fire-secondary"; dev_options.level_fire_secondary = string_to_int(value); i += 1;
            case "--level-weapon"; dev_options.level_weapon = string_to_int(value); i += 1;
            case "--level-launch";
                found, frame, type := split_from_left(value, #char ":");
                if found {
                    dev_options.level_launch = string_to_int(frame);
                    dev_options.level_launch_type = string_to_int(type);
                } else {
                    print("--level-launch wants FRAME:TYPE, not '%'.\n", value);
                }
                i += 1;
            case "--level-turn-frame";  dev_options.level_turn_frame = string_to_int(value); i += 1;
            case "--level-walk-after";  dev_options.level_walk_after = string_to_int(value); i += 1;
            case "--level-at";
                parts := split(value, ",",, temp);
                if parts.count == 3  dev_options.level_at = .{string_to_float(parts[0]), string_to_float(parts[1]), string_to_float(parts[2])};
                dev_options.level_placed = parts.count == 3;
                i += 1;
            case "--level-bot";  dev_options.level_bot = true;
            case "--level-god";  dev_options.level_god = true;
            case "--level-input";
                if !add_dev_level_input(value)  print("--level-input wants FROM:TO:KEYS, not '%'.\n", value);
                i += 1;
            case "--key";
                found, frame, name := split_from_left(value, #char ":");
                if found {
                    k := array_add(*dev_options.keys);
                    k.frame = string_to_int(frame);
                    k.key = SDL_GetKeyFromName(temp_c_string(name));
                    k.name = sprint("%\0", name);
                    k.name.count -= 1;
                }
                if !found  print("--key wants FRAME:NAME, not '%'.\n", value);
                i += 1;
            case "--x11";        // Read by main before SDL starts.
            case; print("Unknown option '%'.\n", arg);
        }
        i += 1;
    }
    if dev_options.screenshot {
        // Every window in the main one, where the capture can see it, and the user's saved
        // layout neither used nor overwritten.
        io := ImGui.GetIO();
        io.IniFilename = null;
        io.ConfigFlags &= ~ImGuiConfigFlags.ViewportsEnable;
    }
    if dev_options.open && !dev_options.tool  dev_options.tool = "archive";
    if !dev_options.tool return false;
    if !open_tool(dev_options.tool)  print("No tool '%'.\n", dev_options.tool);
    if dev_options.tool == "cutscene" && dev_options.play {
        request_tool_cutscene(get_requested_scene());
        dev_options.play = false;
    }
    if dev_options.open  open_in_archive_browser(dev_options.open);
    return true;
}

// --level: the level to start in, or nothing.
get_requested_level :: () -> string {
    return dev_options.level;
}

// The --level-* options, as input: the turn on the first frame, then walking.
apply_dev_level_input :: (input: *World_Input) {
    d := *dev_options;
    if !d.level return;
    if d.level_frame == d.level_turn_frame {
        // Mouse counts of 8 angle units, 16384 to a turn.
        input.mouse_x += d.level_turn / 360.0 * 16384 / 8;
    }
    if !d.level_frame {
        player := world_get_player();
        player.pitch = cast(s32) (d.level_pitch / 360.0 * 16384);
        if d.level_placed && !world_place_player(d.level_at)  print("No sector holds %.\n", d.level_at);
        if d.level_headlight  world_toggle_headlight();
        if d.level_goggles { world_get_agent().items[Item_Slot.GOGGLES] = -1; world_toggle_goggles(); }
        if d.level_mask    { world_get_agent().items[Item_Slot.MASK] = -1; world_toggle_mask(); }
        if d.level_weapon >= 0  world_give_weapon(xx d.level_weapon);
        if d.level_god  world_get_player_state().invincible = -2;
        if d.level_bot  world_reset_bot();
        if d.level_yawed {
            player.yaw = (cast(s32) (d.level_yaw / 360.0 * 16384)) & 0x3FFF;
            player.object_yaw = player.yaw;
        }
    }
    if d.level_frame >= d.level_walk_after && d.level_frame < d.level_walk_after + d.level_walk  input.forward = true;
    if d.level_frame < d.level_strafe  input.right = true;
    if d.level_run  input.run = true;
    if d.level_frame == d.level_use  input.use = true;
    if d.level_bot  world_get_bot_input(input);
    for d.level_inputs {
        if d.level_frame < it.from || d.level_frame >= it.to continue;
        k := *it.keys;
        input.forward |= k.forward;          input.back |= k.back;
        input.left |= k.left;                input.right |= k.right;
        input.turn_left |= k.turn_left;      input.turn_right |= k.turn_right;
        input.look_up |= k.look_up;          input.look_down |= k.look_down;
        input.run |= k.run;                  input.walk |= k.walk;
        input.jump |= k.jump;                input.crouch |= k.crouch;
        input.use |= k.use;
        input.fire |= k.fire;                input.fire_secondary |= k.fire_secondary;
    }
    if d.level_frame == d.level_fire  input.fire = true;
    if d.level_frame == d.level_fire_secondary  input.fire_secondary = true;
    if d.level_frame == d.level_launch {
        // From the eye, two units out along the view.
        p := world_get_player();
        s, c := sin_cos(p.yaw);
        at := Fixed3.{p.position.x + 2 * s, p.position.y - p.height, p.position.z + 2 * c};
        type := cast(Projectile_Type) d.level_launch_type;
        if world_launch_projectile(type, at, p.pitch, p.yaw) < 0  print("No sector to launch % in.\n", type);
    }
    d.level_frame += 1;
}

// --play: start in the opening cutscene.
is_play_requested :: () -> bool {
    return dev_options.play;
}

// The scene --play starts at.
get_requested_scene :: () -> s32 {
    return ifx dev_options.scene then dev_options.scene else CUTSCENE_OPENING;
}

// Under --cutscene-diff or --screenshot, the cutscene clock runs a fixed step per frame.
is_fixed_clock :: () -> bool {
    return is_fixed_cutscene_run() || dev_options.screenshot != "";
}

// Under --screenshot, the time by frames rather than the clock.
get_screenshot_clock :: () -> u64, bool {
    if !dev_options.screenshot return 0, false;
    return cast(u64) (dev_options.frame * 1_000_000_000 / 60), true;
}

// --click-frame: once a frame, before the cutscene is updated.
send_dev_clicks :: () {
    if dev_options.click_frame >= 0 && dev_options.frame == dev_options.click_frame && cutscene_is_playing()  cutscene_next();
    // Keys as events, handled next frame like typed ones: a character as text, others as
    // keys.
    for * dev_options.keys {
        if it.frame != dev_options.frame || it.sent_frame == dev_options.frame continue;
        it.sent_frame = dev_options.frame;
        event: SDL_Event;
        if it.name.count == 1 {
            event.text.type = .TEXT_INPUT;
            event.text.text = it.name.data;
        } else {
            event.key.type = .KEY_DOWN;
            event.key.key = it.key;
            event.key.down = true;
        }
        SDL_PushEvent(*event);
    }
}

is_enhanced_requested :: () -> bool { return dev_options.enhanced; }
is_original_requested :: () -> bool { return dev_options.original; }
is_status_hidden :: () -> bool { return dev_options.hide_status; }

// Automated runs (screenshots, dumps, the diff) take no input from the real keyboard and
// mouse, so whoever is at the machine can't change what they capture. The --key presses are
// pushed with no window, which tells them apart.
is_input_ignored :: () -> bool { return is_fixed_clock(); }

// The same runs, asked before SDL starts and the options are read.
is_automated_run_requested :: () -> bool {
    for get_command_line_arguments()  if it == "--screenshot" || it == "--dump-frames" || it == "--cutscene-diff"  return true;
    return false;
}

is_device_input :: (event: *SDL_Event) -> bool {
    if cast(SDL_EventType) event.type == {
        case .KEY_DOWN; #through;
        case .KEY_UP;        return event.key.windowID != 0;
        case .TEXT_INPUT;    return event.text.windowID != 0;
        case .TEXT_EDITING;  return event.edit.windowID != 0;
        case .MOUSE_MOTION; #through;
        case .MOUSE_BUTTON_DOWN; #through;
        case .MOUSE_BUTTON_UP; #through;
        case .MOUSE_WHEEL;   return true;
    }
    return false;
}

// Called with the frame's command buffer once the window is drawn: when it is time, draws the
// same UI into a texture of its own and queues it to be read back.
capture_dev_screenshot :: (device: *SDL_GPUDevice, command_buffer: *SDL_GPUCommandBuffer, draw_data: *ImDrawData, format: SDL_GPUTextureFormat) {
    if !dev_options.screenshot return;
    dev_options.frame += 1;
    if dev_options.frame < dev_options.screenshot_frame || dev_options.frame >= dev_options.screenshot_frame + dev_options.dump_count return;

    width  := cast(u32) (draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
    height := cast(u32) (draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
    info: SDL_GPUTextureCreateInfo;
    info.type = ._2D;
    info.format = format;
    info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = width;
    info.height = height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    texture := SDL_CreateGPUTexture(device, *info);
    defer SDL_ReleaseGPUTexture(device, texture);

    target: SDL_GPUColorTargetInfo;
    target.texture = texture;
    target.clear_color = .{0, 0, 0, 1};
    target.load_op = .CLEAR;
    target.store_op = .STORE;
    pass := SDL_BeginGPURenderPass(command_buffer, *target, 1, null);
    im_render(draw_data, command_buffer, pass);
    SDL_EndGPURenderPass(pass);

    transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .DOWNLOAD, size = width * height * 4};
    dev_options.transfer = SDL_CreateGPUTransferBuffer(device, *transfer_info);
    dev_options.width, dev_options.height = width, height;
    dev_options.bgra = format == .B8G8R8A8_UNORM || format == .B8G8R8A8_UNORM_SRGB;
    copy := SDL_BeginGPUCopyPass(command_buffer);
    region := SDL_GPUTextureRegion.{texture = texture, w = width, h = height, d = 1};
    destination := SDL_GPUTextureTransferInfo.{transfer_buffer = dev_options.transfer};
    SDL_DownloadFromGPUTexture(copy, *region, *destination);
    SDL_EndGPUCopyPass(copy);
}

// After the frame is submitted: writes a queued screenshot. Returns true when the app should quit:
// after the last frame to save.
finish_dev_screenshot :: (device: *SDL_GPUDevice) -> bool {
    if !dev_options.transfer return false;
    SDL_WaitForGPUIdle(device);
    pixels := cast(*u8) SDL_MapGPUTransferBuffer(device, dev_options.transfer, false);
    count := dev_options.width * dev_options.height;
    for 0..count-1 {
        p := pixels + it * 4;
        if dev_options.bgra  p[0], p[2] = p[2], p[0];
        p[3] = 255;
    }
    path := dev_options.screenshot;
    if dev_options.dump_dir {
        make_directory_if_it_does_not_exist(dev_options.dump_dir, recursive = true);
        path = tprint("%/frame_%.png", dev_options.dump_dir, formatInt(dev_options.frame, minimum_digits = 5));
    }
    ok := stbi_write_png(temp_c_string(path), xx dev_options.width, xx dev_options.height, 4, pixels, xx (dev_options.width * 4));
    SDL_UnmapGPUTransferBuffer(device, dev_options.transfer);
    SDL_ReleaseGPUTransferBuffer(device, dev_options.transfer);
    dev_options.transfer = null;
    if !ok  print("Couldn't write %\n", path);
    last := dev_options.frame >= dev_options.screenshot_frame + dev_options.dump_count - 1;
    if ok && (last || !dev_options.dump_dir)  print("Saved %\n", ifx dev_options.dump_dir then tprint("% frames in %", dev_options.dump_count, dev_options.dump_dir) else path);
    if dev_options.level && world_is_loaded()  print_player_report();
    return last;
}

// With a level's screenshot, where the player is and how it's doing, to check the logic
// without looking.
print_player_report :: () {
    p := world_get_player();
    a := world_get_agent();
    s := world_get_player_state();
    f :: (x: s32) -> float { return x / 65536.0; };
    print("Player at % % % in sector %, eye %, on floor %; health % shields % lives % battery % (of 100)%\n",
          f(p.position.x), f(p.position.y), f(p.position.z), p.sector, f(p.height), p.on_floor,
          a.health, a.shields, a.lives, a.battery * 50 / 65536, ifx s.dying then ", dying" else "");
    print("Ammo % (energy, power, plasma, detonators, shells, mines, missiles)\n", a.ammo);
    elevators, triggers, teleports := world_get_inf_counts();
    print("INF: % elevators, % triggers, % teleports\n", elevators, triggers, teleports);
}

#scope_file

// Enough frames for the tools to load what they show.
// --level-input: keys held over a span of frames.
Dev_Level_Input :: struct {
    from, to: int;
    keys: World_Input;
}

add_dev_level_input :: (value: string) -> bool {
    parts := split(value, ":",, temp);
    if parts.count != 3 return false;
    span: Dev_Level_Input;
    span.from, span.to = string_to_int(parts[0]), string_to_int(parts[1]);
    k := *span.keys;
    for split(parts[2], "+",, temp) {
        if it == {
            case "forward";        k.forward = true;
            case "back";           k.back = true;
            case "left";           k.left = true;
            case "right";          k.right = true;
            case "turn_left";      k.turn_left = true;
            case "turn_right";     k.turn_right = true;
            case "look_up";        k.look_up = true;
            case "look_down";      k.look_down = true;
            case "run";            k.run = true;
            case "walk";           k.walk = true;
            case "jump";           k.jump = true;
            case "crouch";         k.crouch = true;
            case "use";            k.use = true;
            case "fire";           k.fire = true;
            case "fire_secondary"; k.fire_secondary = true;
            case; print("--level-input: no key '%'.\n", it); return false;
        }
    }
    array_add(*dev_options.level_inputs, span);
    return true;
}

Dev_Key :: struct {
    frame: int;
    key: SDL_Keycode;
    name: string;               // Zero-terminated: a single character goes as text.
    sent_frame := -1;
}

dev_options: struct {
    tool, open, screenshot: string;
    screenshot_frame := 30;
    dump_dir: string;           // --dump-frames.
    dump_count := 1;
    click_frame := -1;
    play: bool;
    scene: s32;
    enhanced, original: bool;
    level: string;
    level_turn, level_pitch: float;
    level_walk, level_strafe, level_frame: int;
    level_run, level_headlight, level_goggles, level_mask, level_yawed, hide_status, level_bot, level_god: bool;
    level_yaw: float;
    level_use := -1;
    level_fire := -1;
    level_fire_secondary := -1;
    level_weapon := -1;
    level_launch := -1;
    level_launch_type: int;
    level_turn_frame, level_walk_after: int;
    level_at: Vector3;
    level_placed: bool;
    keys: [..] Dev_Key;
    level_inputs: [..] Dev_Level_Input;
    frame: int;
    transfer: *SDL_GPUTransferBuffer;
    width, height: u32;
    bgra: bool;
};

#import "Basic";
#import "File";
#import "String";
#import "Math";
#import "stb_image_write";
#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "engine/dfImGui";
#import "engine/dfWorld";
#import "engine/dfFixed";
#import "engine/dfLevel";
#import "engine/dfRender";
