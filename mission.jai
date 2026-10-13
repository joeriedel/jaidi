// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Play: the game's order of play, as DARK.EXE's main loop runs it (0x105ca, the table at
// 0xe499b). After the opening, the agent menu; from the mission chosen there, each mission in
// turn: the cutscene before it (scene 100 N), the briefing, the mission, the cutscene after
// it (100 N + 50); after the last, the ending (1500). Scenes CUTSCENE.LST doesn't have are
// skipped. Dying with no lives left goes back to the briefing; cancelling the briefing,
// aborting the mission or the ending go back to the agent menu, whose Exit ends the run.
//
// The agents are kept in our own DARKPILO.CFG, in the user's data folder: saved each time the
// agent menu is left and when a mission is done, with what the agent takes into the next.
//
// In a mission, Esc fades the game out and brings up the Esc menu over it, the game standing
// still in grey (0x19c94); Return fades it back in. F1 brings up the PDA the same way, over
// the whole screen (0x19f88).

Play_Screen :: enum u8 {
    NONE;
    OPENING;            // The opening cutscene, before the agent menu.
    AGENT_MENU;
    CUTSCENE;
    BRIEFING;
    LEVEL;
}

Esc_Phase :: enum u8 {
    NONE;
    FADE_OUT;           // The game fading to black, a step a tick.
    MENU;
    FADE_MENU;          // Return: the menu fading out,
    FADE_IN;            // then the game fading back in.
}

play: struct {
    active: bool;
    screen: Play_Screen;
    step: s32;                  // Into the order.
    esc: Esc_Phase;
    pda: bool;                  // The PDA in the Esc menu's place.
    fade_step: s32;             // 0 to 31 through a fade.
    fade_next_ns: u64;
    saved_music_volume: int = -1;
};

// The agents, read when Play first starts; the one chosen, kept while the program runs.
agents: Agents;
agents_read: bool;
current_agent: s32;
mission_titles: [..] string;    // JEDI.LVL's.

MISSION_COUNT :: 14;

// The whole run from the opening, as Play does it; scene, for dev runs, starts the opening
// chain elsewhere.
start_play :: (scene: s32 = CUTSCENE_OPENING) {
    if !agents_read {
        ok: bool;
        agents, ok = agents_load(get_agents_path());
        if !ok  agents_save(*agents, get_agents_path());
        agents_read = true;
    }
    play = .{active = true, screen = .OPENING};
    if !cutscene_start(scene, get_clock())  open_agent_menu();
}

is_esc_menu_up :: () -> bool { return play.esc != .NONE; }

is_opening_playing :: () -> bool { return play.active && play.screen == .OPENING && cutscene_is_playing(); }

is_menu_shown :: () -> bool { return play.screen == .AGENT_MENU || play.screen == .BRIEFING || play.esc == .MENU; }

// Once a frame: on to the next step when the one shown is done.
update_play :: (window: *SDL_Window, in_tools: *bool, running: *bool) {
    if !play.active {
        // A level from the tools has the Esc menu too.
        if game.playing  update_esc_menu(window, in_tools, running);
        return;
    }
    if play.screen == {
        case .OPENING;
            if cutscene_is_playing() return;
            open_agent_menu();
        case .AGENT_MENU;
            result := menu_update(get_clock());
            if result == MENU_NO_RESULT return;
            current_agent = menu_get_chosen_agent();
            menu_close();
            // Saved however the menu is left (0x189d8).
            if result > 0  get_agent().selected = result;
            agents_save(*agents, get_agents_path());
            if result <= 0 { end_play(window, in_tools); return; }
            play.step = (result - 1) * 4;
            begin_step(window);
        case .CUTSCENE;
            if cutscene_is_playing() return;
            play.step += 1;
            begin_step(window);
        case .BRIEFING;
            result := menu_update(get_clock());
            if result == MENU_NO_RESULT return;
            // The difficulty chosen is kept even when the briefing is cancelled.
            get_agent().difficulty = cast(u8) menu_get_briefing_difficulty();
            menu_close();
            resume_music();
            if result == 0 { back_to_agent_menu(window, in_tools); return; }
            play.step += 1;
            begin_step(window);
        case .LEVEL;
            update_esc_menu(window, in_tools, running);
        case .NONE;
            begin_step(window);
    }
}

// Esc in a level.
open_esc_menu :: () {
    if play.esc != .NONE return;
    play.esc = .FADE_OUT;
    play.pda = false;
    play.fade_step = 0;
    play.fade_next_ns = get_clock();
}

// F1 in a mission.
open_pda :: () {
    open_esc_menu();
    play.pda = true;
}

// The level's view while the Esc menu is up or fading: the game stands still.
show_esc_level :: () {
    palette := world_get_palette();
    if play.esc == {
        case .FADE_OUT;
            palette = fade_palette(palette, 0xF800 - play.fade_step * 0x800);
        case .MENU;
            if play.pda { show_menu_screen(menu_get_palette()); return; }
            palette = menu_get_grey_palette(palette);
        case .FADE_MENU;
            if play.pda { show_menu_screen(fade_palette(menu_get_palette(), 0xF800 - play.fade_step * 0x800)); return; }
            palette = fade_palette(menu_get_grey_palette(palette), 0xF800 - play.fade_step * 0x800);
        case .FADE_IN;
            palette = fade_palette(palette, 0x800 + play.fade_step * 0x800);
    }
    options := game.draw;
    options.palette = *palette;
    show_level(options);
    if play.esc == .MENU || play.esc == .FADE_MENU {
        menu_palette := menu_get_palette();
        if play.esc == .FADE_MENU  menu_palette = fade_palette(menu_palette, 0xF800 - play.fade_step * 0x800);
        show_menu_screen(menu_palette, over_level = true);
    }
}

// The menu's canvas at 4:3 over the window: the whole screen, or over the level.
show_menu_screen :: (palette: Palette, over_level := false) {
    WIDTH, HEIGHT :: 320, 200;
    video, covered := menu_get_video();
    render_size_view(*menu_screen.view, WIDTH, HEIGHT);
    render_update_image(*menu_screen.image, .{WIDTH, HEIGHT, video}, covered);
    pal := palette;
    render_begin_view(*menu_screen.view, *pal, null, .{perspective = false}, transparent = over_level);
    render_set_image(*menu_screen.image);
    render_add_quad(.{-WIDTH / 2, -HEIGHT / 2, 1}, .{WIDTH / 2, HEIGHT / 2, 1}, .{0, 0}, .{WIDTH, HEIGHT}, 31, 0, render_pack_color(.TEXTURE_RAW));

    p0, p1 := get_menu_screen_rect();
    viewport := ImGui.GetMainViewport();
    ImGui.SetNextWindowPos(viewport.Pos);
    ImGui.SetNextWindowSize(viewport.Size);
    ImGui.SetNextWindowViewport(viewport.ID);
    ImGui.PushStyleVar(.WindowPadding, ImVec2.{0, 0});
    ImGui.PushStyleVar(.WindowBorderSize, 0);
    ImGui.PushStyleColor(.WindowBg, ifx over_level then cast(u32) 0 else 0xFF000000);
    flags := ImGuiWindowFlags.NoDecoration | .NoMove | .NoSavedSettings | .NoDocking | .NoInputs | .NoFocusOnAppearing;
    if ImGui.Begin("Menu", flags = flags) {
        draw_list := ImGui.GetWindowDrawList();
        platform := ImGui.GetPlatformIO();
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerNearest);
        draw_list.AddImage(draw_list, .{_TexID = cast(ImTextureID) menu_screen.view.color}, p0, p1);
        draw_list.AddCallback(draw_list, platform.DrawCallback_SetSamplerLinear);
    }
    ImGui.End();
    ImGui.PopStyleColor();
    ImGui.PopStyleVar(2);
}

// Where the 320x200 screen is in the window, at 4:3.
get_menu_screen_rect :: () -> ImVec2, ImVec2 {
    viewport := ImGui.GetMainViewport();
    pixels := ImGui.GetIO().DisplayFramebufferScale;
    size := viewport.Size;
    width, height := get_shown_size(size, pixels, 4.0 / 3.0);
    left := cast(s32) ((size.x * pixels.x - width) / 2);
    top  := cast(s32) ((size.y * pixels.y - height) / 2);
    p0 := ImVec2.{viewport.Pos.x + left / pixels.x, viewport.Pos.y + top / pixels.y};
    return p0, .{p0.x + width / pixels.x, p0.y + height / pixels.y};
}

// The mouse, each frame a menu is up, on the 320x200 screen.
send_menu_mouse :: () {
    x, y: float;
    buttons := SDL_GetMouseState(*x, *y);
    #if DEV  if is_input_ignored()  x, y, buttons = -1000, -1000, 0;
    p0, p1 := get_menu_screen_rect();
    viewport := ImGui.GetMainViewport();
    sx := cast(s32) floor((x - (p0.x - viewport.Pos.x)) * 320 / (p1.x - p0.x));
    sy := cast(s32) floor((y - (p0.y - viewport.Pos.y)) * 200 / (p1.y - p0.y));
    // Either button, as in the original: masks 1 << (button - 1).
    mask := (cast(u32) 1 << (SDL_BUTTON_LEFT - 1)) | (cast(u32) 1 << (SDL_BUTTON_RIGHT - 1));
    // Not a click on the debug panel over the menu.
    pressed := (buttons & mask) != 0 && !is_debug_panel_using_mouse();
    menu_move_mouse(sx, sy, pressed);
    // And the shift keys, which the PDA's Space reads as it takes the key.
    shift := (SDL_GetModState() & SDL_KMOD_SHIFT) != 0;
    #if DEV  if is_input_ignored()  shift = false;
    menu_set_shift_held(shift);
}

// A key for a menu, as the original reads it: the character, or the scan code times 256.
// Characters come from text input (send_menu_text); keys only for what has none.
send_menu_key :: (key: SDL_KeyboardEvent) {
    k := key.key;
    code: s32 = -1;
    if k == SDLK_RETURN || k == SDLK_KP_ENTER  code = KEY_ENTER;
    else if k == SDLK_ESCAPE                    code = KEY_ESCAPE;
    else if k == SDLK_BACKSPACE                 code = KEY_BACKSPACE;
    else if k == SDLK_TAB && (key.mod & SDL_KMOD_ALT)  code = KEY_ALT_TAB;
    else if k == SDLK_TAB                       code = KEY_TAB;
    else if k == SDLK_F1                        code = KEY_F1;
    else if k == SDLK_DELETE                    code = KEY_DELETE;
    else if k == SDLK_UP                        code = KEY_UP;
    else if k == SDLK_DOWN                      code = KEY_DOWN;
    else if k == SDLK_LEFT                      code = KEY_LEFT;
    else if k == SDLK_RIGHT                     code = KEY_RIGHT;
    else if k == SDLK_PAGEUP                    code = KEY_PAGE_UP;
    else if k == SDLK_PAGEDOWN                  code = KEY_PAGE_DOWN;
    if code >= 0  menu_press_key(code);
}

// Typed characters, as the DOS keyboard gives them: only space to '~'.
send_menu_text :: (text: *u8) {
    s := to_string(text);
    for cast([] u8) s  if it >= 0x20 && it <= 0x7E  menu_press_key(it);
}

// Text input on while a menu is up, for the characters.
set_menu_text_input :: (window: *SDL_Window, on: bool) {
    if on == SDL_TextInputActive(window) return;
    if on  SDL_StartTextInput(window);
    else   SDL_StopTextInput(window);
}

// A mission over, by dying with no lives left: back to its briefing.
on_level_failed :: (window: *SDL_Window, in_tools: *bool) {
    stop_level(window, in_tools);
    play.step -= 1;
    begin_step(window);
}

menu_screen: struct {
    view:  View;
    image: Gpu_Image;
};

release_menu_screen :: () {
    render_release_image(*menu_screen.image);
    render_release_view(*menu_screen.view);
}

#scope_file

Step_Kind :: enum u8 { CUTSCENE; BRIEFING; MISSION; END; }

Step :: struct {
    mission: s32;
    kind: Step_Kind;
    scene: s32;
}

// The order: four steps a mission, the ending after the last.
get_step :: (index: s32) -> Step {
    if index < 0 return .{kind = .END};
    if index == MISSION_COUNT * 4  return .{MISSION_COUNT, .CUTSCENE, 1500};
    if index > MISSION_COUNT * 4   return .{kind = .END};
    mission := index / 4 + 1;
    if index % 4 == {
        case 0;  return .{mission, .CUTSCENE, mission * 100};
        case 1;  return .{mission, .BRIEFING, 0};
        case 2;  return .{mission, .MISSION, 0};
    }
    return .{mission, .CUTSCENE, mission * 100 + 50};
}

get_mission_name :: (mission: s32) -> string {
    levels := world_get_level_list();
    if mission < 1 || mission > levels.count return "";
    return levels[mission - 1].name;
}

get_agents_path :: () -> string {
    folder := SDL_GetPrefPath("", "jaidi");
    defer SDL_free(folder);
    return tprint("%DARKPILO.CFG", to_string(folder));
}

get_agent :: () -> *Agent_Record {
    return *agents.records[clamp(current_agent, 0, AGENT_SLOTS - 1)];
}

open_agent_menu :: () {
    if !mission_titles  for world_get_level_list()  array_add(*mission_titles, it.title);
    // Dev builds open every mission, to get to any of them quickly.
    if menu_open_agents(*agents, mission_titles, current_agent, cutscene_get_frame_delay(), all_open = DEV) {
        play.screen = .AGENT_MENU;
    } else {
        // Without the agent menu, the agent chosen plays from its mission.
        play.step = (max(get_agent().selected, 1) - 1) * 4;
        play.screen = .NONE;
    }
}

back_to_agent_menu :: (window: *SDL_Window, in_tools: *bool) {
    if game.playing  stop_level(window, in_tools);
    cutscene_stop();
    menu_close();
    play.esc = .NONE;
    open_agent_menu();
}

// Starts the step the order is at, going past those that show nothing.
begin_step :: (window: *SDL_Window) {
    while true {
        step := get_step(play.step);
        if step.kind == {
            case .END;
                open_agent_menu();
                return;
            case .CUTSCENE;
                if cutscene_start(step.scene, get_clock()) {
                    play.screen = .CUTSCENE;
                    return;
                }
            case .BRIEFING;
                if menu_open_briefing(get_mission_name(step.mission), get_agent().difficulty, cutscene_get_frame_delay()) {
                    play.screen = .BRIEFING;
                    pause_music();
                    return;
                }
            case .MISSION;
                // What the agent takes into it (0x1860d).
                record := get_agent();
                m := clamp(step.mission, 1, AGENT_MISSIONS) - 1;
                world_set_agent_inventory(record.items[m], record.stats[m]);
                if start_level(window, get_mission_name(step.mission), false, record.difficulty) {
                    play.screen = .LEVEL;
                    return;
                }
        }
        play.step += 1;
    }
}

end_play :: (window: *SDL_Window, in_tools: *bool) {
    if game.playing {
        tools := false;
        stop_level(window, ifx in_tools then in_tools else *tools);
    }
    cutscene_stop();
    menu_close();
    play.active = false;
    play.screen = .NONE;
    play.esc = .NONE;
}

// The mission done (0x10867, 0x1999c, 0x1980d, 0x184ba): kept as done at the difficulty
// played, the next one open, the agents saved, and what the agent has now saved as what it
// takes into the next.
record_mission_done :: () {
    record := get_agent();
    mission := get_step(play.step).mission;
    if mission < 1 || mission > MISSION_COUNT return;
    record.completed[mission - 1] = record.difficulty;
    record.next = max(record.next, record.selected + 1);
    if mission < MISSION_COUNT {
        items, stats := world_get_agent_inventory();
        record.items[mission] = items;
        record.stats[mission] = stats;
    }
    agents_save(*agents, get_agents_path());
}

// The Esc menu's fades, a step a game tick (0x4ff50), and its answer.
update_esc_menu :: (window: *SDL_Window, in_tools: *bool, running: *bool) {
    if play.esc == .NONE return;
    now := get_clock();
    TICK_NS :: cast(u64) (1_000_000_000.0 * 8192.0 / 1193182.0);
    if play.esc == .FADE_OUT || play.esc == .FADE_MENU || play.esc == .FADE_IN {
        while play.esc != .MENU && play.esc != .NONE && now >= play.fade_next_ns {
            play.fade_next_ns += TICK_NS;
            play.fade_step += 1;
            if play.fade_step < 32 continue;
            play.fade_step = 0;
            if play.esc == {
                case .FADE_OUT;
                    play.esc = .MENU;
                    pause_music();
                    SDL_SetWindowRelativeMouseMode(window, false);
                    opened := ifx play.pda then menu_open_pda(get_pda_source(), cutscene_get_frame_delay())
                              else menu_open_esc(world_is_mission_complete(), cutscene_get_frame_delay());
                    if !opened {
                        play.esc = .FADE_IN;
                        resume_music();
                    }
                case .FADE_MENU;
                    play.esc = .FADE_IN;
                case .FADE_IN;
                    play.esc = .NONE;
                    game.mouse_x, game.mouse_y = 0, 0;
            }
        }
        return;
    }
    result := menu_update(now);
    if result == MENU_NO_RESULT return;
    menu_close();
    resume_music();
    // The PDA has only the way back.
    if play.pda || result == xx Esc_Result.RETURN {
        // Back by fades: the menu out, the game in (0x19a6d).
        play.esc = .FADE_MENU;
        play.fade_step = 0;
        play.fade_next_ns = now;
        set_mouse_captured(window, true);
        return;
    }
    play.esc = .NONE;
    // A level from the tools: its way out goes back to them, or quits.
    if !play.active {
        stop_level(window, in_tools);
        if result == xx Esc_Result.QUIT  running.* = false;
        return;
    }
    complete := world_is_mission_complete();
    if result == {
        case xx Esc_Result.NEXT;
            // On to the cutscene after it.
            record_mission_done();
            stop_level(window, in_tools);
            play.step += 1;
            begin_step(window);
        case xx Esc_Result.ABORT;
            back_to_agent_menu(window, in_tools);
        case xx Esc_Result.QUIT;
            // A mission complete still counts.
            if complete  record_mission_done();
            end_play(window, in_tools);
            running.* = false;
    }
}

// What the PDA shows of the level: its goals, secrets, what the agent has, the map.
get_pda_source :: () -> Pda_Source {
    source := Pda_Source.{
        level = world_get_name(),
        is_goal_done = world_is_goal_complete,
        secrets_percent = world_get_secrets_percent(),
        draw_map = world_draw_automap_for_pda,
        send_map_message = (message: s32) { world_send_automap_message(xx message); },
    };
    agent := world_get_agent();
    has :: (agent: *Agent, slot: Item_Slot) -> bool { return agent.items[slot] != 0; }
    // The guns frames' order (0x2f880).
    source.weapons = .[
        has(agent, .PISTOL), has(agent, .RIFLE), agent.ammo[Ammo.DETONATOR] != 0,
        has(agent, .AUTOGUN), has(agent, .FUSION), agent.ammo[Ammo.MINE] != 0,
        has(agent, .MORTAR), has(agent, .CONCUSSION), has(agent, .CANNON),
    ];
    // The items frames' order (0x2f940): slots 8 to 15, then 18, 16, 17, 19 to 24.
    ITEM_FRAMES :: s32.[8, 9, 10, 11, 12, 13, 14, 15, 18, 16, 17, 19, 20, 21, 22, 23, 24];
    for ITEM_FRAMES  source.items[it_index] = agent.items[it] != 0;
    return source;
}

// The DAC's 6-bit colors scaled by a brightness in 16.16, as the original's fade does.
fade_palette :: (palette: Palette, brightness: s32) -> Palette {
    result: Palette;
    for palette.colors {
        scale :: (v: u8, b: s32) -> u8 { return expand_6_bit(cast(u8) (((cast(s32) (v >> 2)) * b) >> 16)); }
        result.colors[it_index] = .{scale(it.r, brightness), scale(it.g, brightness), scale(it.b, brightness)};
    }
    return result;
}

// Music stops and goes silent while a menu is up (0x1a32c, 0x19c94).
pause_music :: () {
    audio_lock();
    if play.saved_music_volume < 0  play.saved_music_volume = imuse_get_music_volume();
    imuse_set_music_volume(0);
    imuse_pause();
    audio_unlock();
}

resume_music :: () {
    audio_lock();
    imuse_resume();
    if play.saved_music_volume >= 0  imuse_set_music_volume(play.saved_music_volume);
    play.saved_music_volume = -1;
    audio_unlock();
}

#import "Math";
#import "engine/dfMenu";
#import "engine/dfAgents";
