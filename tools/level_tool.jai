// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The Levels tool: the game's levels from JEDI.LVL, each played from its start by a click.
// Esc in the level comes back here.

show_level_tool :: (open: *bool) {
    viewport := ImGui.GetMainViewport();
    ImGui.SetNextWindowPos(viewport.WorkPos, .FirstUseEver);
    ImGui.SetNextWindowSize(im_scale(ImVec2.{420, 520}), .FirstUseEver);
    if ImGui.Begin("Levels", open) {
        levels := world_get_level_list();
        if !levels  ImGui.TextUnformatted("JEDI.LVL wasn't found in the GOBs.");
        for levels {
            ImGui.PushID(cast(s32) it_index);
            if ImGui.Button("Play")  level_tool.request = it.name;
            ImGui.SameLine();
            ImGui.Text("%  (%)", it.title, it.name);
            ImGui.PopID();
        }
        ImGui.Separator();
        ImGui.TextWrapped("WASD move, mouse look, Shift run, Space jump, C crouch, arrows turn, Page Up/Down look, F5 headlight, F12 Enhanced (high resolution) or 320x200, Esc the menu (Abort Mission comes back here).");
    }
    ImGui.End();
}

// A level the tool asked to play this frame, once.
take_tool_level_request :: () -> string {
    request := level_tool.request;
    level_tool.request = "";
    return request;
}

#scope_file

level_tool: struct {
    request: string;
};
