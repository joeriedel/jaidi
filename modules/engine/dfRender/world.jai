// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Drawing a level through its portals. The level's sectors only make sense seen through the
// adjoins that lead to them: sectors on different layers can overlap in space, so a sector is
// drawn only inside the part of the screen its portal shows. The stencil holds that part:
// while a sector is drawn, its pixels hold its depth in the walk from the camera's sector.
//
// A sector is drawn as: its walls and objects, depth tested and written; then each portal it
// sees: MARK the opening up one level where it's visible (depth tested against what the
// sector drew, so walls and objects in front keep it covered), UNDRAWN to clear DRAWN there,
// draw the sector behind at the next level, then RESTORE the opening to this level, marked
// DRAWN; then the sector's floor and ceiling as FLAT, which stay out of DRAWN. Nothing writes
// depth that isn't along the pixel's ray (floors and ceilings, planes around the camera, are
// drawn last and kept out of the openings), so what's behind an opening keeps its depth and
// is tested against as it is, as the original copies the far sector's depths back. Openings
// that overlap on the screen are settled by depth, whichever comes first. Pixels hold the
// level of the deepest open portal over them, so the next level is exactly the one opening.
//
// The stencil: the level in the low bits, ABOVE_WALL and DRAWN above them, which only FLAT
// tests. WALL_MARK sets ABOVE_WALL over a sky sector's walls, up from their tops, so the
// floor and ceiling don't show past the walls when the eye is above them; the sector's
// RESTORE, or the end of the frame, clears it.
//
// World views keep reversed depth (see scene.vert.hlsl): 1 at the near plane, 0 at the far.

World_Draw :: enum u8 {
    NONE;
    GEOMETRY;           // Walls, sky, objects: in the current level's pixels.
    POINTS;             // GEOMETRY as points (3D objects drawn by their vertices).
    SKY;                // GEOMETRY without writing depth: the original's sky never hides
                        // what's drawn after it.
    FLAT;               // GEOMETRY but not in DRAWN or ABOVE_WALL: floors and ceilings.
    FLAT_SKY;           // FLAT without writing depth: a pit's floor.
    WALL_MARK;          // ABOVE_WALL set where it's visible; level with ABOVE_WALL.
    PORTAL_MARK;        // The opening, up one level where it's visible.
    PORTAL_UNDRAWN;     // DRAWN cleared in the next level's pixels; the next level.
    PORTAL_RESTORE;     // The next level back to this one, DRAWN; level with DRAWN.
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

STENCIL_LEVEL      :: 0x3F;
STENCIL_ABOVE_WALL :: 0x40;
STENCIL_DRAWN      :: 0x80;

// Draws that follow go through this kind of drawing, testing the stencil against level (the
// sector's depth in the walk; one more for UNDRAWN, and with the flag for WALL_MARK and
// RESTORE).
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
    ds.compare_mask = STENCIL_LEVEL;
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
        case .SKY;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = false;
        case .FLAT;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = true;
            ds.compare_mask = 0xFF;
        case .FLAT_SKY;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = false;
            ds.compare_mask = 0xFF;
        case .WALL_MARK;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = false;
            ds.write_mask = STENCIL_ABOVE_WALL;
            stencil.pass_op = .REPLACE;
        case .PORTAL_MARK;
            ds.compare_op = .GREATER_OR_EQUAL;
            ds.enable_depth_write = false;
            ds.write_mask = STENCIL_LEVEL;
            stencil.pass_op = .INCREMENT_AND_CLAMP;
        case .PORTAL_UNDRAWN;
            ds.enable_depth_test = false;
            ds.enable_depth_write = false;
            ds.write_mask = STENCIL_DRAWN;
            stencil.pass_op = .ZERO;
        case .PORTAL_RESTORE;
            // Every pixel above this level is the opening's: the sector behind's own openings
            // are back at its level by now.
            ds.enable_depth_test = false;
            ds.enable_depth_write = false;
            stencil.compare_op = .LESS;
            stencil.pass_op = .REPLACE;
        case .OVERLAY;
            ds.enable_depth_test = false;
            ds.enable_stencil_test = false;
            ds.enable_depth_write = false;
    }
    ds.front_stencil_state = stencil;
    ds.back_stencil_state  = stencil;

    if kind != .GEOMETRY && kind != .POINTS && kind != .SKY && kind != .FLAT && kind != .FLAT_SKY && kind != .OVERLAY {
        color.blend_state.enable_color_write_mask = true;
        color.blend_state.color_write_mask = 0;
    }
}
