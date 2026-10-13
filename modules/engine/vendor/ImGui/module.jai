// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Bindings for Dear ImGui (docking branch).
//
// Core library only — no backends are vendored. The platform/renderer
// backend is implemented in native Jai on top of SDL3 + SDL_GPU.
//
// Regenerate the bindings (and rebuild ImGui.dll) with:
//   jai/bin/jai.exe modules/engine/vendor/ImGui/generate.jai

#load "paths.jai";

// ImGui's tiny math types map onto the engine's (Math) vector types so callers
// can pass familiar values. Layouts match (two/four packed floats).
ImVec2  :: Vector2;
ImVec4  :: Vector4;
ImColor :: Vector4;

ImVector :: struct (T: Type) {
    Size:     s32;
    Capacity: s32;
    Data:     *T;
}

ImDrawCallback :: #type (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call;

#scope_module

#import "Basic";
#import "Math";

#if OS == .WINDOWS {
    #load "windows.jai";
    // ImGui's default Win32 handlers call into user32 (clipboard) and shell32
    // (ShellExecuteW, for opening hyperlinks). We keep IME disabled at compile
    // time so we don't also need imm32 — see generate.jai.
    #library,system,link_always "user32";
    #library,system,link_always "shell32";
} else #if OS == .LINUX {
    #load "linux.jai";
} else {
    #assert false "ImGui module: unsupported platform";
}
