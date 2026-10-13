// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dev tools screen: a column of buttons like the main menu, one per tool. A tool runs on its
// own until its window is closed, which comes back here. Returns false when the user goes back
// to the main menu.

show_tools :: (cutscenes: *Cutscene_Settings) -> bool {
    if tools.active == .NONE return show_tools_menu();

    open := true;
    if tools.active == {
        case .ARCHIVE_BROWSER; show_archive_browser(*open);
        case .FM_TEST;         show_fm_test(*open);
        case .MUSIC;           show_music_tool(*open);
        case .CUTSCENES;       show_cutscene_tool(*open, cutscenes);
        case .LEVELS;          show_level_tool(*open);
    }
    if !open tools.active = .NONE;
    return true;
}

// Starts the tools screen in a tool: "archive", "music", "fm", "cutscene" or "level".
open_tool :: (name: string) -> bool {
    if name == {
        case "archive";  tools.active = .ARCHIVE_BROWSER;
        case "music";    tools.active = .MUSIC;
        case "fm";       tools.active = .FM_TEST;
        case "cutscene"; tools.active = .CUTSCENES;
        case "level";    tools.active = .LEVELS;
        case; return false;
    }
    return true;
}

// Frees what the tools hold on the GPU and in memory, before the renderer shuts down.
shutdown_tools :: () {
    shutdown_archive_browser();
}

#scope_file

Tool :: enum u8 {
    NONE;
    ARCHIVE_BROWSER;
    FM_TEST;
    MUSIC;
    CUTSCENES;
    LEVELS;
}

TOOL_LABELS :: string.["", "Archive Browser", "FM Test", "Music", "Cutscenes", "Levels"];

tools: struct {
    active: Tool;
};

show_tools_menu :: () -> bool {
    button_size := im_scale(ImVec2.{160, 40});
    stay := true;

    viewport := ImGui.GetMainViewport();
    ImGui.SetNextWindowPos(viewport.WorkPos);
    ImGui.SetNextWindowSize(viewport.WorkSize);
    ImGui.SetNextWindowViewport(viewport.ID);

    flags := ImGuiWindowFlags.NoDecoration | .NoBackground | .NoMove | .NoSavedSettings | .NoBringToFrontOnFocus | .NoDocking;
    if ImGui.Begin("Tools", flags = flags) {
        style := ImGui.GetStyle();
        avail := ImGui.GetContentRegionAvail();
        button_x := (avail.x - button_size.x) * 0.5 + style.WindowPadding.x;
        total_height := TOOL_LABELS.count * (button_size.y + style.ItemSpacing.y) - style.ItemSpacing.y;
        ImGui.SetCursorPosY((avail.y - total_height) * 0.5 + style.WindowPadding.y);

        for tool: Tool.ARCHIVE_BROWSER..Tool.LEVELS {
            ImGui.SetCursorPosX(button_x);
            if ImGui.Button(temp_c_string(TOOL_LABELS[tool]), button_size)  tools.active = tool;
        }
        ImGui.SetCursorPosX(button_x);
        if ImGui.Button("Back", button_size)  stay = false;
    }
    ImGui.End();

    // Nothing a tool started should outlive the tools screen.
    if !stay {
        music_stop();
        audio_stop_sound();
        audio_lock();
        imuse_stop_all();
        fm_stop_all_notes();
        audio_unlock();
    }
    return stay;
}

#load "archive_browser.jai";
#load "cutscene_runs.jai";
#load "cutscene_tool.jai";
#load "assets.jai";
#load "asset_viewer.jai";
#load "dev_command_line.jai";
#load "fm_test.jai";
#load "level_tool.jai";
#load "music.jai";

#import "Basic";
#import "engine/dfAudio";
#import "engine/dfFm";
#import "engine/dfIMuse";
#import "engine/dfMusic";
#import "engine/dfImGui";
#import "engine/dfWorld";
#import "engine/vendor/ImGui";
