// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Native-Jai port of Dear ImGui's SDL3 platform backend (imgui_impl_sdl3.cpp,
// version 1.92.8-docking). Paired with the SDL_GPU renderer backend in
// imgui_impl_sdlgpu3.jai.
//
// Scope: full upstream backend — clipboard, keyboard map, mouse
// (position/buttons/wheel/source), system mouse cursors, text input/IME, window
// focus/move/resize, gamepad input, monitor enumeration, and the multi-viewport
// platform interface (docking + viewports).

#scope_module

FLT_MAX : float : 3.4028235e38; // matches C FLT_MAX (the ImGui mouse-left sentinel)

// The main-thread context, captured at Init, so the #c_call callbacks ImGui
// invokes (viewport create/destroy, renderer render-window) can push a real
// context before calling into native Jai (allocation, asserts, etc.).
g_context: #Context;

ImGui_ImplSDL3_Data :: struct {
    Window:                 *SDL_Window;
    WindowID:               SDL_WindowID;
    Time:                   Uint64;
    BackendPlatformName:    [64] u8;
    ClipboardTextData:      *u8;
    WantUpdateMonitors:     bool;
    MouseWindowID:          SDL_WindowID;
    MouseButtonsDown:       int;
    MouseCursors:           [ImGuiMouseCursor.COUNT] *SDL_Cursor;
    MouseLastCursor:        *SDL_Cursor;
    MousePendingLeaveFrame: int;
    MouseCanUseGlobalState: bool;
    MouseCaptureMode:       Mouse_Capture_Mode;
    MouseCanReportHoveredViewport: bool; // ImGuiBackendFlags_HasMouseHoveredViewport set dynamically per-frame

    // IME handling
    ImeWindow:              *SDL_Window;
    ImeData:                ImGuiPlatformImeData;
    ImeDirty:               bool;

    // Gamepad handling
    Gamepads:               [..] *SDL_Gamepad;
    GamepadMode:            Gamepad_Mode;
    WantUpdateGamepadsList: bool;
}

Gamepad_Mode :: enum {
    MANUAL;
    AUTO_FIRST;
    AUTO_ALL;
}

// Whether/when to SDL_CaptureMouse() so drags continue when the cursor leaves the
// window (e.g. dragging a viewport window's title bar fast). X11 debuggers behave
// badly with eager capture, so there we only capture once an actual drag starts.
Mouse_Capture_Mode :: enum {
    DISABLED;
    ENABLED;
    ENABLED_AFTER_DRAG;
}

// Per-viewport platform data, stored in viewport.PlatformUserData.
ImGui_ImplSDL3_ViewportData :: struct {
    Window:       *SDL_Window;
    ParentWindow: *SDL_Window;
    WindowID:     SDL_WindowID;
    WindowOwned:  bool;
}

get_platform_data :: () -> *ImGui_ImplSDL3_Data #c_call {
    if ImGui.GetCurrentContext() then return cast(*ImGui_ImplSDL3_Data) ImGui.GetIO().BackendPlatformUserData;
    return null;
}

// Works for the main window and secondary viewport windows (each stores its
// SDL_WindowID in viewport.PlatformHandle via setup_platform_handles).
viewport_for_window_id :: (window_id: SDL_WindowID) -> *ImGuiViewport #c_call {
    return ImGui.FindViewportByPlatformHandle(cast(*void)(cast(u64) window_id));
}

get_sdl_window_from_viewport :: (viewport: *ImGuiViewport) -> *SDL_Window #c_call {
    if viewport  return SDL_GetWindowFromID(cast(SDL_WindowID)(cast(u64) viewport.PlatformHandle));
    return null;
}

// --- Clipboard ---

get_clipboard_text :: (ctx: *ImGuiContext) -> *u8 #c_call {
    bd := get_platform_data();
    if bd.ClipboardTextData  SDL_free(bd.ClipboardTextData);
    if SDL_HasClipboardText() then bd.ClipboardTextData = SDL_GetClipboardText();
    else                           bd.ClipboardTextData = null;
    return bd.ClipboardTextData;
}

set_clipboard_text :: (ctx: *ImGuiContext, text: *u8) #c_call {
    SDL_SetClipboardText(text);
}

open_in_shell :: (ctx: *ImGuiContext, url: *u8) -> bool #c_call {
    return SDL_OpenURL(url);
}

// --- IME ---

platform_set_ime_data :: (ctx: *ImGuiContext, viewport: *ImGuiViewport, data: *ImGuiPlatformImeData) #c_call {
    bd := get_platform_data();
    bd.ImeData = data.*;
    bd.ImeDirty = true;
    push_context g_context {
        update_ime();
    }
}

update_ime :: () {
    bd := get_platform_data();
    data := *bd.ImeData;
    window := SDL_GetKeyboardFocus();

    if (!(data.WantVisible || data.WantTextInput) || bd.ImeWindow != window) && bd.ImeWindow != null {
        SDL_StopTextInput(bd.ImeWindow);
        bd.ImeWindow = null;
    }
    if (!bd.ImeDirty && bd.ImeWindow == window) || window == null  return;

    bd.ImeDirty = false;
    if data.WantVisible {
        viewport_pos: ImVec2;
        vp := viewport_for_window_id(SDL_GetWindowID(window));
        if vp  viewport_pos = vp.Pos;
        r: SDL_Rect;
        r.x = cast(s32)(data.InputPos.x - viewport_pos.x);
        r.y = cast(s32)(data.InputPos.y - viewport_pos.y);
        r.w = 1;
        r.h = cast(s32) data.InputLineHeight;
        SDL_SetTextInputArea(window, *r, 0);
        bd.ImeWindow = window;
    }
    if !SDL_TextInputActive(window) && (data.WantVisible || data.WantTextInput)  SDL_StartTextInput(window);
}

// --- Keyboard map ---

key_event_to_imgui_key :: (keycode: SDL_Keycode, scancode: SDL_Scancode) -> ImGuiKey {
    // Keypad doesn't have individual keycodes in SDL3 — switch on scancode first.
    if scancode == {
        case .KP_0;        return .Keypad0;
        case .KP_1;        return .Keypad1;
        case .KP_2;        return .Keypad2;
        case .KP_3;        return .Keypad3;
        case .KP_4;        return .Keypad4;
        case .KP_5;        return .Keypad5;
        case .KP_6;        return .Keypad6;
        case .KP_7;        return .Keypad7;
        case .KP_8;        return .Keypad8;
        case .KP_9;        return .Keypad9;
        case .KP_PERIOD;   return .KeypadDecimal;
        case .KP_DIVIDE;   return .KeypadDivide;
        case .KP_MULTIPLY; return .KeypadMultiply;
        case .KP_MINUS;    return .KeypadSubtract;
        case .KP_PLUS;     return .KeypadAdd;
        case .KP_ENTER;    return .KeypadEnter;
        case .KP_EQUALS;   return .KeypadEqual;
    }
    if keycode == {
        case SDLK_TAB;          return .Tab;
        case SDLK_LEFT;         return .LeftArrow;
        case SDLK_RIGHT;        return .RightArrow;
        case SDLK_UP;           return .UpArrow;
        case SDLK_DOWN;         return .DownArrow;
        case SDLK_PAGEUP;       return .PageUp;
        case SDLK_PAGEDOWN;     return .PageDown;
        case SDLK_HOME;         return .Home;
        case SDLK_END;          return .End;
        case SDLK_INSERT;       return .Insert;
        case SDLK_DELETE;       return .Delete;
        case SDLK_BACKSPACE;    return .Backspace;
        case SDLK_SPACE;        return .Space;
        case SDLK_RETURN;       return .Enter;
        case SDLK_ESCAPE;       return .Escape;
        case SDLK_COMMA;        return .Comma;
        case SDLK_PERIOD;       return .Period;
        case SDLK_SEMICOLON;    return .Semicolon;
        case SDLK_CAPSLOCK;     return .CapsLock;
        case SDLK_SCROLLLOCK;   return .ScrollLock;
        case SDLK_NUMLOCKCLEAR; return .NumLock;
        case SDLK_PRINTSCREEN;  return .PrintScreen;
        case SDLK_PAUSE;        return .Pause;
        case SDLK_LCTRL;        return .LeftCtrl;
        case SDLK_LSHIFT;       return .LeftShift;
        case SDLK_LALT;         return .LeftAlt;
        case SDLK_LGUI;         return .LeftSuper;
        case SDLK_RCTRL;        return .RightCtrl;
        case SDLK_RSHIFT;       return .RightShift;
        case SDLK_RALT;         return .RightAlt;
        case SDLK_RGUI;         return .RightSuper;
        case SDLK_APPLICATION;  return .Menu;
        case SDLK_0;            return ._0;
        case SDLK_1;            return ._1;
        case SDLK_2;            return ._2;
        case SDLK_3;            return ._3;
        case SDLK_4;            return ._4;
        case SDLK_5;            return ._5;
        case SDLK_6;            return ._6;
        case SDLK_7;            return ._7;
        case SDLK_8;            return ._8;
        case SDLK_9;            return ._9;
        case SDLK_A;            return .A;
        case SDLK_B;            return .B;
        case SDLK_C;            return .C;
        case SDLK_D;            return .D;
        case SDLK_E;            return .E;
        case SDLK_F;            return .F;
        case SDLK_G;            return .G;
        case SDLK_H;            return .H;
        case SDLK_I;            return .I;
        case SDLK_J;            return .J;
        case SDLK_K;            return .K;
        case SDLK_L;            return .L;
        case SDLK_M;            return .M;
        case SDLK_N;            return .N;
        case SDLK_O;            return .O;
        case SDLK_P;            return .P;
        case SDLK_Q;            return .Q;
        case SDLK_R;            return .R;
        case SDLK_S;            return .S;
        case SDLK_T;            return .T;
        case SDLK_U;            return .U;
        case SDLK_V;            return .V;
        case SDLK_W;            return .W;
        case SDLK_X;            return .X;
        case SDLK_Y;            return .Y;
        case SDLK_Z;            return .Z;
        case SDLK_F1;           return .F1;
        case SDLK_F2;           return .F2;
        case SDLK_F3;           return .F3;
        case SDLK_F4;           return .F4;
        case SDLK_F5;           return .F5;
        case SDLK_F6;           return .F6;
        case SDLK_F7;           return .F7;
        case SDLK_F8;           return .F8;
        case SDLK_F9;           return .F9;
        case SDLK_F10;          return .F10;
        case SDLK_F11;          return .F11;
        case SDLK_F12;          return .F12;
        case SDLK_F13;          return .F13;
        case SDLK_F14;          return .F14;
        case SDLK_F15;          return .F15;
        case SDLK_F16;          return .F16;
        case SDLK_F17;          return .F17;
        case SDLK_F18;          return .F18;
        case SDLK_F19;          return .F19;
        case SDLK_F20;          return .F20;
        case SDLK_F21;          return .F21;
        case SDLK_F22;          return .F22;
        case SDLK_F23;          return .F23;
        case SDLK_F24;          return .F24;
        case SDLK_AC_BACK;      return .AppBack;
        case SDLK_AC_FORWARD;   return .AppForward;
    }
    // Fallback to scancode for layout-dependent OEM keys.
    if scancode == {
        case .GRAVE;          return .GraveAccent;
        case .MINUS;          return .Minus;
        case .EQUALS;         return .Equal;
        case .LEFTBRACKET;    return .LeftBracket;
        case .RIGHTBRACKET;   return .RightBracket;
        case .NONUSBACKSLASH; return .Oem102;
        case .BACKSLASH;      return .Backslash;
        case .SEMICOLON;      return .Semicolon;
        case .APOSTROPHE;     return .Apostrophe;
        case .COMMA;          return .Comma;
        case .PERIOD;         return .Period;
        case .SLASH;          return .Slash;
    }
    return .None;
}

update_key_modifiers :: (sdl_key_mods: SDL_Keymod) {
    io := ImGui.GetIO();
    io.AddKeyEvent(io,.ImGuiMod_Ctrl,  (sdl_key_mods & SDL_KMOD_CTRL)  != 0);
    io.AddKeyEvent(io,.ImGuiMod_Shift, (sdl_key_mods & SDL_KMOD_SHIFT) != 0);
    io.AddKeyEvent(io,.ImGuiMod_Alt,   (sdl_key_mods & SDL_KMOD_ALT)   != 0);
    io.AddKeyEvent(io,.ImGuiMod_Super, (sdl_key_mods & SDL_KMOD_GUI)   != 0);
}

ImGui_ImplSDL3_ProcessEvent :: (event: *SDL_Event) -> bool {
    bd := get_platform_data();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplSDL3_Init()?");
    io := ImGui.GetIO();

    etype := cast(SDL_EventType) event.type;
    if etype == {
        case .MOUSE_MOTION;
            if viewport_for_window_id(event.motion.windowID) == null  return false;
            mouse_x := event.motion.x;
            mouse_y := event.motion.y;
            if io.ConfigFlags & .ViewportsEnable {
                // Multi-viewport: report mouse position in OS-desktop coordinates.
                wx, wy: s32;
                SDL_GetWindowPosition(SDL_GetWindowFromID(event.motion.windowID), *wx, *wy);
                mouse_x += cast(float) wx;
                mouse_y += cast(float) wy;
            }
            source: ImGuiMouseSource = ifx event.motion.which == SDL_TOUCH_MOUSEID then ImGuiMouseSource.TouchScreen else .Mouse;
            io.AddMouseSourceEvent(io, source);
            io.AddMousePosEvent(io, mouse_x, mouse_y);
            return true;

        case .MOUSE_WHEEL;
            if viewport_for_window_id(event.wheel.windowID) == null  return false;
            source: ImGuiMouseSource = ifx event.wheel.which == SDL_TOUCH_MOUSEID then ImGuiMouseSource.TouchScreen else .Mouse;
            io.AddMouseSourceEvent(io, source);
            io.AddMouseWheelEvent(io, -event.wheel.x, event.wheel.y);
            return true;

        case .MOUSE_BUTTON_DOWN; #through;
        case .MOUSE_BUTTON_UP;
            if viewport_for_window_id(event.button.windowID) == null  return false;
            mouse_button := -1;
            if event.button.button == SDL_BUTTON_LEFT    mouse_button = 0;
            if event.button.button == SDL_BUTTON_RIGHT   mouse_button = 1;
            if event.button.button == SDL_BUTTON_MIDDLE  mouse_button = 2;
            if event.button.button == SDL_BUTTON_X1      mouse_button = 3;
            if event.button.button == SDL_BUTTON_X2      mouse_button = 4;
            if mouse_button == -1  return false;
            source: ImGuiMouseSource = ifx event.button.which == SDL_TOUCH_MOUSEID then ImGuiMouseSource.TouchScreen else .Mouse;
            down := etype == .MOUSE_BUTTON_DOWN;
            io.AddMouseSourceEvent(io, source);
            io.AddMouseButtonEvent(io, cast(s32) mouse_button, down);
            bd.MouseButtonsDown = ifx down then (bd.MouseButtonsDown | (1 << mouse_button)) else (bd.MouseButtonsDown & ~(1 << mouse_button));
            return true;

        case .TEXT_INPUT;
            if viewport_for_window_id(event.text.windowID) == null  return false;
            io.AddInputCharactersUTF8(io, event.text.text);
            return true;

        case .KEY_DOWN; #through;
        case .KEY_UP;
            if viewport_for_window_id(event.key.windowID) == null  return false;
            update_key_modifiers(event.key.mod);
            key := key_event_to_imgui_key(event.key.key, event.key.scancode);
            down := etype == .KEY_DOWN;
            io.AddKeyEvent(io,key, down);
            io.SetKeyEventNativeData(io, key, cast(s32) event.key.key, cast(s32) event.key.scancode, cast(s32) event.key.scancode);
            return true;

        case .WINDOW_MOUSE_ENTER;
            if viewport_for_window_id(event.window.windowID) == null  return false;
            bd.MouseWindowID = event.window.windowID;
            bd.MousePendingLeaveFrame = 0;
            return true;

        case .WINDOW_MOUSE_LEAVE;
            if viewport_for_window_id(event.window.windowID) == null  return false;
            bd.MousePendingLeaveFrame = ImGui.GetFrameCount() + 1;
            return true;

        case .WINDOW_FOCUS_GAINED; #through;
        case .WINDOW_FOCUS_LOST;
            if viewport_for_window_id(event.window.windowID) == null  return false;
            io.AddFocusEvent(io, etype == .WINDOW_FOCUS_GAINED);
            return true;

        case .WINDOW_CLOSE_REQUESTED; #through;
        case .WINDOW_MOVED; #through;
        case .WINDOW_RESIZED;
            vp := viewport_for_window_id(event.window.windowID);
            if vp == null  return false;
            if etype == .WINDOW_CLOSE_REQUESTED  vp.PlatformRequestClose  = true;
            if etype == .WINDOW_MOVED            vp.PlatformRequestMove   = true;
            if etype == .WINDOW_RESIZED          vp.PlatformRequestResize = true;
            return true;

        case .DISPLAY_ORIENTATION;           #through;
        case .DISPLAY_ADDED;                 #through;
        case .DISPLAY_REMOVED;               #through;
        case .DISPLAY_MOVED;                 #through;
        case .DISPLAY_CONTENT_SCALE_CHANGED;
            bd.WantUpdateMonitors = true;
            return true;

        case .GAMEPAD_ADDED;   #through;
        case .GAMEPAD_REMOVED;
            bd.WantUpdateGamepadsList = true;
            return true;
    }
    return false;
}

setup_platform_handles :: (viewport: *ImGuiViewport, window: *SDL_Window) #c_call {
    viewport.PlatformHandle = cast(*void)(cast(u64) SDL_GetWindowID(window));
    viewport.PlatformHandleRaw = null;
    #if OS == .WINDOWS {
        viewport.PlatformHandleRaw = SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_WIN32_HWND_POINTER.data, null);
    }
}

ImGui_ImplSDL3_Init :: (window: *SDL_Window) -> bool {
    g_context = context;

    io := ImGui.GetIO();
    assert(io.BackendPlatformUserData == null, "Already initialized a platform backend!");

    bd := New(ImGui_ImplSDL3_Data);
    io.BackendPlatformUserData = bd;

    // Backend name with linked SDL version, e.g. "imgui_impl_sdl3 (SDL 3.4.8)".
    ver := SDL_GetVersion();
    name := tprint("imgui_impl_sdl3 (SDL %.%.%)", ver / 1000000, (ver / 1000) % 1000, ver % 1000);
    n := min(name.count, bd.BackendPlatformName.count - 1);
    memcpy(bd.BackendPlatformName.data, name.data, n);
    bd.BackendPlatformName[n] = 0;
    io.BackendPlatformName = bd.BackendPlatformName.data;

    io.BackendFlags |= .HasMouseCursors;
    io.BackendFlags |= .HasSetMousePos;

    bd.Window   = window;
    bd.WindowID = SDL_GetWindowID(window);
    bd.WantUpdateMonitors = true;

    // Only some SDL video drivers support SDL_GetGlobalMouseState()/SDL_CaptureMouse().
    // Whitelist them (matches upstream); x11 captures only after a drag begins.
    bd.MouseCanUseGlobalState = false;
    bd.MouseCaptureMode = .DISABLED;
    sdl_backend := to_string(SDL_GetCurrentVideoDriver());
    if sdl_backend == "windows" || sdl_backend == "cocoa" || sdl_backend == "DIVE" || sdl_backend == "VMAN" {
        bd.MouseCanUseGlobalState = true;
        bd.MouseCaptureMode = .ENABLED;
    } else if sdl_backend == "x11" {
        bd.MouseCanUseGlobalState = true;
        bd.MouseCaptureMode = .ENABLED_AFTER_DRAG;
    }

    // SDL on Linux/macOS doesn't report events for unfocused windows (#4960), so we
    // set HasMouseHoveredViewport dynamically each frame based on this.
    #if OS == .MACOS {
        bd.MouseCanReportHoveredViewport = false;
    } else {
        bd.MouseCanReportHoveredViewport = bd.MouseCanUseGlobalState;
    }

    bd.GamepadMode = .AUTO_FIRST;
    bd.WantUpdateGamepadsList = true;

    // Multi-viewports, with parent/child, only where windows have desktop positions and the
    // global mouse state is known: Wayland has neither, so there ImGui keeps every window
    // inside the main one (as upstream).
    if bd.MouseCanUseGlobalState {
        io.BackendFlags |= .PlatformHasViewports;
        io.BackendFlags |= .HasParentViewport;
    }

    platform_io := ImGui.GetPlatformIO();
    platform_io.Platform_SetClipboardTextFn = set_clipboard_text;
    platform_io.Platform_GetClipboardTextFn = get_clipboard_text;
    platform_io.Platform_SetImeDataFn = platform_set_ime_data;
    platform_io.Platform_OpenInShellFn = open_in_shell;

    update_monitors();

    bd.MouseCursors[ImGuiMouseCursor.Arrow]      = SDL_CreateSystemCursor(.DEFAULT);
    bd.MouseCursors[ImGuiMouseCursor.TextInput]  = SDL_CreateSystemCursor(.TEXT);
    bd.MouseCursors[ImGuiMouseCursor.ResizeAll]  = SDL_CreateSystemCursor(.MOVE);
    bd.MouseCursors[ImGuiMouseCursor.ResizeNS]   = SDL_CreateSystemCursor(.NS_RESIZE);
    bd.MouseCursors[ImGuiMouseCursor.ResizeEW]   = SDL_CreateSystemCursor(.EW_RESIZE);
    bd.MouseCursors[ImGuiMouseCursor.ResizeNESW] = SDL_CreateSystemCursor(.NESW_RESIZE);
    bd.MouseCursors[ImGuiMouseCursor.ResizeNWSE] = SDL_CreateSystemCursor(.NWSE_RESIZE);
    bd.MouseCursors[ImGuiMouseCursor.Hand]       = SDL_CreateSystemCursor(.POINTER);
    bd.MouseCursors[ImGuiMouseCursor.Wait]       = SDL_CreateSystemCursor(.WAIT);
    bd.MouseCursors[ImGuiMouseCursor.Progress]   = SDL_CreateSystemCursor(.PROGRESS);
    bd.MouseCursors[ImGuiMouseCursor.NotAllowed] = SDL_CreateSystemCursor(.NOT_ALLOWED);

    main_viewport := ImGui.GetMainViewport();
    setup_platform_handles(main_viewport, window);

    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    SDL_SetHint(SDL_HINT_MOUSE_AUTO_CAPTURE, "0");
    SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "0");

    platform_init_multi_viewport_support(window);

    return true;
}

ImGui_ImplSDL3_InitForSDLGPU :: (window: *SDL_Window) -> bool {
    return ImGui_ImplSDL3_Init(window);
}

ImGui_ImplSDL3_Shutdown :: () {
    bd := get_platform_data();
    assert(bd != null, "No platform backend to shutdown, or already shutdown?");
    io := ImGui.GetIO();
    platform_io := ImGui.GetPlatformIO();

    platform_shutdown_multi_viewport_support();

    if bd.ClipboardTextData  SDL_free(bd.ClipboardTextData);
    for 0..ImGuiMouseCursor.COUNT - 1  SDL_DestroyCursor(bd.MouseCursors[it]);
    close_gamepads();
    array_free(bd.Gamepads);

    io.BackendPlatformName = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags &= ~(ImGuiBackendFlags.HasMouseCursors | .HasSetMousePos | .HasGamepad | .PlatformHasViewports | .HasParentViewport | .HasMouseHoveredViewport);
    platform_io.ClearPlatformHandlers(platform_io);
    free(bd);
}

update_mouse_data :: () {
    bd := get_platform_data();
    io := ImGui.GetIO();

    // Keep the mouse captured while a button is held so drags (e.g. dragging a
    // viewport window's title bar) continue even when the cursor leaves the window.
    if bd.MouseCaptureMode == .ENABLED {
        SDL_CaptureMouse(bd.MouseButtonsDown != 0);
    } else if bd.MouseCaptureMode == .ENABLED_AFTER_DRAG {
        want_capture := false;
        for button_n: 0..4 {
            if ImGui.IsMouseDragging(cast(ImGuiMouseButton) button_n, 1.0) { want_capture = true; break; }
        }
        SDL_CaptureMouse(want_capture);
    }

    focused_window := SDL_GetKeyboardFocus();
    is_app_focused := focused_window != null && (focused_window == bd.Window || viewport_for_window_id(SDL_GetWindowID(focused_window)) != null);

    if is_app_focused {
        if io.WantSetMousePos  SDL_WarpMouseInWindow(bd.Window, io.MousePos.x, io.MousePos.y);

        hovered_window := SDL_GetMouseFocus();
        is_relative := SDL_GetWindowRelativeMouseMode(bd.Window);
        if hovered_window == null && bd.MouseCanUseGlobalState && bd.MouseButtonsDown == 0 && !is_relative {
            mouse_x, mouse_y: float;
            SDL_GetGlobalMouseState(*mouse_x, *mouse_y);
            // Single-viewport: client coords. Multi-viewport: absolute desktop coords.
            if !(io.ConfigFlags & .ViewportsEnable) {
                window_x, window_y: s32;
                SDL_GetWindowPosition(focused_window, *window_x, *window_y);
                mouse_x -= cast(float) window_x;
                mouse_y -= cast(float) window_y;
            }
            io.AddMousePosEvent(io, mouse_x, mouse_y);
        }
    }

    // (Multi-viewport) Report the viewport the OS mouse cursor is over, so ImGui
    // doesn't have to fall back to its heuristic to find the hovered viewport.
    if io.BackendFlags & .HasMouseHoveredViewport {
        mouse_viewport_id: ImGuiID = 0;
        mouse_viewport := viewport_for_window_id(bd.MouseWindowID);
        if mouse_viewport  mouse_viewport_id = mouse_viewport.ID;
        io.AddMouseViewportEvent(io, mouse_viewport_id);
    }
}

update_mouse_cursor :: () {
    io := ImGui.GetIO();
    if io.ConfigFlags & .NoMouseCursorChange  return;
    bd := get_platform_data();

    imgui_cursor := ImGui.GetMouseCursor();
    if io.MouseDrawCursor || imgui_cursor == .None {
        SDL_HideCursor();
    } else {
        expected := bd.MouseCursors[cast(int) imgui_cursor];
        if !expected  expected = bd.MouseCursors[ImGuiMouseCursor.Arrow];
        if bd.MouseLastCursor != expected {
            SDL_SetCursor(expected);
            bd.MouseLastCursor = expected;
        }
        SDL_ShowCursor();
    }
}

window_size_and_framebuffer_scale :: (window: *SDL_Window, out_size: *ImVec2, out_fb_scale: *ImVec2) #c_call {
    w, h: s32;
    SDL_GetWindowSize(window, *w, *h);
    if SDL_GetWindowFlags(window) & SDL_WINDOW_MINIMIZED { w = 0; h = 0; }

    display_w, display_h: s32;
    SDL_GetWindowSizeInPixels(window, *display_w, *display_h);
    fb_scale_x := ifx w > 0 then cast(float) display_w / cast(float) w else 1.0;
    fb_scale_y := ifx h > 0 then cast(float) display_h / cast(float) h else 1.0;

    if out_size      out_size.*     = .{cast(float) w, cast(float) h};
    if out_fb_scale  out_fb_scale.* = .{fb_scale_x, fb_scale_y};
}

ImGui_ImplSDL3_NewFrame :: () {
    bd := get_platform_data();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplSDL3_Init()?");
    io := ImGui.GetIO();

    window_size_and_framebuffer_scale(bd.Window, *io.DisplaySize, *io.DisplayFramebufferScale);

    if bd.WantUpdateMonitors  update_monitors();

    frequency := SDL_GetPerformanceFrequency();
    current_time := SDL_GetPerformanceCounter();
    if current_time <= bd.Time  current_time = bd.Time + 1;
    io.DeltaTime = ifx bd.Time > 0 then cast(float)(cast(float64)(current_time - bd.Time) / cast(float64) frequency) else cast(float)(1.0 / 60.0);
    bd.Time = current_time;

    if bd.MousePendingLeaveFrame && bd.MousePendingLeaveFrame >= ImGui.GetFrameCount() && bd.MouseButtonsDown == 0 {
        bd.MouseWindowID = 0;
        bd.MousePendingLeaveFrame = 0;
        io.AddMousePosEvent(io, -FLT_MAX, -FLT_MAX);
    }

    // Our io.AddMouseViewportEvent() calls (in update_mouse_data) are only valid
    // when we can reliably report the hovered viewport and aren't mid drag-drop.
    if bd.MouseCanReportHoveredViewport && ImGui.GetDragDropPayload() == null {
        io.BackendFlags |= .HasMouseHoveredViewport;
    } else {
        io.BackendFlags &= ~ImGuiBackendFlags.HasMouseHoveredViewport;
    }

    update_mouse_data();
    update_mouse_cursor();
    update_ime();
    update_gamepads();
}

// --- Gamepad ---

close_gamepads :: () {
    bd := get_platform_data();
    if bd.GamepadMode != .MANUAL  for bd.Gamepads  SDL_CloseGamepad(it);
    bd.Gamepads.count = 0; // mirrors ImGui's Gamepads.resize(0) (keeps capacity)
}

update_gamepad_button :: (bd: *ImGui_ImplSDL3_Data, io: *ImGuiIO, key: ImGuiKey, button_no: SDL_GamepadButton) {
    merged := false;
    for bd.Gamepads  merged = merged || SDL_GetGamepadButton(it, button_no);
    io.AddKeyEvent(io, key, merged);
}

saturate :: (v: float) -> float {
    if v < 0.0  return 0.0;
    if v > 1.0  return 1.0;
    return v;
}

update_gamepad_analog :: (bd: *ImGui_ImplSDL3_Data, io: *ImGuiIO, key: ImGuiKey, axis_no: SDL_GamepadAxis, v0: float, v1: float) {
    merged := 0.0;
    for bd.Gamepads {
        raw := cast(float) SDL_GetGamepadAxis(it, axis_no);
        vn := saturate((raw - v0) / (v1 - v0));
        if merged < vn  merged = vn;
    }
    io.AddKeyAnalogEvent(io, key, merged > 0.1, merged);
}

update_gamepads :: () {
    io := ImGui.GetIO();
    bd := get_platform_data();

    if bd.WantUpdateGamepadsList && bd.GamepadMode != .MANUAL {
        close_gamepads();
        count: s32;
        sdl_gamepads := SDL_GetGamepads(*count);
        defer SDL_free(sdl_gamepads);
        for n: 0..count - 1 {
            gamepad := SDL_OpenGamepad(sdl_gamepads[n]);
            if gamepad {
                array_add(*bd.Gamepads, gamepad);
                if bd.GamepadMode == .AUTO_FIRST  break;
            }
        }
        bd.WantUpdateGamepadsList = false;
    }

    io.BackendFlags &= ~ImGuiBackendFlags.HasGamepad;
    if bd.Gamepads.count == 0  return;
    io.BackendFlags |= .HasGamepad;

    thumb_dead_zone: float = 8000.0; // SDL_gamepad.h suggests this value.
    update_gamepad_button(bd, io, .GamepadStart,       .START);
    update_gamepad_button(bd, io, .GamepadBack,        .BACK);
    update_gamepad_button(bd, io, .GamepadFaceLeft,    .WEST);   // Xbox X, PS Square
    update_gamepad_button(bd, io, .GamepadFaceRight,   .EAST);   // Xbox B, PS Circle
    update_gamepad_button(bd, io, .GamepadFaceUp,      .NORTH);  // Xbox Y, PS Triangle
    update_gamepad_button(bd, io, .GamepadFaceDown,    .SOUTH);  // Xbox A, PS Cross
    update_gamepad_button(bd, io, .GamepadDpadLeft,    .DPAD_LEFT);
    update_gamepad_button(bd, io, .GamepadDpadRight,   .DPAD_RIGHT);
    update_gamepad_button(bd, io, .GamepadDpadUp,      .DPAD_UP);
    update_gamepad_button(bd, io, .GamepadDpadDown,    .DPAD_DOWN);
    update_gamepad_button(bd, io, .GamepadL1,          .LEFT_SHOULDER);
    update_gamepad_button(bd, io, .GamepadR1,          .RIGHT_SHOULDER);
    update_gamepad_analog(bd, io, .GamepadL2,          .LEFT_TRIGGER,  0.0, 32767.0);
    update_gamepad_analog(bd, io, .GamepadR2,          .RIGHT_TRIGGER, 0.0, 32767.0);
    update_gamepad_button(bd, io, .GamepadL3,          .LEFT_STICK);
    update_gamepad_button(bd, io, .GamepadR3,          .RIGHT_STICK);
    update_gamepad_analog(bd, io, .GamepadLStickLeft,  .LEFTX,  -thumb_dead_zone, -32768.0);
    update_gamepad_analog(bd, io, .GamepadLStickRight, .LEFTX,  +thumb_dead_zone, +32767.0);
    update_gamepad_analog(bd, io, .GamepadLStickUp,    .LEFTY,  -thumb_dead_zone, -32768.0);
    update_gamepad_analog(bd, io, .GamepadLStickDown,  .LEFTY,  +thumb_dead_zone, +32767.0);
    update_gamepad_analog(bd, io, .GamepadRStickLeft,  .RIGHTX, -thumb_dead_zone, -32768.0);
    update_gamepad_analog(bd, io, .GamepadRStickRight, .RIGHTX, +thumb_dead_zone, +32767.0);
    update_gamepad_analog(bd, io, .GamepadRStickUp,    .RIGHTY, -thumb_dead_zone, -32768.0);
    update_gamepad_analog(bd, io, .GamepadRStickDown,  .RIGHTY, +thumb_dead_zone, +32767.0);
}

// Optional: change how/when the mouse is captured (e.g. X11 debugger users).
ImGui_ImplSDL3_SetMouseCaptureMode :: (mode: Mouse_Capture_Mode) {
    bd := get_platform_data();
    if mode == .DISABLED && bd.MouseCaptureMode != .DISABLED  SDL_CaptureMouse(false);
    bd.MouseCaptureMode = mode;
}

// Optional: switch gamepad source between auto (first/all) and a manual list.
ImGui_ImplSDL3_SetGamepadMode :: (mode: Gamepad_Mode, manual_gamepads: [] *SDL_Gamepad = .[]) {
    bd := get_platform_data();
    close_gamepads();
    if mode == .MANUAL {
        for manual_gamepads  array_add(*bd.Gamepads, it);
    } else {
        assert(manual_gamepads.count == 0);
        bd.WantUpdateGamepadsList = true;
    }
    bd.GamepadMode = mode;
}

// --- Monitors ---

update_monitors :: () {
    bd := get_platform_data();
    platform_io := ImGui.GetPlatformIO();
    bd.WantUpdateMonitors = false;

    // platform_io.Monitors is an ImVector managed with ImGui's allocator; our
    // ImVector binding has no resize/push_back, so manage the buffer by hand.
    if platform_io.Monitors.Data  ImGui.MemFree(platform_io.Monitors.Data);
    platform_io.Monitors.Data = null;
    platform_io.Monitors.Size = 0;
    platform_io.Monitors.Capacity = 0;

    count: s32;
    displays := SDL_GetDisplays(*count);
    defer SDL_free(displays);
    if count <= 0  return;

    buf := cast(*ImGuiPlatformMonitor) ImGui.MemAlloc(cast(u64)(count * size_of(ImGuiPlatformMonitor)));
    n: s32 = 0;
    for i: 0..count - 1 {
        display_id := displays[i];

        mon: ImGuiPlatformMonitor;
        r: SDL_Rect;
        SDL_GetDisplayBounds(display_id, *r);
        mon.MainPos  = .{cast(float) r.x, cast(float) r.y};
        mon.MainSize = .{cast(float) r.w, cast(float) r.h};
        mon.WorkPos  = mon.MainPos;
        mon.WorkSize = mon.MainSize;

        ur: SDL_Rect;
        if SDL_GetDisplayUsableBounds(display_id, *ur) && ur.w > 0 && ur.h > 0 {
            mon.WorkPos  = .{cast(float) ur.x, cast(float) ur.y};
            mon.WorkSize = .{cast(float) ur.w, cast(float) ur.h};
        }

        mon.DpiScale = SDL_GetDisplayContentScale(display_id);
        mon.PlatformHandle = cast(*void)(cast(s64) i);
        if mon.DpiScale <= 0.0  continue; // skip virtual monitors reporting DPI 0 (#7902)

        buf[n] = mon;
        n += 1;
    }
    platform_io.Monitors.Data     = buf;
    platform_io.Monitors.Size     = n;
    platform_io.Monitors.Capacity = count;
}

// --- Multi-viewport platform interface ---
// These are #c_call callbacks ImGui invokes from UpdatePlatformWindows(). Ones
// that allocate (create/destroy) push g_context; the pure-SDL ones don't need it.

viewport_create_window :: (viewport: *ImGuiViewport) #c_call {
    push_context g_context {
        bd := get_platform_data();
        vd := New(ImGui_ImplSDL3_ViewportData);
        viewport.PlatformUserData = vd;

        vd.ParentWindow = get_sdl_window_from_viewport(viewport.ParentViewport);

        sdl_flags: SDL_WindowFlags = SDL_WINDOW_HIDDEN;
        sdl_flags |= SDL_GetWindowFlags(bd.Window) & SDL_WINDOW_HIGH_PIXEL_DENSITY;
        sdl_flags |= ifx viewport.Flags & .NoDecoration then SDL_WINDOW_BORDERLESS else SDL_WINDOW_RESIZABLE;
        if viewport.Flags & .NoTaskBarIcon  sdl_flags |= SDL_WINDOW_UTILITY;
        if viewport.Flags & .TopMost        sdl_flags |= SDL_WINDOW_ALWAYS_ON_TOP;

        vd.Window = SDL_CreateWindow("No Title Yet".data, cast(s32) viewport.Size.x, cast(s32) viewport.Size.y, sdl_flags);
        SDL_SetWindowParent(vd.Window, vd.ParentWindow);
        SDL_SetWindowPosition(vd.Window, cast(s32) viewport.Pos.x, cast(s32) viewport.Pos.y);
        vd.WindowOwned = true;

        setup_platform_handles(viewport, vd.Window);
    }
}

viewport_destroy_window :: (viewport: *ImGuiViewport) #c_call {
    push_context g_context {
        vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
        if vd {
            if vd.Window && vd.WindowOwned  SDL_DestroyWindow(vd.Window);
            vd.Window = null;
            free(vd);
        }
        viewport.PlatformUserData = null;
        viewport.PlatformHandle   = null;
    }
}

viewport_show_window :: (viewport: *ImGuiViewport) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;

    #if OS == .WINDOWS {
        // SDL hack: show the icon in the task bar (#7989). SDL_WINDOW_UTILITY does
        // not affect child windows on Windows, so toggle the ex-style directly.
        if !(viewport.Flags & .NoTaskBarIcon) {
            hwnd := viewport.PlatformHandleRaw;
            ex_style := GetWindowLongW(hwnd, GWL_EXSTYLE);
            ex_style |= WS_EX_APPWINDOW;
            ex_style &= ~WS_EX_TOOLWINDOW;
            ShowWindow(hwnd, SW_HIDE);
            SetWindowLongW(hwnd, GWL_EXSTYLE, ex_style);
        }
    }

    SDL_SetHint(SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, ifx viewport.Flags & .NoFocusOnAppearing then "0".data else "1".data);
    SDL_ShowWindow(vd.Window);
}

viewport_update_window :: (viewport: *ImGuiViewport) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    new_parent := get_sdl_window_from_viewport(viewport.ParentViewport);
    if new_parent != vd.ParentWindow {
        vd.ParentWindow = new_parent;
        SDL_SetWindowParent(vd.Window, vd.ParentWindow);
    }
}

get_window_pos :: (viewport: *ImGuiViewport) -> ImVec2 #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    x, y: s32;
    SDL_GetWindowPosition(vd.Window, *x, *y);
    return .{cast(float) x, cast(float) y};
}

viewport_set_window_pos :: (viewport: *ImGuiViewport, pos: ImVec2) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    SDL_SetWindowPosition(vd.Window, cast(s32) pos.x, cast(s32) pos.y);
}

get_window_size :: (viewport: *ImGuiViewport) -> ImVec2 #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    w, h: s32;
    SDL_GetWindowSize(vd.Window, *w, *h);
    return .{cast(float) w, cast(float) h};
}

viewport_set_window_size :: (viewport: *ImGuiViewport, size: ImVec2) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    SDL_SetWindowSize(vd.Window, cast(s32) size.x, cast(s32) size.y);
}

get_window_framebuffer_scale :: (viewport: *ImGuiViewport) -> ImVec2 #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    fb: ImVec2;
    window_size_and_framebuffer_scale(vd.Window, null, *fb);
    return fb;
}

// MSVC returns ImVec2 (it has constructors, so it isn't POD) through a hidden
// pointer, and the Windows bindings declare these callbacks accordingly. The
// SysV ABI returns it in registers like any small struct.
#if OS == .WINDOWS {
    viewport_get_window_pos :: (viewport: *ImGuiViewport) -> ImVec2 #c_call #cpp_return_type_is_non_pod { return get_window_pos(viewport); }
    viewport_get_window_size :: (viewport: *ImGuiViewport) -> ImVec2 #c_call #cpp_return_type_is_non_pod { return get_window_size(viewport); }
    viewport_get_window_framebuffer_scale :: (viewport: *ImGuiViewport) -> ImVec2 #c_call #cpp_return_type_is_non_pod { return get_window_framebuffer_scale(viewport); }
} else {
    viewport_get_window_pos :: (viewport: *ImGuiViewport) -> ImVec2 #c_call { return get_window_pos(viewport); }
    viewport_get_window_size :: (viewport: *ImGuiViewport) -> ImVec2 #c_call { return get_window_size(viewport); }
    viewport_get_window_framebuffer_scale :: (viewport: *ImGuiViewport) -> ImVec2 #c_call { return get_window_framebuffer_scale(viewport); }
}

viewport_set_window_title :: (viewport: *ImGuiViewport, title: *u8) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    SDL_SetWindowTitle(vd.Window, title);
}

viewport_set_window_alpha :: (viewport: *ImGuiViewport, alpha: float) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    SDL_SetWindowOpacity(vd.Window, alpha);
}

viewport_set_window_focus :: (viewport: *ImGuiViewport) #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    SDL_RaiseWindow(vd.Window);
}

viewport_get_window_focus :: (viewport: *ImGuiViewport) -> bool #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    return (SDL_GetWindowFlags(vd.Window) & SDL_WINDOW_INPUT_FOCUS) != 0;
}

viewport_get_window_minimized :: (viewport: *ImGuiViewport) -> bool #c_call {
    vd := cast(*ImGui_ImplSDL3_ViewportData) viewport.PlatformUserData;
    return (SDL_GetWindowFlags(vd.Window) & SDL_WINDOW_MINIMIZED) != 0;
}

platform_init_multi_viewport_support :: (window: *SDL_Window) {
    platform_io := ImGui.GetPlatformIO();
    platform_io.Platform_CreateWindow              = viewport_create_window;
    platform_io.Platform_DestroyWindow             = viewport_destroy_window;
    platform_io.Platform_ShowWindow                = viewport_show_window;
    platform_io.Platform_UpdateWindow              = viewport_update_window;
    platform_io.Platform_SetWindowPos              = viewport_set_window_pos;
    platform_io.Platform_GetWindowPos              = viewport_get_window_pos;
    platform_io.Platform_SetWindowSize             = viewport_set_window_size;
    platform_io.Platform_GetWindowSize             = viewport_get_window_size;
    platform_io.Platform_GetWindowFramebufferScale = viewport_get_window_framebuffer_scale;
    platform_io.Platform_SetWindowFocus            = viewport_set_window_focus;
    platform_io.Platform_GetWindowFocus            = viewport_get_window_focus;
    platform_io.Platform_GetWindowMinimized        = viewport_get_window_minimized;
    platform_io.Platform_SetWindowTitle            = viewport_set_window_title;
    platform_io.Platform_SetWindowAlpha            = viewport_set_window_alpha;

    // Register the app-owned main window as the main viewport's platform data so
    // the get/set callbacks work uniformly for main and secondary viewports.
    main_viewport := ImGui.GetMainViewport();
    vd := New(ImGui_ImplSDL3_ViewportData);
    vd.Window = window;
    vd.WindowID = SDL_GetWindowID(window);
    vd.WindowOwned = false;
    main_viewport.PlatformUserData = vd;
    main_viewport.PlatformHandle = cast(*void)(cast(u64) vd.WindowID);
}

platform_shutdown_multi_viewport_support :: () {
    ImGui.DestroyPlatformWindows(); // frees secondary viewports' ViewportData via Platform_DestroyWindow
    main_viewport := ImGui.GetMainViewport();
    vd := cast(*ImGui_ImplSDL3_ViewportData) main_viewport.PlatformUserData;
    if vd  free(vd); // main viewport's window is app-owned; only the vd is ours
    main_viewport.PlatformUserData = null;
}

#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "Basic";

// Minimal Win32 bindings for the task-bar-icon hack in viewport_show_window.
#if OS == .WINDOWS {
    user32 :: #system_library "user32";
    GWL_EXSTYLE      : s32 : -20;
    WS_EX_TOOLWINDOW : s32 : 0x0000_0080;
    WS_EX_APPWINDOW  : s32 : 0x0004_0000;
    SW_HIDE          : s32 : 0;
    GetWindowLongW :: (hwnd: *void, index: s32) -> s32 #foreign user32;
    SetWindowLongW :: (hwnd: *void, index: s32, new_long: s32) -> s32 #foreign user32;
    ShowWindow     :: (hwnd: *void, cmd_show: s32) -> s32 #foreign user32;
}
