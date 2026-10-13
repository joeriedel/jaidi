// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Cutscene images on the GPU: palette indices plus one in 16-bit targets, as views use, drawn
// with the film uber-shader (shaders/film.frag.hlsl). Unlike views they keep their contents
// from frame to frame, and the operations on them (clear, draw, crawl, copy a rectangle to
// another image, resolve through a palette) run in the order they were recorded, as the
// original's blitter ran them.

// An image a cutscene draws into or copies between: palette indices plus one (the exact
// path), or linear color, premultiplied, in RGBA16F (Enhanced).
Film_Image :: struct {
    texture: *SDL_GPUTexture;
    width, height: s32;
    color: bool;
}

// A palette for drawing in color: 256 x 1, sRGB, decoded to linear when sampled.
Film_Palette :: struct {
    texture: *SDL_GPUTexture;
}

// What the UI shows: a resolved image, and the palettes it was resolved through.
Film_Output :: struct {
    color:   *SDL_GPUTexture;
    palettes: [2] *SDL_GPUTexture;     // Source and destination of a fade.
    uploaded: [2] Palette;
    width, height: s32;
}

// How a resolve blends its two palettes.
Film_Fade :: enum s32 {
    NONE      :: 0;     // The source palette as it is.
    TO_MONO   :: 1;     // Source toward black.
    FROM_MONO :: 2;     // Black toward the destination.
    PALETTE   :: 3;     // Source toward destination.
}

// A table of ints for the uber-shader, 8 to a row: the crawl's row tables.
Film_Table :: struct {
    texture: *SDL_GPUTexture;
    rows: s32;
}

FILM_TABLE_WIDTH :: 8;

FILM_MODE_DELT         : s32 : 0;
FILM_MODE_CRAWL        : s32 : 1;
FILM_MODE_CRAWL_SMOOTH : s32 : 2;
FILM_MODE_DELT_TWEEN   : s32 : 3;

// Enhanced cutscene art's filter inside its outlines (0 EASU, 1 Catmull-Rom, 2 bilinear,
// 3 nearest, 4 the pixel-art edge filter) and whether the output is sharpened. Catmull-Rom
// unsharpened by default: EASU and the sharpening smeared and scratched small detail (the
// LucasArts logo's letters, 3 to 4 pixels thick). The others are kept for comparing (dev
// options --film-filter and --film-sharpen).
film_filter: s32 = 1;
film_sharpen := false;

// Stored as 16-bit halves in an RGBA16 texture, 4 texels a row, which samples exactly.
render_upload_film_table :: (values: [] [FILM_TABLE_WIDTH] s32) -> Film_Table {
    table: Film_Table;
    if !values return table;
    table.rows = xx values.count;
    halves := NewArray(values.count * FILM_TABLE_WIDTH * 2, u16,, temp);
    for row, r: values {
        for v, i: row {
            bits := cast,no_check(u32) v;
            halves[(r * FILM_TABLE_WIDTH + i) * 2]     = cast,trunc(u16) bits;
            halves[(r * FILM_TABLE_WIDTH + i) * 2 + 1] = cast,trunc(u16) (bits >> 16);
        }
    }
    table.texture = create_texture(FILM_TABLE_WIDTH / 2, table.rows, .R16G16B16A16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(table.texture, FILM_TABLE_WIDTH / 2, table.rows, halves.data, halves.count * 2);
    return table;
}

render_release_film_table :: (table: *Film_Table) {
    if table.texture  SDL_ReleaseGPUTexture(renderer.device, table.texture);
    table.* = .{};
}

render_create_film_image :: (width: s32, height: s32, color := false) -> Film_Image {
    image: Film_Image;
    image.width, image.height = width, height;
    image.color = color;
    format := ifx color then SDL_GPUTextureFormat.R16G16B16A16_FLOAT else .R16_UNORM;
    image.texture = create_texture(width, height, format, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    return image;
}

// An image's colors for drawing into color images: 'pixels' are sRGB, alpha 0 where nothing
// is, premultiplied (so black there).
render_upload_film_colors :: (width: s32, height: s32, pixels: [] u32) -> Gpu_Image {
    image: Gpu_Image;
    if width <= 0 || height <= 0 return image;
    image.width, image.height = width, height;
    image.texture = create_texture(width, height, .R8G8B8A8_UNORM_SRGB, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(image.texture, width, height, pixels.data, pixels.count * 4);
    return image;
}

render_upload_film_palette :: (palette: *Palette) -> Film_Palette {
    result: Film_Palette;
    texels: [256] u32;
    for palette.colors  texels[it_index] = 0xFF000000 | ((cast(u32) it.b) << 16) | ((cast(u32) it.g) << 8) | it.r;
    result.texture = create_texture(256, 1, .R8G8B8A8_UNORM_SRGB, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(result.texture, 256, 1, texels.data, size_of(type_of(texels)));
    return result;
}

render_release_film_palette :: (palette: *Film_Palette) {
    if palette.texture  SDL_ReleaseGPUTexture(renderer.device, palette.texture);
    palette.* = .{};
}

render_release_film_image :: (image: *Film_Image) {
    if image.texture  SDL_ReleaseGPUTexture(renderer.device, image.texture);
    image.* = .{};
}

render_create_film_output :: (width: s32, height: s32) -> Film_Output {
    output: Film_Output;
    output.width, output.height = width, height;
    output.color = create_texture(width, height, .R8G8B8A8_UNORM, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    for * output.palettes  it.* = create_texture(256, 1, .R8G8B8A8_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    for * output.uploaded  it.colors[0].r = 1;     // Differs from any first upload's.
    return output;
}

render_release_film_output :: (output: *Film_Output) {
    if output.color  SDL_ReleaseGPUTexture(renderer.device, output.color);
    for output.palettes  if it  SDL_ReleaseGPUTexture(renderer.device, it);
    output.* = .{};
}

// To the index, or a color image to black.
render_film_clear :: (target: *Film_Image, index: u8 = 0) {
    array_add(*renderer.film_ops, .{kind = .CLEAR, target = target.texture, size = .[target.width, target.height], index = index, color = target.color});
}

// Draws an image (palette indices, 0x100 for no pixel) with its top-left corner at (x, y),
// mirrored left to right if flip, inside clip (left, top, right exclusive, bottom exclusive).
// Positions and the clip are in 320x200 screen pixels; the target is 'scale' times that,
// across and down.
render_film_draw :: (target: *Film_Image, image: *Gpu_Image, x: float, y: float, flip: bool, clip: [4] float, scale := Vector2.{1, 1}) {
    op := array_add(*renderer.film_ops);
    op.kind    = .DRAW;
    op.target  = target.texture;
    op.size    = .[target.width, target.height];
    op.image   = image.texture;
    op.quad    = .[x * scale.x, y * scale.y, (x + image.width) * scale.x, (y + image.height) * scale.y];
    op.flip    = flip;
    op.uv      = ifx flip then float.[xx image.width, 0, 0, xx image.height] else float.[0, 0, xx image.width, xx image.height];
    op.color   = target.color;
    // Clips are never negative: the callers cut them to the screen.
    op.clip    = .[xx (clip[0] * scale.x + 0.5), xx (clip[1] * scale.y + 0.5), xx (clip[2] * scale.x + 0.5), xx (clip[3] * scale.y + 0.5)];
    op.params  = .[FILM_MODE_DELT, film_filter, 0, 0];
    op.params_f = .[scale.x, scale.y, 0, 0];
}

// Between two frames of an ANIM, into a color image: 'a' and 'b' with their top-left corners
// at a_at and b_at (in the screen's pixels), where p to zoom p + shift takes a's picture onto
// b's; 'along' of the way from a to b. 'offset' and 'size' put the screen's pixels in the
// target, at (p + offset) * size; the clip is in the screen's pixels with the offset added.
render_film_tween :: (target: *Film_Image, a: *Gpu_Image, b: *Gpu_Image, a_at: Vector2, b_at: Vector2, zoom: float, shift: Vector2, along: float, clip: [4] float, offset: Vector2, size: Vector2) {
    // Part of the way: the zoom at an even rate about the motion's fixed point.
    zoom_along := pow(zoom, along);
    shift_along := ifx abs(zoom - 1) < 0.0001 then shift * along else shift * ((1 - zoom_along) / (1 - zoom));
    op := array_add(*renderer.film_ops);
    op.kind    = .DRAW;
    op.target  = target.texture;
    op.size    = .[target.width, target.height];
    op.image   = a.texture;
    op.table   = b.texture;
    op.color   = target.color;
    op.clip    = .[xx (clip[0] * size.x + 0.5), xx (clip[1] * size.y + 0.5), xx (clip[2] * size.x + 0.5), xx (clip[3] * size.y + 0.5)];
    op.quad    = .[xx op.clip[0], xx op.clip[1], xx op.clip[2], xx op.clip[3]];
    op.uv      = .[0, 0, 1, 1];
    op.params  = .[FILM_MODE_DELT_TWEEN, film_filter, 0, 0];
    op.params_f = .[offset.x * size.x, offset.y * size.y, size.x, size.y];
    op.params_g = .[zoom_along, shift_along.x, shift_along.y, along];
    op.params_h = .[zoom, shift.x, shift.y, 0];
    op.params_i = .[a_at.x, a_at.y, b_at.x, b_at.y];
}

// The text crawl: 'text' holds the text's indices, 0 for see-through; 'rows' the per-row
// tables; the scroll offset is in 16.16 rows. Into a color image, through 'palette'; smooth,
// at full resolution from the text's distance field (the tables aren't used).
// Smooth, 'field' is the text's signed distance field, 'field_scale' times finer than the
// text, and 'full' its brightest color (sRGB, 0 to 1) with the number of steps its palette
// ramp takes down to black. 'margin' is how many screen pixels the target reaches past the
// screen's left edge.
render_film_crawl :: (target: *Film_Image, text: *Gpu_Image, rows: *Film_Table, offset: s32, scale := Vector2.{1, 1}, palette: *Film_Palette = null, smooth := false, full := Vector4.{}, margin: float = 0, field: *Gpu_Image = null, field_scale: s32 = 1) {
    op := array_add(*renderer.film_ops);
    op.kind    = .DRAW;
    op.target  = target.texture;
    op.size    = .[target.width, target.height];
    op.image   = ifx smooth then field.texture else text.texture;
    op.quad    = .[0, 0, xx target.width, xx target.height];
    op.clip    = .[0, 0, target.width, target.height];
    op.table   = rows.texture;
    op.color   = target.color;
    if palette  op.palettes[0] = palette.texture;
    op.params  = .[ifx smooth then FILM_MODE_CRAWL_SMOOTH else FILM_MODE_CRAWL, offset, text.width, text.height];
    op.params_f = .[scale.x, scale.y, margin, xx field_scale];
    op.params_g = .[full.x, full.y, full.z, full.w];
}

// A signed distance field, 16-bit values, 0.5 on the outline.
render_upload_film_field :: (width: s32, height: s32, values: [] u16) -> Gpu_Image {
    image: Gpu_Image;
    if width <= 0 || height <= 0 return image;
    image.width, image.height = width, height;
    image.texture = create_texture(width, height, .R16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(image.texture, width, height, values.data, values.count * 2);
    return image;
}

// Copies 'source' (left, top, right, bottom exclusive, inside the image) to (x, y) in another.
render_film_copy :: (from: *Film_Image, source: [4] s32, to: *Film_Image, x: s32, y: s32) {
    if source[2] <= source[0] || source[3] <= source[1] return;
    array_add(*renderer.film_ops, .{kind = .COPY, image = from.texture, target = to.texture, rect = source, clip = .[x, y, 0, 0]});
}

// Turns the image's indices into colors through the palette, into the output.
render_film_resolve :: (from: *Film_Image, output: *Film_Output, palette: *Palette) {
    render_film_resolve_fade(from, output, palette, palette, .NONE, 0, false);
}

// Through two palettes blended: 'fraction' of the way from source to destination by the fade's
// mode, in floating point; with dither, an ordered dither against banding.
render_film_resolve_fade :: (from: *Film_Image, output: *Film_Output, source: *Palette, destination: *Palette, fade: Film_Fade, fraction: float, dither: bool) {
    upload_palette(output, 0, source);
    upload_palette(output, 1, destination);
    op := array_add(*renderer.film_ops);
    op.kind   = .RESOLVE;
    op.image  = from.texture;
    op.target = output.color;
    op.palettes = output.palettes;
    op.params = .[xx fade, xx dither, 0, 0];
    op.params_f = .[fraction, 0, 0, 0];
}

// Turns one or two color images into the 8-bit sRGB output, applying a color fade in gamma
// space: 'fraction' of the way from the first image toward black, from black toward the second,
// or from the first toward the second. With dither, an ordered dither against banding; with
// sharpen, FSR 1's contrast-adaptive sharpening, 'sharpness' stops below its strongest.
render_film_output :: (first: *Film_Image, second: *Film_Image, output: *Film_Output, fade: Film_Fade, fraction: float, dither: bool, sharpen := false, sharpness: float = 0.2) {
    op := array_add(*renderer.film_ops);
    op.kind   = .OUTPUT;
    op.image  = first.texture;
    op.palettes = .[second.texture, null];
    op.target = output.color;
    op.params = .[xx fade, xx dither, xx (sharpen && film_sharpen), 0];
    op.params_f = .[fraction, sharpness, 0, 0];
}

// Reads an image's indices back, waiting for the GPU: for checks, not every frame. Call after
// the frame that drew it is submitted. Index + 1 per pixel, 0 where nothing was drawn.
render_read_film_image :: (image: *Film_Image) -> [] u16 {
    device := renderer.device;
    size := cast(u32) (image.width * image.height * 2);
    transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .DOWNLOAD, size = size};
    transfer := SDL_CreateGPUTransferBuffer(device, *transfer_info);
    defer SDL_ReleaseGPUTransferBuffer(device, transfer);

    command_buffer := SDL_AcquireGPUCommandBuffer(device);
    copy := SDL_BeginGPUCopyPass(command_buffer);
    region := SDL_GPUTextureRegion.{texture = image.texture, w = xx image.width, h = xx image.height, d = 1};
    destination := SDL_GPUTextureTransferInfo.{transfer_buffer = transfer};
    SDL_DownloadFromGPUTexture(copy, *region, *destination);
    SDL_EndGPUCopyPass(copy);
    fence := SDL_SubmitGPUCommandBufferAndAcquireFence(command_buffer);
    SDL_WaitForGPUFences(device, true, *fence, 1);
    SDL_ReleaseGPUFence(device, fence);

    texels := NewArray(image.width * image.height, u16,, temp);
    mapped := map_transfer_or_exit(transfer, false);
    memcpy(texels.data, mapped, size);
    SDL_UnmapGPUTransferBuffer(device, transfer);
    return texels;
}

#scope_module

Film_Op_Kind :: enum u8 { CLEAR; DRAW; COPY; RESOLVE; OUTPUT; }

Film_Op :: struct {
    kind:    Film_Op_Kind;
    target:  *SDL_GPUTexture;
    size:    [2] s32;           // The target's.
    image:   *SDL_GPUTexture;   // DRAW: the texture drawn; COPY and RESOLVE: the source.
    palettes: [2] *SDL_GPUTexture;  // RESOLVE.
    rect:    [4] s32;           // COPY: from where.
    quad:    [4] float;         // DRAW: where, in target pixels.
    uv:      [4] float;         // DRAW: texels at the quad's top-left and bottom-right.
    clip:    [4] s32;           // DRAW: the clip, in target pixels; COPY: x and y to copy to.
    flip:    bool;
    color:   bool;              // CLEAR, DRAW: into a color image.
    index:   u8;
    table:   *SDL_GPUTexture;   // DRAW: the shader's table, if the mode has one.
    params:   [4] s32;          // DRAW, RESOLVE: the mode and its parameters.
    params_f: [4] float;
    params_g: [4] float;
    params_h: [4] float;
    params_i: [4] float;
}

upload_palette :: (output: *Film_Output, slot: int, palette: *Palette) {
    if memcmp(*output.uploaded[slot], palette, size_of(Palette)) == 0 return;
    texels: [256] u32;
    for palette.colors  texels[it_index] = 0xFF000000 | ((cast(u32) it.b) << 16) | ((cast(u32) it.g) << 8) | it.r;
    upload_texture(output.palettes[slot], 256, 1, texels.data, size_of(type_of(texels)));
    output.uploaded[slot] = palette.*;
}

// Into index images, or with color into RGBA16F, premultiplied over what's there.
create_film_pipeline :: (vertex: *SDL_GPUShader, fragment: *SDL_GPUShader, color_target := false) -> *SDL_GPUGraphicsPipeline {
    color: SDL_GPUColorTargetDescription;
    color.format = .R16_UNORM;
    if color_target {
        color.format = .R16G16B16A16_FLOAT;
        color.blend_state.enable_blend = true;
        color.blend_state.src_color_blendfactor = .ONE;
        color.blend_state.dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA;
        color.blend_state.color_blend_op = .ADD;
        color.blend_state.src_alpha_blendfactor = .ONE;
        color.blend_state.dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA;
        color.blend_state.alpha_blend_op = .ADD;
    }
    info: SDL_GPUGraphicsPipelineCreateInfo;
    info.vertex_shader   = vertex;
    info.fragment_shader = fragment;
    info.primitive_type  = .TRIANGLELIST;
    info.rasterizer_state.fill_mode = .FILL;
    info.rasterizer_state.cull_mode = .NONE;
    info.target_info.color_target_descriptions = *color;
    info.target_info.num_color_targets = 1;
    pipeline := SDL_CreateGPUGraphicsPipeline(renderer.device, *info);
    if !pipeline log_error("SDL_CreateGPUGraphicsPipeline failed: %", to_string(SDL_GetError()));
    return pipeline;
}

// Runs the recorded operations in order. Draws into one target share a render pass until
// something else comes between.
run_film_ops :: (command_buffer: *SDL_GPUCommandBuffer) {
    defer array_reset_keeping_memory(*renderer.film_ops);
    pass: *SDL_GPURenderPass;
    pass_target: *SDL_GPUTexture;
    end_pass :: () #expand {
        if pass  SDL_EndGPURenderPass(pass);
        pass, pass_target = null, null;
    }

    for op: renderer.film_ops {
        if op.kind == {
          case .CLEAR;
            end_pass();
            target: SDL_GPUColorTargetInfo;
            target.texture  = op.target;
            target.load_op  = .CLEAR;
            target.store_op = .STORE;
            target.clear_color = ifx op.color then SDL_FColor.{0, 0, 0, 0} else .{(op.index + 1) / 65535.0, 0, 0, 0};
            pass = SDL_BeginGPURenderPass(command_buffer, *target, 1, null);
            pass_target = op.target;

          case .DRAW;
            if pass_target != op.target {
                end_pass();
                target: SDL_GPUColorTargetInfo;
                target.texture  = op.target;
                target.load_op  = .LOAD;
                target.store_op = .STORE;
                pass = SDL_BeginGPURenderPass(command_buffer, *target, 1, null);
                pass_target = op.target;
            }
            left   := max(op.clip[0], 0);
            top    := max(op.clip[1], 0);
            right  := min(op.clip[2], op.size[0]);
            bottom := min(op.clip[3], op.size[1]);
            if right <= left || bottom <= top continue;
            scissor := SDL_Rect.{left, top, right - left, bottom - top};
            SDL_SetGPUScissor(pass, *scissor);
            SDL_BindGPUGraphicsPipeline(pass, ifx op.color then renderer.film_rgb else renderer.film);

            quad: struct { rect, uv, target_size: [4] float; };
            quad.rect = op.quad;
            quad.uv   = op.uv;
            quad.target_size = .[xx op.size[0], xx op.size[1], 0, 0];
            SDL_PushGPUVertexUniformData(command_buffer, 0, *quad, size_of(type_of(quad)));

            bindings: [3] SDL_GPUTextureSamplerBinding;
            bindings[0] = .{texture = op.image, sampler = renderer.sampler};
            bindings[1] = .{texture = ifx op.table then op.table else renderer.blank_table, sampler = renderer.sampler};
            bindings[2] = .{texture = ifx op.palettes[0] then op.palettes[0] else renderer.blank_table, sampler = renderer.sampler};
            SDL_BindGPUFragmentSamplers(pass, 0, bindings.data, xx ifx op.color then 3 else 2);
            uniform: struct { params: [4] s32; params_f, params_g, params_h, params_i: [4] float; };
            uniform.params, uniform.params_f, uniform.params_g = op.params, op.params_f, op.params_g;
            uniform.params_h, uniform.params_i = op.params_h, op.params_i;
            SDL_PushGPUFragmentUniformData(command_buffer, 0, *uniform, size_of(type_of(uniform)));
            SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);

          case .COPY;
            end_pass();
            copy := SDL_BeginGPUCopyPass(command_buffer);
            source      := SDL_GPUTextureLocation.{texture = op.image,  x = xx op.rect[0], y = xx op.rect[1]};
            destination := SDL_GPUTextureLocation.{texture = op.target, x = xx op.clip[0], y = xx op.clip[1]};
            SDL_CopyGPUTextureToTexture(copy, *source, *destination, xx (op.rect[2] - op.rect[0]), xx (op.rect[3] - op.rect[1]), 1, false);
            SDL_EndGPUCopyPass(copy);

          case .OUTPUT;
            end_pass();
            output: SDL_GPUColorTargetInfo;
            output.texture  = op.target;
            output.load_op  = .DONT_CARE;
            output.store_op = .STORE;
            pass_out := SDL_BeginGPURenderPass(command_buffer, *output, 1, null);
            SDL_BindGPUGraphicsPipeline(pass_out, renderer.film_output);
            textures: [2] SDL_GPUTextureSamplerBinding;
            textures[0] = .{texture = op.image, sampler = renderer.sampler};
            textures[1] = .{texture = ifx op.palettes[0] then op.palettes[0] else op.image, sampler = renderer.sampler};
            SDL_BindGPUFragmentSamplers(pass_out, 0, textures.data, 2);
            uniform: struct { params: [4] s32; params_f: [4] float; };
            uniform.params, uniform.params_f = op.params, op.params_f;
            SDL_PushGPUFragmentUniformData(command_buffer, 0, *uniform, size_of(type_of(uniform)));
            SDL_DrawGPUPrimitives(pass_out, 3, 1, 0, 0);
            SDL_EndGPURenderPass(pass_out);

          case .RESOLVE;
            end_pass();
            output: SDL_GPUColorTargetInfo;
            output.texture  = op.target;
            output.load_op  = .DONT_CARE;
            output.store_op = .STORE;
            resolve := SDL_BeginGPURenderPass(command_buffer, *output, 1, null);
            SDL_BindGPUGraphicsPipeline(resolve, renderer.film_resolve);
            textures: [3] SDL_GPUTextureSamplerBinding;
            textures[0] = .{texture = op.image,       sampler = renderer.sampler};
            textures[1] = .{texture = op.palettes[0], sampler = renderer.sampler};
            textures[2] = .{texture = op.palettes[1], sampler = renderer.sampler};
            SDL_BindGPUFragmentSamplers(resolve, 0, textures.data, 3);
            uniform: struct { params: [4] s32; params_f: [4] float; };
            uniform.params, uniform.params_f = op.params, op.params_f;
            SDL_PushGPUFragmentUniformData(command_buffer, 0, *uniform, size_of(type_of(uniform)));
            SDL_DrawGPUPrimitives(resolve, 3, 1, 0, 0);
            SDL_EndGPURenderPass(resolve);
        }
    }
    end_pass();
}
