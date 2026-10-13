// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

main :: () {
    #if OS == .LINUX {
        // --x11 forces X11 (XWayland under Wayland) for ImGui's multi-viewport windows, which
        // need desktop positions that Wayland doesn't give. Not the default: X11 clients from the
        // dev container freeze the desktop every few seconds.
        for get_command_line_arguments()  if it == "--x11"  SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "x11");

        // NVIDIA's driver holds a file descriptor for every block of GPU memory, and a level's
        // art takes over a thousand: more than the soft limit of 1024 a desktop launch gets.
        // Raise it to the hard limit, as games under Steam get.
        limit: Posix.rlimit;
        if Posix.getrlimit(.RLIMIT_NOFILE, *limit) == 0 && limit.rlim_cur < limit.rlim_max {
            limit.rlim_cur = limit.rlim_max;
            Posix.setrlimit(.RLIMIT_NOFILE, *limit);
        }
    }
    // Automated runs are silent and keep their window hidden: they capture into a texture of
    // their own, so nothing needs to be on the screen or come out of the speakers.
    parse_ci_test_command_line();
    // Runs last: the CI test's result is the exit code.
    defer if is_ci_test()  exit(get_ci_exit_code());
    automated := is_ci_test();
    #if DEV  if is_automated_run_requested()  automated = true;
    if automated  SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");
    if !SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)  exit_on_error(tprint("SDL_Init failed: %", to_string(SDL_GetError())));
    defer SDL_Quit();

    window := SDL_CreateWindow(TITLE.data, 1280, 720, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN);
    if !window  exit_on_error(tprint("SDL_CreateWindow failed: %", to_string(SDL_GetError())));
    defer SDL_DestroyWindow(window);

    // Where the desktop's scale isn't applied for us (X11, Windows), the window is made that
    // much bigger by hand, as ImGui is in im_init.
    ui_scale := im_get_ui_scale(window);
    if ui_scale != 1  SDL_SetWindowSize(window, xx (1280 * ui_scale), xx (720 * ui_scale));
    if !automated {
        SDL_ShowWindow(window);
        SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED_MASK, SDL_WINDOWPOS_CENTERED_MASK);
    }
    // A ship build starts fullscreen, as the original did.
    #if SHIP  if !is_ci_test()  SDL_SetWindowFullscreen(window, true);

    // The renderer's shaders are SPIR-V only, and on Windows SDL prefers Direct3D 12 when it's
    // offered, so ask for Vulkan first. Direct3D 12 still runs the ImGui tools without Vulkan.
    device := SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, DEV, null);
    if !device  device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV | SDL_GPU_SHADERFORMAT_DXBC, DEV, null);
    if !device  exit_on_error(tprint("SDL_CreateGPUDevice failed: %", to_string(SDL_GetError())));
    defer SDL_DestroyGPUDevice(device);
    add_ci_note("GPU driver", to_string(SDL_GetGPUDeviceDriver(device)));

    if !SDL_ClaimWindowForGPUDevice(device, window)  exit_on_error(tprint("SDL_ClaimWindowForGPUDevice failed: %", to_string(SDL_GetError())));
    defer SDL_ReleaseWindowFromGPUDevice(device, window);
    SDL_SetGPUSwapchainParameters(device, window, .SDR, .VSYNC);

    im_init(window, device, SDL_GetGPUSwapchainTextureFormat(device, window));
    defer im_shutdown(device);
    if is_ci_test() {
        // Every window in the main one, where the capture sees it, and no saved layout.
        io := ImGui.GetIO();
        io.IniFilename = null;
        io.ConfigFlags &= ~ImGuiConfigFlags.ViewportsEnable;
    }

    rendering := render_init(device);
    if !rendering  print("The renderer failed to start; nothing in the game can be drawn.\n");
    add_ci_check("renderer started", rendering);
    defer render_shutdown();

    // A ship build reads the data from DARK beside the executable; dev builds from the repo's
    // dark external.
    #if SHIP {
        dark_dir := tprint("%DARK", path_strip_filename(get_path_of_running_executable()));
        found := file_exists(tprint("%/DARK.GOB", dark_dir));
    } else {
        dark_dir, found := find_dark_data_dir();
    }
    set_dark_data_dir(dark_dir);
    add_ci_check("game data found", found, dark_dir);
    if !found {
        print("Game data not found in %\n", dark_dir);
        // A ship build has nothing to show without it, nor a CI test anything to check.
        if is_ci_test()  exit_on_error("No game data.");
        #if SHIP {
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, TITLE.data, temp_c_string(tprint("Dark Forces data not found in %", dark_dir)), window);
            exit(1);
        }
    } else if !gob_mount_retail(dark_dir) {
        print("Couldn't mount the GOBs in %\n", dark_dir);
        add_ci_check("GOBs mounted", false);
        gob_unmount_all();
    } else {
        add_ci_check("GOBs mounted", true);
    }
    defer gob_unmount_all();

    // The game's logic needs DARK.EXE's cosine table; music, the FM driver's from IMUSE.EXE.
    if found {
        ok := fixed_load_tables(dark_dir);
        if !ok  print("Couldn't read the tables in %/DARK.EXE; levels are off.\n", dark_dir);
        add_ci_check("DARK.EXE's tables read", ok);
        ok = fm_load_driver(dark_dir);
        if !ok  print("Couldn't read the FM driver from %/IMUSE.EXE; music is off.\n", dark_dir);
        add_ci_check("IMUSE.EXE's FM driver read", ok);
    }

    // The game runs without sound if audio can't start.
    audio := audio_init();
    if !audio  print("Audio failed to start; continuing without sound.\n");
    add_ci_check("audio started (the dummy driver)", audio);
    music_init();
    if found {
        audio_lock();
        ok := imuse_load_digital_tables(dark_dir);
        audio_unlock();
        if !ok  print("Couldn't read iMUSE's mixing tables from %/IMUSE.EXE; digital sound is off.\n", dark_dir);
        add_ci_check("IMUSE.EXE's mixing tables read", ok);
    }
    defer audio_shutdown();

    if found {
        ok := cutscene_init();
        if !ok  print("Couldn't read CUTSCENE.LST; cutscenes are off.\n");
        add_ci_check("CUTSCENE.LST read", ok);
    }
    defer cutscene_shutdown();
    defer release_cutscene_screen();
    if found {
        ok := menu_init(dark_dir);
        if !ok  print("Couldn't read HOTKEYS.MSG, MENU.LFD's font or DARK.EXE's colors; the game's menus won't work right.\n");
        add_ci_check("menus read", ok);
    }
    defer menu_shutdown();
    defer release_menu_screen();
    #if DEV  defer shutdown_tools();

    fullscreen := false;
    in_tools := false;
    cutscenes: Cutscene_Settings;
    #if DEV {
        in_tools = parse_dev_command_line();
        if is_enhanced_requested()  cutscenes.enhanced = true;
        if is_original_requested()  cutscenes.enhanced = false;
        if is_light_only_requested()  game.draw.light_only = true;
    }
    if is_real_input_ignored()  ImGui.GetIO().ConfigFlags |= .NoMouse | .NoKeyboard;
    // A ship build runs as the original: the opening, then the agent menu.
    #if SHIP  if !is_ci_test()  start_play();
    // Fixed-step runs (the CI test, the diff, screenshots) go as fast as they can, not held to
    // the display.
    fixed_run := is_ci_test();
    #if DEV {
        _, screenshot := get_screenshot_clock();
        if is_fixed_cutscene_run() || screenshot  fixed_run = true;
    }
    if fixed_run {
        notice.off = true;
        mode := ifx SDL_WindowSupportsGPUPresentMode(device, window, .IMMEDIATE) then SDL_GPUPresentMode.IMMEDIATE else .MAILBOX;
        if SDL_WindowSupportsGPUPresentMode(device, window, mode)  SDL_SetGPUSwapchainParameters(device, window, .SDR, mode);
        // And they'd outrun the in-between fits, so they wait for them, to come out the same
        // every time.
        cutscene_set_waiting_for_fits(true);
    }
    #if DEV {
        if is_play_requested() && !is_fixed_cutscene_run() {
            start_play(get_requested_scene());
        } else if is_play_requested() {
            cutscene_start(get_requested_scene(), get_clock());
        }
        level := get_requested_level();
        if level  start_level(window, level, in_tools);
    }
    last_frame_ns := SDL_GetTicksNS();
    running := true;
    while running {
        profile_begin_frame();
        events_zone := profile_open_zone("events");
        event: SDL_Event;
        while SDL_PollEvent(*event) {
            if is_real_input_ignored() && is_device_input(*event) continue;
            im_process_event(*event);
            if cast(SDL_EventType) event.type == {
                case .QUIT;
                    running = false;
                case .WINDOW_CLOSE_REQUESTED;
                    if event.window.windowID == SDL_GetWindowID(window) running = false;
                case .WINDOW_ENTER_FULLSCREEN;
                    fullscreen = true;
                case .WINDOW_LEAVE_FULLSCREEN;
                    fullscreen = false;
                case .MOUSE_MOTION;
                    if game.playing && !is_esc_menu_up() && !game.paused {
                        game.mouse_x += event.motion.xrel;
                        game.mouse_y += event.motion.yrel;
                    }
                case .TEXT_INPUT;
                    if is_menu_shown()  send_menu_text(event.text.text);
                case .KEY_DOWN;
                    // As the original: Esc and Enter skip, Space goes to the next scene.
                    // Alt+Enter is left to window managers that use it for fullscreen.
                    key := event.key;
                    // Everywhere, before the menus and the game take their keys.
                    if key.key == SDLK_F11 && !key.repeat {
                        SDL_SetWindowFullscreen(window, (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN) == 0);
                        continue;
                    }
                    // F12, unused by the original, is Enhanced Mode for everything: the
                    // cutscenes and the level view.
                    if key.key == SDLK_F12 && !key.repeat {
                        cutscenes.enhanced = !cutscenes.enhanced;
                        show_notice(ifx cutscenes.enhanced then "Enhanced Mode: On" else "Enhanced Mode: Off");
                        continue;
                    }
                    if key.key == DEBUG_PANEL_KEY && !key.repeat {
                        toggle_debug_panel();
                        continue;
                    }
                    if is_menu_shown() {
                        send_menu_key(key);
                        continue;
                    }
                    if game.playing && is_esc_menu_up()  continue;
                    // As the original's Pause: the level stops, and every key but Pause again
                    // is thrown away. Not the original's: the pointer is let go meanwhile.
                    if game.playing && key.key == SDLK_PAUSE && !key.repeat {
                        game.paused = !game.paused;
                        set_mouse_captured(window, !game.paused);
                        continue;
                    }
                    if game.playing && game.paused  continue;
                    // The same in a cutscene, on its clock.
                    if cutscene_is_playing() && key.key == SDLK_PAUSE && !key.repeat {
                        set_cutscene_paused(!is_cutscene_paused());
                        continue;
                    }
                    if cutscene_is_playing() && is_cutscene_paused()  continue;
                    if game.playing && !key.repeat {
                        if key.key == SDLK_ESCAPE  open_esc_menu();
                        else if key.key == SDLK_F1 { if play.active  open_pda(); }
                        // The goggles, cleats, mask and headlamp.
                        else if key.key == SDLK_F2  world_toggle_goggles();
                        else if key.key == SDLK_F3  world_toggle_cleats();
                        else if key.key == SDLK_F4  world_toggle_mask();
                        else if key.key == SDLK_F5  world_toggle_headlight();
                        // The map: Tab (Alt+Tab every layer), [ and ] its layer.
                        else if key.key == SDLK_TAB  world_toggle_automap((key.mod & SDL_KMOD_ALT) != 0);
                        else if key.key == SDLK_LEFTBRACKET   world_change_automap_layer(false);
                        else if key.key == SDLK_RIGHTBRACKET  world_change_automap_layer(true);
                        // The original's weapon keys: F8 holsters (Alt+F8 auto-switching),
                        // F9 and F10 the previous and next weapon, Backspace the one before.
                        else if key.key == SDLK_F8 && (key.mod & SDL_KMOD_ALT)  world_toggle_weapon_auto_switch();
                        else if key.key == SDLK_F8   world_holster_weapon();
                        else if key.key == SDLK_F9   world_cycle_weapon(-1);
                        else if key.key == SDLK_F10  world_cycle_weapon(1);
                        else if key.key == SDLK_BACKSPACE  world_swap_weapon();
                        continue;
                    }
                    if !cutscene_is_playing() || key.repeat continue;
                    if key.key == SDLK_ESCAPE || (key.key == SDLK_RETURN && !(key.mod & SDL_KMOD_ALT))  cutscene_skip();
                    else if key.key == SDLK_SPACE  cutscene_next();
                case .MOUSE_BUTTON_DOWN;
                    // Not a click on a window over the cutscene (the cutscene tool's).
                    if !cutscene_is_playing() || is_cutscene_paused() || ImGui.GetIO().WantCaptureMouse continue;
                    if event.button.button == SDL_BUTTON_RIGHT       cutscene_skip();
                    else if event.button.button == SDL_BUTTON_LEFT   cutscene_next();
            }
        }

        profile_close_zone(events_zone);

        im_new_frame();
        action := Menu_Action.NONE;
        #if DEV {
            advance_cutscene_tool_clock(get_base_clock());
            send_dev_clicks();
        }
        begin_ci_frame(window, *cutscenes);
        now_ns := SDL_GetTicksNS();
        dt := (now_ns - last_frame_ns) / 1_000_000_000.0;
        last_frame_ns = now_ns;
        if is_ci_test()  dt = 1.0 / 60;
        #if DEV {
            _, fixed := get_screenshot_clock();
            if fixed  dt = 1.0 / 60;
        }

        set_menu_text_input(window, is_menu_shown());
        if is_menu_shown()  send_menu_mouse();
        update_play(window, *in_tools, *running);
        // A ship build has no main menu: when the run ends (the agent menu's Exit), so does
        // the program.
        #if SHIP  if !play.active && !is_ci_test()  running = false;

        // The desktop's cursor only on the ImGui screens: the game draws its own.
        os_cursor := false;
        game.draw.original = !cutscenes.enhanced;
        if game.playing && is_esc_menu_up() {
            show_esc_level();
        } else if game.playing {
            if !game.paused {
                profile_zone("level update");
                update_level(cast(float) dt);
            }
            // Dead with no lives left: the level is over, and in a mission back to its
            // briefing. A mission complete waits for Esc.
            if world_has_failed() {
                if play.active  on_level_failed(window, *in_tools);
                else            stop_level(window, *in_tools);
            } else {
                profile_zone("level draw");
                show_level(game.draw);
            }
        } else if play.screen == .BRIEFING || play.screen == .AGENT_MENU {
            profile_zone("menu");
            show_menu_screen(menu_get_palette());
        } else if cutscene_is_playing() && update_cutscene() {
            profile_zone("cutscene draw");
            show_cutscene(cutscenes);
            #if DEV {
                show_cutscene_tool_controls(*cutscenes);
                _, os_cursor = get_cutscene_tool_clock();
            }
        } else if !play.active {
            // Between Play's steps (a cinematic just ended, the next not started until the
            // next frame) the screen stays black rather than flash the main menu.
            os_cursor = true;
            #if DEV {
                if in_tools  in_tools = show_tools(*cutscenes);
                else         action = show_main_menu(*fullscreen, *cutscenes);
            }
        }
        {
            profile_zone("debug panel");
            show_debug_panel();
        }
        show_os_cursor(os_cursor || is_debug_panel_using_mouse() || is_anything_paused());
        hold_audio_while_paused();
        update_start_notice(cutscenes.enhanced);
        draw_notice();
        {
            profile_zone("imgui");
            ImGui.Render();
        }
        draw_data := ImGui.GetDrawData();

        if action == {
            case .QUIT;
                running = false;
            case .TOGGLE_FULLSCREEN;
                SDL_SetWindowFullscreen(window, fullscreen);
            case .TOOLS;
                in_tools = true;
            case .PLAY;
                start_play();
        }
        #if DEV {
            requested := take_tool_level_request();
            if requested  start_level(window, requested, true);
        }

        cmd := SDL_AcquireGPUCommandBuffer(device);

        // Offscreen views first: their copy and render passes can't go inside ImGui's pass.
        {
            profile_zone("render submit");
            render_submit(cmd);
        }

        tex: *SDL_GPUTexture;
        {
            profile_zone("swapchain wait");
            if !SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, *tex, null, null) {
                print("SDL_WaitAndAcquireGPUSwapchainTexture failed: %\n", to_string(SDL_GetError()));
            }
        }
        present_zone := profile_open_zone("present");

        minimized := draw_data.DisplaySize.x <= 0.0 || draw_data.DisplaySize.y <= 0.0;
        if tex != null && !minimized {
            im_prepare(draw_data, cmd);

            target: SDL_GPUColorTargetInfo;
            target.texture = tex;
            target.clear_color = .{0.0, 0.0, 0.0, 1.0};
            target.load_op = .CLEAR;
            target.store_op = .STORE;

            pass := SDL_BeginGPURenderPass(cmd, *target, 1, null);
            im_render(draw_data, cmd, pass);
            SDL_EndGPURenderPass(pass);
            capture_ci_frame(device, cmd, draw_data, SDL_GetGPUSwapchainTextureFormat(device, window));
            #if DEV  capture_dev_screenshot(device, cmd, draw_data, SDL_GetGPUSwapchainTextureFormat(device, window));
        } else if automated && !minimized {
            // A hidden window has no swapchain texture: the capture draws the frame alone.
            im_prepare(draw_data, cmd);
            capture_ci_frame(device, cmd, draw_data, SDL_GetGPUSwapchainTextureFormat(device, window));
            #if DEV  capture_dev_screenshot(device, cmd, draw_data, SDL_GetGPUSwapchainTextureFormat(device, window));
        }

        im_render_viewports();

        SDL_SubmitGPUCommandBuffer(cmd);
        profile_close_zone(present_zone);
        if !end_ci_frame(device)  running = false;
        #if DEV {
            if finish_dev_screenshot(device)  running = false;
            if !check_fixed_cutscene_run()  running = false;
        }
        reset_temporary_storage();
    }
}

// ImGui sets the cursor's shape and shows it each frame unless told not to.
show_os_cursor :: (shown: bool) {
    io := ImGui.GetIO();
    if shown {
        io.ConfigFlags &= ~ImGuiConfigFlags.NoMouseCursorChange;
    } else {
        io.ConfigFlags |= .NoMouseCursorChange;
        SDL_HideCursor();
    }
}

// While the opening plays, the version, the state as F12 shows it, then jaidi's own keys.
NOTICE_START_ENHANCED :: #run tprint("% %\nEnhanced Mode: On\nF11 - Toggle Fullscreen\nF12 - Toggle Enhanced\nInsert - Debug Panel", GAME_NAME, VERSION);
NOTICE_START_ORIGINAL :: #run tprint("% %\nEnhanced Mode: Off\nF11 - Toggle Fullscreen\nF12 - Toggle Enhanced\nInsert - Debug Panel", GAME_NAME, VERSION);
NOTICE_START_NS :: 15_000_000_000;
NOTICE_NS       :: 3_000_000_000;
NOTICE_SCALE    :: 1.5;

notice: struct {
    text:     string;
    until_ns: u64;
    opening:  bool;             // The start notice is up for the opening playing.
    off:      bool;             // None at all: automated runs.
};

// The start notice from when the opening starts until it's skipped or done.
update_start_notice :: (enhanced: bool) {
    playing := is_opening_playing();
    if playing && !notice.opening {
        show_notice(ifx enhanced then NOTICE_START_ENHANCED else NOTICE_START_ORIGINAL, NOTICE_START_NS);
    } else if !playing && notice.opening {
        notice.until_ns = 0;
    }
    notice.opening = playing;
}

// Text in the upper left over whatever is shown, for a few seconds.
show_notice :: (text: string, duration_ns: u64 = NOTICE_NS) {
    notice.text = text;
    notice.until_ns = SDL_GetTicksNS() + duration_ns;
}

draw_notice :: () {
    if notice.off || SDL_GetTicksNS() >= notice.until_ns return;
    viewport := ImGui.GetMainViewport();
    draw_list := ImGui.GetForegroundDrawList(viewport);
    // From the base size, not GetFontSize(), so the display scale isn't applied twice.
    ImGui.PushFont(null, ImGui.GetStyle().FontSizeBase * NOTICE_SCALE);
    defer ImGui.PopFont();
    pad := im_scale(ImVec2.{8 * NOTICE_SCALE, 6 * NOTICE_SCALE});
    pos := ImVec2.{viewport.Pos.x + pad.x * 2, viewport.Pos.y + pad.y * 2};
    size := ImGui.CalcTextSize(notice.text);
    draw_list.AddRectFilled(draw_list, ImVec2.{pos.x - pad.x, pos.y - pad.y}, ImVec2.{pos.x + size.x + pad.x, pos.y + size.y + pad.y}, 0xC0000000, im_scale(4.0 * NOTICE_SCALE));
    draw_list.AddText(draw_list, pos, 0xFFFFFFFF, notice.text);
}

Menu_Action :: enum {
    NONE;
    QUIT;
    TOGGLE_FULLSCREEN;
    TOOLS;
    PLAY;
}

// Nanoseconds. While the cutscene tool plays one, the tool's clock, which stops when paused;
// otherwise the debug panel's, which runs with the base clock unless paused or moved.
get_clock :: () -> u64 {
    #if DEV {
        time, driving := get_cutscene_tool_clock();
        if driving return time;
    }
    return get_debug_panel_clock(get_base_clock());
}

// Under --ci-test, --cutscene-diff or --screenshot a fixed step per frame instead of the time.
get_base_clock :: () -> u64 {
    if is_ci_test()  return get_ci_clock();
    #if DEV {
        if is_fixed_cutscene_run()  return get_fixed_run_clock();
        time, fixed := get_screenshot_clock();
        if fixed  return time;
    }
    return SDL_GetTicksNS();
}

Cutscene_Settings :: struct {
    enhanced := true;   // The GPU presenter's smooth picture, in the window's shape up to 16:9,
                        // rather than the original's 4:3.
}

show_main_menu :: (fullscreen: *bool, cutscenes: *Cutscene_Settings) -> Menu_Action {
    button_size := im_scale(ImVec2.{160, 40});
    FULLSCREEN_LABEL :: "Fullscreen";

    action := Menu_Action.NONE;

    viewport := ImGui.GetMainViewport();
    ImGui.SetNextWindowPos(viewport.WorkPos);
    ImGui.SetNextWindowSize(viewport.WorkSize);
    ImGui.SetNextWindowViewport(viewport.ID);

    flags := ImGuiWindowFlags.NoDecoration | .NoBackground | .NoMove | .NoSavedSettings | .NoBringToFrontOnFocus | .NoDocking;
    if ImGui.Begin("Main Menu", flags = flags) {
        style := ImGui.GetStyle();
        avail := ImGui.GetContentRegionAvail();

        button_x := (avail.x - button_size.x) * 0.5 + style.WindowPadding.x;
        checkbox_width := ImGui.GetFrameHeight() + style.ItemInnerSpacing.x + ImGui.CalcTextSize(FULLSCREEN_LABEL).x;
        total_height := 3 * (button_size.y + style.ItemSpacing.y) + 2 * (ImGui.GetFrameHeight() + style.ItemSpacing.y);

        ImGui.SetCursorPosY((avail.y - total_height) * 0.5 + style.WindowPadding.y);
        ImGui.SetCursorPosX(button_x);
        if ImGui.Button("Play", button_size) action = .PLAY;
        ImGui.SetCursorPosX(button_x);
        if ImGui.Button("Tools", button_size) action = .TOOLS;
        ImGui.SetCursorPosX(button_x);
        if ImGui.Button("Quit", button_size) action = .QUIT;

        ImGui.SetCursorPosX((avail.x - checkbox_width) * 0.5 + style.WindowPadding.x);
        if ImGui.Checkbox(FULLSCREEN_LABEL, fullscreen) action = .TOGGLE_FULLSCREEN;

        // Original: the 320x200 screen as the game drew it. Enhanced: cutscenes through the
        // GPU presenter, levels at the window's resolution.
        MODE_LABEL :: "Mode:";
        radio_width := ImGui.CalcTextSize(MODE_LABEL).x + ImGui.CalcTextSize("Original").x + ImGui.CalcTextSize("Enhanced").x + 2 * ImGui.GetFrameHeight() + 6 * style.ItemInnerSpacing.x + 2 * style.ItemSpacing.x;
        ImGui.SetCursorPosX((avail.x - radio_width) * 0.5 + style.WindowPadding.x);
        ImGui.AlignTextToFramePadding();
        ImGui.Text(MODE_LABEL);
        ImGui.SameLine();
        if ImGui.RadioButton("Original", !cutscenes.enhanced)  cutscenes.enhanced = false;
        ImGui.SameLine();
        if ImGui.RadioButton("Enhanced", cutscenes.enhanced)   cutscenes.enhanced = true;
    }
    ImGui.End();

    return action;
}

// The cutscene's 320x200 screen, shown at 4:3 over the whole window. Original: the CPU's video
// buffer, drawn through the palette by the renderer, its pixels sampled nearest. Enhanced: the
// GPU presenter's smooth image, drawn at the size it's shown, one texel per framebuffer pixel.
// The GPU presenter runs every frame either way (exact while Original), so switching is
// seamless and --cutscene-diff can compare.
show_cutscene :: (settings: Cutscene_Settings) {
    WIDTH, HEIGHT :: 320, 200;
    viewport := ImGui.GetMainViewport();
    pixels := ImGui.GetIO().DisplayFramebufferScale;
    size := viewport.Size;

    // The shape to draw in: 4:3, the screen's pixels 1.2 times taller than wide; Enhanced, the
    // window's, up to 16:9.
    aspect := 4.0 / 3.0;
    if settings.enhanced  aspect = clamp(size.x / size.y, 4.0 / 3.0, 16.0 / 9.0);
    width, height := get_shown_size(size, pixels, aspect);

    screen, shown_aspect := cutscene_present_gpu(get_clock(), settings.enhanced, width, height, aspect);
    if !settings.enhanced || !screen {
        video := cutscene_get_video();
        palette := cutscene_get_palette();
        render_size_view(*cutscene_screen.view, WIDTH, HEIGHT);
        render_update_image(*cutscene_screen.image, .{WIDTH, HEIGHT, video});
        render_begin_view(*cutscene_screen.view, *palette, null, .{perspective = false});
        render_set_image(*cutscene_screen.image);
        render_add_quad(.{-WIDTH / 2, -HEIGHT / 2, 1}, .{WIDTH / 2, HEIGHT / 2, 1}, .{0, 0}, .{WIDTH, HEIGHT}, 31, 0, render_pack_color(.TEXTURE_RAW));
        screen = cutscene_screen.view.color;
        shown_aspect = 4.0 / 3.0;
    }

    // Centered, placed on whole framebuffer pixels. The presenter may hand back the original's
    // 4:3 picture even when wide (while a snap fade holds the old image).
    width, height = get_shown_size(size, pixels, shown_aspect);
    left := cast(s32) ((size.x * pixels.x - width) / 2);
    top  := cast(s32) ((size.y * pixels.y - height) / 2);
    p0 := ImVec2.{viewport.Pos.x + left / pixels.x, viewport.Pos.y + top / pixels.y};
    p1 := ImVec2.{p0.x + width / pixels.x, p0.y + height / pixels.y};

    ImGui.SetNextWindowPos(viewport.Pos);
    ImGui.SetNextWindowSize(viewport.Size);
    ImGui.SetNextWindowViewport(viewport.ID);
    ImGui.PushStyleVar(.WindowPadding, ImVec2.{0, 0});
    ImGui.PushStyleVar(.WindowBorderSize, 0);
    ImGui.PushStyleColor(.WindowBg, 0xFF000000);
    // Always at the back: reappearing, a window takes focus and comes to the front, and this
    // one would cover anything drawn over it (the cutscene tool's controls).
    flags := ImGuiWindowFlags.NoDecoration | .NoMove | .NoSavedSettings | .NoDocking | .NoInputs | .NoBringToFrontOnFocus | .NoFocusOnAppearing;
    if ImGui.Begin("Cutscene", flags = flags) {
        draw_list := ImGui.GetWindowDrawList();
        platform := ImGui.GetPlatformIO();
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerNearest);
        draw_list.AddImage(draw_list, .{_TexID = cast(ImTextureID) screen}, p0, p1);
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerLinear);
        if is_cutscene_paused()  draw_paused_box(draw_list, viewport);
    }
    ImGui.End();
    ImGui.PopStyleColor();
    ImGui.PopStyleVar(2);
}

// The largest size of the given shape that fits the window, in framebuffer pixels.
get_shown_size :: (size: ImVec2, pixels: ImVec2, aspect: float) -> s32, s32 {
    shown := ifx size.x > size.y * aspect then ImVec2.{size.y * aspect, size.y} else ImVec2.{size.x, size.x / aspect};
    return cast(s32) (shown.x * pixels.x), cast(s32) (shown.y * pixels.y);
}

// A level being played: the world, the input that moves it and how it's drawn.
game: struct {
    playing: bool;
    paused: bool;                   // The Pause key.
    audio_paused: bool;             // Music and sounds held, in a level or a cutscene.
    from_tools: bool;               // Esc goes back to the tools rather than the menu.
    mouse_x, mouse_y: float;
    draw: World_Draw_Options;
    rate_shown: float;              // The frame rate in the overlay.
    rate_shown_at: u64;
};

start_level :: (window: *SDL_Window, name: string, from_tools: bool, difficulty := DIFFICULTY_MEDIUM) -> bool {
    if !world_load(name, difficulty) {
        print("Couldn't load level %.\n", name);
        return false;
    }
    cutscene_stop();
    // The level's stalk music, by its place in JEDI.LVL.
    for world_get_level_list()  if it.name == world_get_name()  music_start_level(it_index + 1);
    game.playing = true;
    game.paused = false;
    game.from_tools = from_tools;
    game.mouse_x, game.mouse_y = 0, 0;
    set_mouse_captured(window, true);
    return true;
}

stop_level :: (window: *SDL_Window, in_tools: *bool) {
    // From the tools, the next level starts with the weapon in hand, as after a mission.
    if game.from_tools  world_keep_weapon();
    world_unload();
    music_stop();
    game.playing = false;
    game.paused = false;
    in_tools.* = game.from_tools;
    set_mouse_captured(window, false);
}

// The level takes the mouse's motion while it runs; not in automated runs, which leave the
// pointer alone.
set_mouse_captured :: (window: *SDL_Window, captured: bool) {
    if is_real_input_ignored() return;
    SDL_SetWindowRelativeMouseMode(window, captured);
}

// Automated runs (the CI test, the dev screenshots, the diff) take no input from the real
// keyboard and mouse, so whoever is at the machine can't change what they capture.
is_real_input_ignored :: () -> bool {
    #if DEV  if is_input_ignored() return true;
    return is_ci_test();
}

// Input from the keyboard and mouse rather than pushed by an automated run, which pushes its
// keys with no window.
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

// Before the program is far enough along to run: says why, in the CI test's report too, and
// quits.
exit_on_error :: (message: string) {
    print("%\n", message);
    add_ci_check("started", false, message);
    write_ci_report();
    exit(1);
}

update_level :: (dt: float) {
    keys := SDL_GetKeyboardState(null);
    none: [SDL_Scancode.COUNT] bool;
    if is_real_input_ignored()  keys = none.data;
    input: World_Input;
    // As in the original, the strafe key makes the turn keys strafe.
    strafing := keys[SDL_Scancode.LALT] || keys[SDL_Scancode.RALT];
    // With the map up, ` held scrolls it with the arrows, which the player doesn't get then.
    input.map_scroll   = keys[SDL_Scancode.GRAVE];
    input.map_zoom_in  = keys[SDL_Scancode.EQUALS];
    input.map_zoom_out = keys[SDL_Scancode.MINUS];
    scrolling := world_is_automap_on() && input.map_scroll;
    up, down, left, right := keys[SDL_Scancode.UP], keys[SDL_Scancode.DOWN], keys[SDL_Scancode.LEFT], keys[SDL_Scancode.RIGHT];
    if scrolling {
        input.map_up, input.map_down, input.map_left, input.map_right = up, down, left, right;
        up, down, left, right = false, false, false, false;
    }
    input.forward    = keys[SDL_Scancode.W] || up;
    input.back       = keys[SDL_Scancode.S] || down;
    input.left       = keys[SDL_Scancode.A] || (strafing && left);
    input.right      = keys[SDL_Scancode.D] || (strafing && right);
    input.turn_left  = !strafing && left;
    input.turn_right = !strafing && right;
    input.look_up    = keys[SDL_Scancode.PAGEUP];
    input.look_down  = keys[SDL_Scancode.PAGEDOWN];
    input.center_view = keys[SDL_Scancode.HOME];
    input.run        = keys[SDL_Scancode.LSHIFT] || keys[SDL_Scancode.RSHIFT];
    input.walk       = keys[SDL_Scancode.CAPSLOCK];
    input.jump       = keys[SDL_Scancode.SPACE];
    input.crouch     = keys[SDL_Scancode.C];
    // The original's fire keys are Ctrl and Z, with the mouse's first and third buttons; its
    // second is use.
    buttons := cast(u32) SDL_GetMouseState(null, null);
    if is_real_input_ignored()  buttons = 0;
    input.fire       = keys[SDL_Scancode.LCTRL] || keys[SDL_Scancode.RCTRL] || (buttons & (1 << (SDL_BUTTON_LEFT - 1))) != 0;
    input.fire_secondary = keys[SDL_Scancode.Z] || (buttons & (1 << (SDL_BUTTON_MIDDLE - 1))) != 0;
    for 0..9  input.weapon_keys[it] = keys[cast(SDL_Scancode) (cast(s32) SDL_Scancode._1 + it)];
    input.revive     = keys[SDL_Scancode.SPACE];
    input.use        = keys[SDL_Scancode.E] || keys[SDL_Scancode.RETURN] || (buttons & (1 << (SDL_BUTTON_RIGHT - 1))) != 0;
    input.mouse_x, input.mouse_y = game.mouse_x, game.mouse_y;
    game.mouse_x, game.mouse_y = 0, 0;
    apply_ci_level_input(*input);
    fixed_step := is_ci_test();
    #if DEV {
        apply_dev_level_input(*input);
        if is_fixed_clock()  fixed_step = true;
    }
    {
        profile_zone("world update");
        world_update(dt, input, fixed_step);
    }
    // The enemies' alerts start and keep up the fight music; it runs out on its own.
    for world_take_music_events() {
        if it.kind == .FIGHT  music_start_fight(it.tick);
        else                  music_sustain_fight(it.tick);
    }
    music_update(world_get_tick());
}

// cutscene_update, timed.
update_cutscene :: () -> bool {
    profile_zone("cutscene update");
    return cutscene_update(get_clock());
}

// The level's view over the whole window: the original's 320x200 at 4:3, or at the window's
// size.
show_level :: (options: World_Draw_Options) {
    viewport := ImGui.GetMainViewport();
    pixels := ImGui.GetIO().DisplayFramebufferScale;
    size := viewport.Size;
    width, height: s32;
    if options.original  width, height = get_shown_size(size, pixels, 4.0 / 3.0);
    else width, height = cast(s32) (size.x * pixels.x), cast(s32) (size.y * pixels.y);
    texture: *SDL_GPUTexture;
    {
        profile_zone("world draw");
        texture = world_draw(width, height, options);
    }
    if !texture return;

    left := cast(s32) ((size.x * pixels.x - width) / 2);
    top  := cast(s32) ((size.y * pixels.y - height) / 2);
    p0 := ImVec2.{viewport.Pos.x + left / pixels.x, viewport.Pos.y + top / pixels.y};
    p1 := ImVec2.{p0.x + width / pixels.x, p0.y + height / pixels.y};

    ImGui.SetNextWindowPos(viewport.Pos);
    ImGui.SetNextWindowSize(viewport.Size);
    ImGui.SetNextWindowViewport(viewport.ID);
    ImGui.PushStyleVar(.WindowPadding, ImVec2.{0, 0});
    ImGui.PushStyleVar(.WindowBorderSize, 0);
    ImGui.PushStyleColor(.WindowBg, 0xFF000000);
    flags := ImGuiWindowFlags.NoDecoration | .NoMove | .NoSavedSettings | .NoDocking | .NoInputs | .NoBringToFrontOnFocus | .NoFocusOnAppearing;
    if ImGui.Begin("Level", flags = flags) {
        draw_list := ImGui.GetWindowDrawList();
        platform := ImGui.GetPlatformIO();
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerNearest);
        draw_list.AddImage(draw_list, .{_TexID = cast(ImTextureID) texture}, p0, p1);
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerLinear);
        if game.paused  draw_paused_box(draw_list, viewport);
        #if DEV  if !is_status_hidden() && !is_ci_test() {
            // The frame rate averaged, and shown twice a second, so it can be read.
            now := SDL_GetTicksNS();
            if now - game.rate_shown_at > 500_000_000 {
                game.rate_shown = ImGui.GetIO().Framerate;
                game.rate_shown_at = now;
            }
            player := world_get_player();
            text := tprint("% (sector %)  % fps  Esc: menu, F5: headlight, F12: %", world_get_name(), player.sector,
                           formatFloat(game.rate_shown, trailing_width = 0),
                           ifx game.draw.original then "Enhanced" else "Original");
            draw_list.AddText(draw_list, ImVec2.{viewport.Pos.x + 8, viewport.Pos.y + 6}, 0xFFFFFFFF, text);
        }
    }
    ImGui.End();
    ImGui.PopStyleColor();
    ImGui.PopStyleVar(2);
}

// A level or a cutscene paused, by the Pause key or the debug panel's controls.
is_anything_paused :: () -> bool {
    if game.playing return game.paused;
    return cutscene_is_playing() && is_cutscene_paused();
}

// Not the original's, which lets them play on: music and sounds stop while paused. And a
// cutscene's pause doesn't outlive it.
hold_audio_while_paused :: () {
    if !game.playing && !cutscene_is_playing() && is_cutscene_paused()  set_cutscene_paused(false);
    paused := is_anything_paused();
    if paused != game.audio_paused {
        audio_pause(paused);
        game.audio_paused = paused;
    }
}

// Not the original's, which shows nothing while paused: [PAUSED] in the middle, in a frame,
// large for the window.
draw_paused_box :: (draw_list: *ImDrawList, viewport: *ImGuiViewport) {
    TEXT :: "[PAUSED]";
    ImGui.PushFont(null, max(viewport.Size.y * 0.08, ImGui.GetStyle().FontSizeBase * 3));
    defer ImGui.PopFont();
    size := ImGui.CalcTextSize(TEXT);
    pad := ImVec2.{size.y * 0.6, size.y * 0.35};
    center := ImVec2.{viewport.Pos.x + viewport.Size.x / 2, viewport.Pos.y + viewport.Size.y / 2};
    p0 := ImVec2.{center.x - size.x / 2 - pad.x, center.y - size.y / 2 - pad.y};
    p1 := ImVec2.{center.x + size.x / 2 + pad.x, center.y + size.y / 2 + pad.y};
    rounding := size.y * 0.15;
    draw_list.AddRectFilled(draw_list, p0, p1, 0xC0000000, rounding);
    draw_list.AddRect(draw_list, p0, p1, 0xFFFFFFFF, rounding, thickness = max(size.y * 0.05, 1));
    draw_list.AddText(draw_list, ImVec2.{center.x - size.x / 2, center.y - size.y / 2}, 0xFFFFFFFF, TEXT);
}

cutscene_screen: struct {
    view:  View;
    image: Gpu_Image;
};

release_cutscene_screen :: () {
    render_release_image(*cutscene_screen.image);
    render_release_view(*cutscene_screen.view);
}

#import "Basic";
#import "String";
#import "File_Utilities";
#import "System";
#import "Build_Config";
#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "engine/dfImGui";
#import "engine/dfRender";
#import "engine/dfArchive";
#import "engine/dfAudio";
#import "engine/dfMusic";
#import "engine/dfImage";
#import "engine/dfCutscene";
#import "engine/dfIMuse";
#import "engine/dfWorld";
#import "engine/dfFixed";
#import "engine/dfFm";

#import "engine/dfMenu";

#if OS == .LINUX  Posix :: #import "POSIX";

#load "mission.jai";
#load "debug_panel.jai";
#load "profile.jai";
#load "capture.jai";
#load "ci_test.jai";
#if DEV #load "tools/tools.jai";
