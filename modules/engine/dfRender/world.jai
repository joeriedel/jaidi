// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Drawing a level through its portals. The level's sectors only make sense seen through the
// adjoins that lead to them: sectors on different layers can overlap in space, so a sector is
// drawn only inside the part of the screen its portal shows. The stencil holds that part:
// while a sector is drawn, its pixels hold its depth in the walk from the camera's sector.
//
// For each portal the caller sees: MARK the opening (stencil test equal to the sector's level,
// depth tested against what the sector drew, so walls and objects in front of the opening
// keep it covered) up one level; CLEAR the depth there to the far plane; draw the sector
// behind it at the next level; then RESTORE the opening to the level it came from, writing
// its depth, so what's drawn after it in the nearer sector (objects, masked mid textures)
// is tested against the opening. Pixels hold the level of the deepest open portal over
// them, so the next level is exactly the one opening.
//
// World views keep reversed depth (see scene.vert.hlsl): 1 at the near plane, 0 at the far.

World_Draw :: enum u8 {
    NONE;
    GEOMETRY;           // Walls, floors, ceilings, sky, objects: in the current level's pixels.
    POINTS;             // GEOMETRY as points (3D objects drawn by their vertices).
    PORTAL_MARK;        // The opening, up one level where it's visible.
    PORTAL_CLEAR;       // The next level's depth back to far.
    PORTAL_RESTORE;     // The next level down one, at the opening's depth.
    OVERLAY;            // Over everything: flat, in pixels of the overlay's screen (see
                        // render_begin_overlay), no depth or stencil.
}

// The sky, drawn by direction rather than by its polygon's place: across, the texel is
// u + atan((x - center_x) * inv_focal) / turn * 1024 at pixel column x (the original builds
// its table for a parallax of 1024 whatever the level's); down, v + y * row_scale, which is
// one texel per row of a 200-line screen. u and v carry the camera's yaw and pitch.
Sky :: struct {
    u, v: float;
    center_x:  float;
    inv_focal: float;
    row_scale: float;
    pad: [3] float;
}

// Draws that follow go through this kind of drawing, testing the stencil against level (the
// sector's depth in the walk; one more for CLEAR and RESTORE).
render_set_world_draw :: (kind: World_Draw, level: u8) {
    renderer.world_draw = kind;
    renderer.stencil = level;
}

render_set_sky :: (sky: Sky) {
    renderer.sky = sky;
}

// The draws that follow go over the world view's scene, flat: positions in pixels of a
// screen of screen_width by screen_height, shown in the view's rectangle from x, y, w by h
// (the original's 320x200 HUD in the 4:3 part of a wider view).
render_begin_overlay :: (screen_width: float, screen_height: float, x: float, y: float, w: float, h: float) {
    if !renderer.passes return;
    pass := *renderer.passes[renderer.passes.count - 1];
    vw, vh := cast(float) pass.view.width, cast(float) pass.view.height;
    sx, sy := w / screen_width, h / screen_height;
    pass.overlay.scale_offset = .[2 * sx / vw, 2 * sy / vh, 2 * x / vw - 1, 1 - 2 * y / vh];
    pass.overlay.depth_range  = .[0, 1, 0, 0];
    renderer.world_draw = .OVERLAY;
    renderer.stencil = 0;
}

#scope_module

set_world_pipeline_state :: (info: *SDL_GPUGraphicsPipelineCreateInfo, color: *SDL_GPUColorTargetDescription, kind: World_Draw) {
    info.target_info.depth_stencil_format = renderer.stencil_format;
    ds := *info.depth_stencil_state;
    ds.enable_depth_test = true;
    ds.enable_stencil_test = true;
    ds.compare_mask = 0xFF;
    ds.write_mask = 0xFF;
    stencil: SDL_GPUStencilOpState;
    stencil.compare_op = .EQUAL;
    stencil.fail_op = .KEEP;
    stencil.depth_fail_op = .KEEP;
    stencil.pass_op = .KEEP;

    if kind == {
        case .GEOMETRY; #through;
        case .POINTS;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = true;
        case .PORTAL_MARK;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = false;
            stencil.pass_op = .INCREMENT_AND_CLAMP;
        case .PORTAL_CLEAR;
            ds.compare_op = .ALWAYS;
            ds.enable_depth_write = true;
        case .PORTAL_RESTORE;
            ds.compare_op = .ALWAYS;
            ds.enable_depth_write = true;
            stencil.pass_op = .DECREMENT_AND_CLAMP;
        case .OVERLAY;
            ds.enable_depth_test = false;
            ds.enable_stencil_test = false;
            ds.enable_depth_write = false;
    }
    ds.front_stencil_state = stencil;
    ds.back_stencil_state  = stencil;

    if kind != .GEOMETRY && kind != .POINTS && kind != .OVERLAY {
        color.blend_state.enable_color_write_mask = true;
        color.blend_state.color_write_mask = 0;
    }
}
