// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// The GPU renderer. It draws the way the original's software renderer does: everything goes
// into a target of palette indices, each pixel lit through the level's colormap by the
// original's integer formulas (shaders/scene.frag.hlsl, and lighting.jai for what the original
// computes per polygon or per vertex on the CPU), and the palette is applied last, as the
// VGA DAC did (shaders/resolve.frag.hlsl).
//
// An RGB view (Enhanced) draws the same way but lights in color: each pixel's palette color
// is lit by a curve fitted to the colormap (fit_light) at a fractional light level, in linear
// light into RGBA16F, then turned to sRGB with an ordered dither by the film output pass.
// Only world views are drawn in RGB.
//
// A View is an offscreen target the UI shows as an image. During the frame, code records
// draws into views; render_submit, called before ImGui's render pass, uploads the vertices
// and runs every view's passes.
//
// Positions are given in view space: x right, y down, z forward, in world units, as the
// original transforms them itself before drawing.

Render_Mode :: enum u8 {
    FLAT           :: 0;   // Color, one light level (31 or more: no colormap).
    SHADED         :: 1;   // Color, light interpolated between vertices.
    TEXTURE_FLAT   :: 2;   // Texture, one light level.
    TEXTURE_SHADED :: 3;   // Texture, light interpolated between vertices.
    TEXTURE_DEPTH  :: 4;   // Texture, lit per pixel by distance.
    TEXTURE_RAW    :: 5;   // Texture, unlit.
    COLOR_RAW      :: 6;   // Color, unlit.
    SKY            :: 7;   // Texture by the pixel's direction (see Sky), unlit.
}

Render_Vertex :: struct {
    position: Vector3;
    uv:       Vector2;      // In texels.
    light:    float;        // Light level; for the shaded modes, intensity in levels.
    depth:    float;        // Distance used for TEXTURE_DEPTH lighting, in world units.
    color:    u32;          // See render_pack_color.
}

render_pack_color :: (mode: Render_Mode, index: u8 = 0, transparent := false) -> u32 {
    return cast(u32) index | ((cast(u32) mode) << 8) | ifx transparent then 0x1000 else 0;
}

// A game image on the GPU: 16-bit texels holding the palette index, or 0x100 for "no pixel"
// (gaps in a DELT).
Gpu_Image :: struct {
    texture: *SDL_GPUTexture;
    width, height: s32;
    transfer: *SDL_GPUTransferBuffer;  // Images updated every frame keep one for their uploads.
}

// A colormap on the GPU: 32 rows of light levels, then the light ramp. The rows are kept on
// the CPU too, for RGB views' fits.
Gpu_Colormap :: struct {
    texture: *SDL_GPUTexture;
    source:  *Colormap;
}

View :: struct {
    width, height: s32;
    world:   bool;              // A 3D view of a level: reversed depth and a stencil for
                                // drawing through portals (see world.jai).
    rgb:     bool;              // Lit in color (Enhanced); world views only.
    indices: *SDL_GPUTexture;   // Palette index + 1, 0 for nothing drawn.
    scene:   *SDL_GPUTexture;   // RGB views: linear color, RGBA16F, in place of indices.
    light_table: *SDL_GPUTexture;   // RGB views: the palette and the fit (scene.frag.hlsl).
    fit_palette:  Palette;      // What the light table was fitted to.
    fit_colormap: *Colormap;
    depth:   *SDL_GPUTexture;
    color:   *SDL_GPUTexture;   // What the UI shows.
    palette: *SDL_GPUTexture;   // 256 x 1, uploaded when it changes.
    uploaded_palette: Palette;
}

Projection :: struct {
    perspective: bool = true;
    focal:  float;              // Perspective: pixels per unit at distance 1. 0 picks the
                                // original's 90-degree view across a 320-wide screen.
    scale:  float = 1;          // 2D: pixels per unit.
    center: Vector2;            // Offset of the view's center from the target's, in pixels.
    near: float = 0.25;
    far:  float = 1024;
    pixel_aspect: float = 1;    // Perspective: how much taller than wide a pixel is drawn.
}

// Fails when the GPU driver isn't one the shaders are built for (SPIR-V only so far).
render_init :: (device: *SDL_GPUDevice) -> bool {
    renderer.device = device;
    driver := to_string(SDL_GetGPUDeviceDriver(device));
    if driver != "vulkan" {
        log_error("The renderer's shaders are SPIR-V only; the GPU driver is %.", driver);
        return false;
    }

    renderer.depth_format = .D32_FLOAT;
    if !SDL_GPUTextureSupportsFormat(device, .D32_FLOAT, ._2D, SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)
        renderer.depth_format = .D16_UNORM;
    renderer.stencil_format = .D32_FLOAT_S8_UINT;
    if !SDL_GPUTextureSupportsFormat(device, .D32_FLOAT_S8_UINT, ._2D, SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET)
        renderer.stencil_format = .D24_UNORM_S8_UINT;

    scene_vert  := create_shader(SCENE_VERT_SPV, .VERTEX, 0, 2);
    points_vert := create_shader(SCENE_POINTS_VERT_SPV, .VERTEX, 0, 2);
    scene_frag  := create_shader(SCENE_FRAG_SPV, .FRAGMENT, 2, 1);
    scene_rgb_frag := create_shader(SCENE_RGB_FRAG_SPV, .FRAGMENT, 3, 1);
    resolve_vert := create_shader(RESOLVE_VERT_SPV, .VERTEX, 0, 0);
    resolve_frag := create_shader(RESOLVE_FRAG_SPV, .FRAGMENT, 2, 1);
    film_vert    := create_shader(FILM_VERT_SPV, .VERTEX, 0, 1);
    film_frag    := create_shader(FILM_FRAG_SPV, .FRAGMENT, 2, 1);
    film_resolve_frag := create_shader(FILM_RESOLVE_FRAG_SPV, .FRAGMENT, 3, 1);
    film_rgb_frag     := create_shader(FILM_RGB_FRAG_SPV, .FRAGMENT, 3, 1);
    film_output_frag  := create_shader(FILM_OUTPUT_FRAG_SPV, .FRAGMENT, 2, 1);
    defer {
        SDL_ReleaseGPUShader(device, scene_vert);
        SDL_ReleaseGPUShader(device, points_vert);
        SDL_ReleaseGPUShader(device, scene_frag);
        SDL_ReleaseGPUShader(device, scene_rgb_frag);
        SDL_ReleaseGPUShader(device, resolve_vert);
        SDL_ReleaseGPUShader(device, resolve_frag);
        SDL_ReleaseGPUShader(device, film_vert);
        SDL_ReleaseGPUShader(device, film_frag);
        SDL_ReleaseGPUShader(device, film_resolve_frag);
        SDL_ReleaseGPUShader(device, film_rgb_frag);
        SDL_ReleaseGPUShader(device, film_output_frag);
    }
    if !scene_vert || !points_vert || !scene_frag || !scene_rgb_frag || !resolve_vert || !resolve_frag || !film_vert || !film_frag || !film_resolve_frag || !film_rgb_frag || !film_output_frag return false;

    renderer.triangles = create_scene_pipeline(scene_vert, scene_frag, .TRIANGLELIST);
    renderer.points    = create_scene_pipeline(points_vert, scene_frag, .POINTLIST);
    renderer.resolve   = create_resolve_pipeline(resolve_vert, resolve_frag);
    renderer.film      = create_film_pipeline(film_vert, film_frag);
    renderer.film_resolve = create_resolve_pipeline(resolve_vert, film_resolve_frag);
    renderer.film_rgb     = create_film_pipeline(film_vert, film_rgb_frag, color_target = true);
    renderer.film_output  = create_resolve_pipeline(resolve_vert, film_output_frag);
    if !renderer.triangles || !renderer.points || !renderer.resolve || !renderer.film || !renderer.film_resolve || !renderer.film_rgb || !renderer.film_output return false;
    for * renderer.world_pipelines {
        kind := cast(World_Draw) it_index;
        it.* = create_scene_pipeline(ifx kind == .POINTS then points_vert else scene_vert, scene_frag, ifx kind == .POINTS then .POINTLIST else .TRIANGLELIST, kind);
        if !it.* return false;
    }
    for * renderer.world_rgb_pipelines {
        kind := cast(World_Draw) it_index;
        it.* = create_scene_pipeline(ifx kind == .POINTS then points_vert else scene_vert, scene_rgb_frag, ifx kind == .POINTS then .POINTLIST else .TRIANGLELIST, kind, .R16G16B16A16_FLOAT);
        if !it.* return false;
    }

    sampler_info: SDL_GPUSamplerCreateInfo;
    sampler_info.min_filter = .NEAREST;
    sampler_info.mag_filter = .NEAREST;
    sampler_info.mipmap_mode = .NEAREST;
    sampler_info.address_mode_u = .CLAMP_TO_EDGE;
    sampler_info.address_mode_v = .CLAMP_TO_EDGE;
    sampler_info.address_mode_w = .CLAMP_TO_EDGE;
    renderer.sampler = SDL_CreateGPUSampler(device, *sampler_info);

    // Ready from here: the uploads below need it.
    renderer.ready = true;

    // Stand-ins for draws without a texture or a colormap.
    blank: Image;
    blank.width, blank.height = 1, 1;
    blank.pixels = .[0];
    renderer.blank_image = render_upload_image(blank);
    identity: Colormap;
    for * level: identity.levels  for * level.* it.* = cast(u8) it_index;
    renderer.identity_colormap = render_upload_colormap(*identity);
    renderer.blank_table = create_texture(1, 1, .R16G16B16A16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    zeros: [4] u16;
    upload_texture(renderer.blank_table, 1, 1, zeros.data, size_of(type_of(zeros)));
    return true;
}

render_shutdown :: () {
    if !renderer.device return;
    device := renderer.device;
    SDL_WaitForGPUIdle(device);
    render_release_image(*renderer.blank_image);
    render_release_colormap(*renderer.identity_colormap);
    SDL_ReleaseGPUTexture(device, renderer.blank_table);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.triangles);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.points);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.resolve);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.film);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.film_resolve);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.film_rgb);
    SDL_ReleaseGPUGraphicsPipeline(device, renderer.film_output);
    for renderer.world_pipelines  SDL_ReleaseGPUGraphicsPipeline(device, it);
    for renderer.world_rgb_pipelines  SDL_ReleaseGPUGraphicsPipeline(device, it);
    SDL_ReleaseGPUSampler(device, renderer.sampler);
    SDL_ReleaseGPUBuffer(device, renderer.vertex_buffer);
    SDL_ReleaseGPUTransferBuffer(device, renderer.vertex_transfer);
    array_free(renderer.vertices);
    array_free(renderer.passes);
    array_free(renderer.batches);
    array_free(renderer.film_ops);
    array_free(renderer.uploads);
    renderer = .{};
}

render_is_ready :: () -> bool { return renderer.ready; }

// mask, when given, marks the pixels that exist; the rest become "no pixel".
// Without a running renderer (tests), only the size: the game's logic still needs it.
render_upload_image :: (image: Image, mask: [] bool = .[]) -> Gpu_Image {
    result: Gpu_Image;
    if image.width <= 0 || image.height <= 0 return result;
    if !renderer.ready return .{width = image.width, height = image.height};
    texels := NewArray(image.width * image.height, u16,, temp);
    for image.pixels {
        texels[it_index] = ifx mask && !mask[it_index] then 0x100 else cast(u16) it;
    }
    result.texture = create_texture(image.width, image.height, .R16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    result.width   = image.width;
    result.height  = image.height;
    upload_texture(result.texture, image.width, image.height, texels.data, texels.count * 2);
    return result;
}

// Replaces the texels of an image changing every frame (a cutscene's screen), recreating its
// texture when the size changes. No mask: every pixel exists. The texels go into the image's
// own transfer buffer (cycled, so a frame still uploading isn't written over), and the upload
// is recorded for render_submit, on the frame's command buffer. mask, when given, marks the
// pixels that exist.
render_update_image :: (image: *Gpu_Image, source: Image, mask: [] bool = .[]) {
    if source.width <= 0 || source.height <= 0 return;
    size := cast(u32) (source.width * source.height * 2);
    if !image.texture || image.width != source.width || image.height != source.height {
        render_release_image(image);
        image.texture = create_texture(source.width, source.height, .R16_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
        image.width   = source.width;
        image.height  = source.height;
        transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .UPLOAD, size = size};
        image.transfer = SDL_CreateGPUTransferBuffer(renderer.device, *transfer_info);
    }
    texels := cast(*u16) map_transfer_or_exit(image.transfer, true);
    for source.pixels  texels[it_index] = ifx mask && !mask[it_index] then 0x100 else cast(u16) it;
    SDL_UnmapGPUTransferBuffer(renderer.device, image.transfer);
    array_add(*renderer.uploads, .{image.texture, image.transfer, image.width, image.height});
}

render_release_image :: (image: *Gpu_Image) {
    if image.texture   SDL_ReleaseGPUTexture(renderer.device, image.texture);
    if image.transfer  SDL_ReleaseGPUTransferBuffer(renderer.device, image.transfer);
    image.* = .{};
}

render_upload_colormap :: (colormap: *Colormap) -> Gpu_Colormap {
    WIDTH :: 256;
    if !renderer.ready return .{};
    texels := NewArray(WIDTH * (LIGHT_LEVELS + 1), u8,, temp);
    memcpy(texels.data, colormap.levels.data, size_of(type_of(colormap.levels)));
    memcpy(texels.data + WIDTH * LIGHT_LEVELS, colormap.light_ramp.data, LIGHT_RAMP_COUNT);
    result: Gpu_Colormap;
    result.texture = create_texture(WIDTH, LIGHT_LEVELS + 1, .R8_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(result.texture, WIDTH, LIGHT_LEVELS + 1, texels.data, texels.count);
    result.source = New(Colormap);
    result.source.* = colormap.*;
    return result;
}

render_release_colormap :: (colormap: *Gpu_Colormap) {
    if colormap.texture SDL_ReleaseGPUTexture(renderer.device, colormap.texture);
    if colormap.source  free(colormap.source);
    colormap.* = .{};
}

// rgb: lit in color (Enhanced), for world views.
render_create_view :: (width: s32, height: s32, world := false, rgb := false) -> View {
    view: View;
    view.width  = max(width, 1);
    view.height = max(height, 1);
    view.world  = world;
    view.rgb    = rgb && world;
    if view.rgb  view.scene = create_texture(view.width, view.height, .R16G16B16A16_FLOAT, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    else         view.indices = create_texture(view.width, view.height, .R16_UNORM, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    view.depth   = create_texture(view.width, view.height, ifx world then renderer.stencil_format else renderer.depth_format, SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET);
    view.color   = create_texture(view.width, view.height, .R8G8B8A8_UNORM, SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER);
    return view;
}

render_release_view :: (view: *View) {
    if view.palette SDL_ReleaseGPUTexture(renderer.device, view.palette);
    if view.indices SDL_ReleaseGPUTexture(renderer.device, view.indices);
    if view.scene   SDL_ReleaseGPUTexture(renderer.device, view.scene);
    if view.light_table  SDL_ReleaseGPUTexture(renderer.device, view.light_table);
    if view.depth   SDL_ReleaseGPUTexture(renderer.device, view.depth);
    if view.color   SDL_ReleaseGPUTexture(renderer.device, view.color);
    view.* = .{};
}

// Makes the view this size, recreating its targets when it changes.
render_size_view :: (view: *View, width: s32, height: s32, world := false, rgb := false) {
    width, height = max(width, 1), max(height, 1);
    rgb = rgb && world;
    if (view.indices || view.scene) && view.width == width && view.height == height && view.world == world && view.rgb == rgb return;
    palette := view.palette;
    uploaded := view.uploaded_palette;
    view.palette = null;
    render_release_view(view);
    view.* = render_create_view(width, height, world, rgb);
    view.palette = palette;
    view.uploaded_palette = uploaded;
}

// Starts recording a view's frame. Every later draw goes into it until the next
// render_begin_view. The palette and background are copied.
// With transparent, what nothing is drawn on is left clear, for drawing over another view.
// With light_only (RGB views), lit drawing is white at its light, to show the light alone.
render_begin_view :: (view: *View, palette: *Palette, colormap: *Gpu_Colormap, projection: Projection, background := Color.{0, 0, 0}, transparent := false, light_only := false) {
    pass := array_add(*renderer.passes);
    pass.view = view;
    pass.light_only = light_only && view.rgb;
    pass.colormap = ifx colormap && colormap.texture then colormap.texture else renderer.identity_colormap.texture;
    pass.first_batch = xx renderer.batches.count;
    pass.background = .[background.r / 255.0, background.g / 255.0, background.b / 255.0, ifx transparent then 0.0 else 1.0];

    if !view.palette || memcmp(*view.uploaded_palette, palette, size_of(Palette)) != 0 {
        if !view.palette  view.palette = create_texture(256, 1, .R8G8B8A8_UNORM, SDL_GPU_TEXTUREUSAGE_SAMPLER);
        texels: [256] u32;
        for palette.colors  texels[it_index] = 0xFF000000 | ((cast(u32) it.b) << 16) | ((cast(u32) it.g) << 8) | it.r;
        upload_texture(view.palette, 256, 1, texels.data, size_of(type_of(texels)));
        view.uploaded_palette = palette.*;
    }
    if view.rgb {
        source := ifx colormap then colormap.source else null;
        if !view.light_table || view.fit_colormap != source || memcmp(*view.fit_palette, palette, size_of(Palette)) != 0 {
            upload_light_table(view, palette, source);
            view.fit_palette  = palette.*;
            view.fit_colormap = source;
        }
    }

    focal := projection.focal;
    if focal <= 0  focal = view.width * 0.5;
    if projection.perspective {
        pass.projection.scale_offset = .[2 * focal / view.width, 2 * focal * projection.pixel_aspect / view.height, 2 * projection.center.x / view.width, -2 * projection.center.y / view.height];
        pass.projection.depth_range  = .[projection.near, projection.far, ifx view.world then 2.0 else 1.0, 0];
    } else {
        pass.projection.scale_offset = .[2 * projection.scale / view.width, 2 * projection.scale / view.height, 2 * projection.center.x / view.width, -2 * projection.center.y / view.height];
        pass.projection.depth_range  = .[projection.near, projection.far, 0, 0];
    }
    renderer.lighting = .{};
    renderer.image = null;
    renderer.world_draw = .GEOMETRY;
    renderer.stencil = 0;
    renderer.sky = .{};
    renderer.clip = NO_CLIP;
}

// Lighting for the draws that follow, in the original's terms.
render_set_lighting :: (lighting: Lighting) {
    renderer.lighting = lighting;
}

// The plane in view space that the draws that follow are cut by, keeping where
// a x + b y + c z + d is 0 or more; NO_CLIP for none.
render_set_clip_plane :: (plane: Clip_Plane) {
    renderer.clip = plane;
}

Clip_Plane :: [4] float;
NO_CLIP :: float.[0, 0, 0, 1];

// The texture for the draws that follow; null for none.
render_set_image :: (image: *Gpu_Image) {
    renderer.image = ifx image then image.texture else null;
}

render_add_triangles :: (vertices: [] Render_Vertex) {
    add_vertices(vertices, false);
}

render_add_points :: (vertices: [] Render_Vertex) {
    add_vertices(vertices, true);
}

// A rectangle from two corners, as two triangles: positions and texture coordinates
// interpolate from top-left to bottom-right.
render_add_quad :: (top_left: Vector3, bottom_right: Vector3, uv0: Vector2, uv1: Vector2, light: float, depth: float, color: u32) {
    a := Render_Vertex.{top_left, uv0, light, depth, color};
    b := Render_Vertex.{.{bottom_right.x, top_left.y, top_left.z}, .{uv1.x, uv0.y}, light, depth, color};
    c := Render_Vertex.{bottom_right, uv1, light, depth, color};
    d := Render_Vertex.{.{top_left.x, bottom_right.y, bottom_right.z}, .{uv0.x, uv1.y}, light, depth, color};
    quad := Render_Vertex.[a, b, c, a, c, d];
    add_vertices(quad, false);
}

// Runs the recorded views. Call with the frame's command buffer before any render pass.
render_submit :: (command_buffer: *SDL_GPUCommandBuffer) {
    defer {
        array_reset_keeping_memory(*renderer.vertices);
        array_reset_keeping_memory(*renderer.passes);
        array_reset_keeping_memory(*renderer.batches);
    }
    if !renderer.ready return;
    run_uploads(command_buffer);
    run_film_ops(command_buffer);
    if !renderer.passes return;
    device := renderer.device;

    if renderer.vertices {
        size := cast(u32) (renderer.vertices.count * size_of(Render_Vertex));
        if size > renderer.vertex_capacity {
            SDL_ReleaseGPUBuffer(device, renderer.vertex_buffer);
            SDL_ReleaseGPUTransferBuffer(device, renderer.vertex_transfer);
            capacity := max(size * 2, 64 * 1024);
            buffer_info := SDL_GPUBufferCreateInfo.{usage = SDL_GPU_BUFFERUSAGE_VERTEX, size = capacity};
            renderer.vertex_buffer = SDL_CreateGPUBuffer(device, *buffer_info);
            transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .UPLOAD, size = capacity};
            renderer.vertex_transfer = SDL_CreateGPUTransferBuffer(device, *transfer_info);
            renderer.vertex_capacity = capacity;
        }
        mapped := map_transfer_or_exit(renderer.vertex_transfer, true);
        memcpy(mapped, renderer.vertices.data, size);
        SDL_UnmapGPUTransferBuffer(device, renderer.vertex_transfer);

        source := SDL_GPUTransferBufferLocation.{transfer_buffer = renderer.vertex_transfer};
        region := SDL_GPUBufferRegion.{buffer = renderer.vertex_buffer, size = size};
        copy := SDL_BeginGPUCopyPass(command_buffer);
        SDL_UploadToGPUBuffer(copy, *source, *region, true);
        SDL_EndGPUCopyPass(copy);
    }

    for * pass: renderer.passes {
        view := pass.view;
        last_batch := ifx it_index + 1 < renderer.passes.count then renderer.passes[it_index + 1].first_batch else xx renderer.batches.count;

        target: SDL_GPUColorTargetInfo;
        target.texture  = ifx view.rgb then view.scene else view.indices;
        if view.rgb {
            b := pass.background;
            target.clear_color = .{srgb_to_linear(b[0]), srgb_to_linear(b[1]), srgb_to_linear(b[2]), b[3]};
        }
        target.load_op  = .CLEAR;
        target.store_op = .STORE;
        depth: SDL_GPUDepthStencilTargetInfo;
        depth.texture = view.depth;
        depth.clear_depth = ifx view.world then 0.0 else 1.0;
        depth.load_op  = .CLEAR;
        depth.store_op = .DONT_CARE;
        depth.stencil_load_op  = ifx view.world then SDL_GPULoadOp.CLEAR else .DONT_CARE;
        depth.stencil_store_op = .DONT_CARE;
        depth.clear_stencil = 0;
        render_pass := SDL_BeginGPURenderPass(command_buffer, *target, 1, *depth);

        if pass.first_batch < last_batch {
            binding := SDL_GPUBufferBinding.{buffer = renderer.vertex_buffer};
            SDL_PushGPUVertexUniformData(command_buffer, 0, *pass.projection, size_of(Projection_Uniform));
            clip := NO_CLIP;
            SDL_PushGPUVertexUniformData(command_buffer, 1, *clip, size_of(Clip_Plane));
            current: *SDL_GPUGraphicsPipeline;
            stencil := -1;
            in_overlay := false;
            for b: pass.first_batch..last_batch-1 {
                batch := *renderer.batches[b];
                pipeline := ifx batch.points then renderer.points else renderer.triangles;
                if view.world  pipeline = ifx view.rgb then renderer.world_rgb_pipelines[batch.world_draw] else renderer.world_pipelines[batch.world_draw];
                if pipeline != current {
                    SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
                    SDL_BindGPUVertexBuffers(render_pass, 0, *binding, 1);
                    current = pipeline;
                }
                if view.world {
                    if batch.stencil != stencil {
                        SDL_SetGPUStencilReference(render_pass, batch.stencil);
                        stencil = batch.stencil;
                    }
                    // The overlay is drawn flat, in its own rectangle.
                    overlay := batch.world_draw == .OVERLAY;
                    if overlay != in_overlay {
                        projection := ifx overlay then pass.overlay else pass.projection;
                        SDL_PushGPUVertexUniformData(command_buffer, 0, *projection, size_of(Projection_Uniform));
                        in_overlay = overlay;
                    }
                }
                if memcmp(*batch.clip, *clip, size_of(Clip_Plane)) != 0 {
                    clip = batch.clip;
                    SDL_PushGPUVertexUniformData(command_buffer, 1, *clip, size_of(Clip_Plane));
                }
                samplers: [3] SDL_GPUTextureSamplerBinding;
                samplers[0] = .{texture = ifx batch.image then batch.image else renderer.blank_image.texture, sampler = renderer.sampler};
                samplers[1] = .{texture = pass.colormap, sampler = renderer.sampler};
                samplers[2] = .{texture = view.light_table, sampler = renderer.sampler};
                SDL_BindGPUFragmentSamplers(render_pass, 0, samplers.data, xx ifx view.rgb then 3 else 2);
                uniform := make_lighting_uniform(batch.lighting);
                uniform.light_only = xx pass.light_only;
                uniform.sky = batch.sky;
                SDL_PushGPUFragmentUniformData(command_buffer, 0, *uniform, size_of(Lighting_Uniform));
                SDL_DrawGPUPrimitives(render_pass, batch.count, 1, batch.first, 0);
            }
        }
        SDL_EndGPURenderPass(render_pass);

        output: SDL_GPUColorTargetInfo;
        output.texture  = view.color;
        output.load_op  = .DONT_CARE;
        output.store_op = .STORE;
        resolve_pass := SDL_BeginGPURenderPass(command_buffer, *output, 1, null);
        if view.rgb {
            // Linear color to sRGB, dithered, with no fade.
            SDL_BindGPUGraphicsPipeline(resolve_pass, renderer.film_output);
            images: [2] SDL_GPUTextureSamplerBinding;
            images[0] = .{texture = view.scene, sampler = renderer.sampler};
            images[1] = images[0];
            SDL_BindGPUFragmentSamplers(resolve_pass, 0, images.data, 2);
            params := Output_Uniform.{params = .[xx Film_Fade.NONE, 1, 0, 0]};
            SDL_PushGPUFragmentUniformData(command_buffer, 0, *params, size_of(Output_Uniform));
            SDL_DrawGPUPrimitives(resolve_pass, 3, 1, 0, 0);
            SDL_EndGPURenderPass(resolve_pass);
            continue;
        }
        SDL_BindGPUGraphicsPipeline(resolve_pass, renderer.resolve);
        textures: [2] SDL_GPUTextureSamplerBinding;
        textures[0] = .{texture = view.indices, sampler = renderer.sampler};
        textures[1] = .{texture = view.palette, sampler = renderer.sampler};
        SDL_BindGPUFragmentSamplers(resolve_pass, 0, textures.data, 2);
        SDL_PushGPUFragmentUniformData(command_buffer, 0, *pass.background, size_of(type_of(pass.background)));
        SDL_DrawGPUPrimitives(resolve_pass, 3, 1, 0, 0);
        SDL_EndGPURenderPass(resolve_pass);
    }
}

#load "lighting.jai";
#load "film.jai";
#load "world.jai";

#scope_module

// #run,host, so that a cross build reads the files on the build machine. Its procedure sees
// nothing outside itself, hence the imports in each.
SCENE_VERT_SPV        :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/scene.vert.spv", #filepath)); }
SCENE_POINTS_VERT_SPV :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/scene_points.vert.spv", #filepath)); }
FILM_VERT_SPV         :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/film.vert.spv", #filepath)); }
FILM_FRAG_SPV         :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/film.frag.spv", #filepath)); }
FILM_RESOLVE_FRAG_SPV :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/film_resolve.frag.spv", #filepath)); }
FILM_RGB_FRAG_SPV     :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/film_rgb.frag.spv", #filepath)); }
FILM_OUTPUT_FRAG_SPV  :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/film_output.frag.spv", #filepath)); }
SCENE_RGB_FRAG_SPV    :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/scene_rgb.frag.spv", #filepath)); }
SCENE_FRAG_SPV        :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/scene.frag.spv", #filepath)); }
RESOLVE_VERT_SPV      :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/resolve.vert.spv", #filepath)); }
RESOLVE_FRAG_SPV      :: #run,host -> string { #import "Basic"; #import "File"; return read_entire_file(tprint("%shaders/resolve.frag.spv", #filepath)); }

Projection_Uniform :: struct {
    scale_offset: [4] float;
    depth_range:  [4] float;
}

Lighting_Uniform :: struct {
    sector_ambient: s32;
    scaled_ambient: s32;
    world_ambient:  s32;
    headlight:      s32;
    light_offset:   s32;
    light_only:     s32;
    pad: [2] s32;
    sky: Sky;
}

// The film output pass's uniform (film.frag.hlsl, OUTPUT).
Output_Uniform :: struct {
    params:   [4] s32;      // Fade, dither, sharpen.
    fraction: [4] float;
}

Pass :: struct {
    view:        *View;
    colormap:    *SDL_GPUTexture;
    projection:  Projection_Uniform;
    overlay:     Projection_Uniform;
    background:  [4] float;
    light_only:  bool;
    first_batch: u32;
}

Batch :: struct {
    image:    *SDL_GPUTexture;
    lighting: Lighting;
    sky:      Sky;
    points:   bool;
    world_draw: World_Draw;     // Only for world views.
    stencil:  u8;
    clip:     Clip_Plane;
    first, count: u32;
}

renderer: struct {
    device: *SDL_GPUDevice;
    ready:  bool;
    depth_format: SDL_GPUTextureFormat;
    stencil_format: SDL_GPUTextureFormat;   // World views': depth and stencil.
    world_pipelines: [#run enum_highest_value(World_Draw) + 1] *SDL_GPUGraphicsPipeline;
    world_rgb_pipelines: [#run enum_highest_value(World_Draw) + 1] *SDL_GPUGraphicsPipeline;
    triangles, points, resolve, film, film_resolve, film_rgb, film_output: *SDL_GPUGraphicsPipeline;
    sampler: *SDL_GPUSampler;
    blank_image: Gpu_Image;
    identity_colormap: Gpu_Colormap;
    blank_table: *SDL_GPUTexture;

    vertex_buffer:   *SDL_GPUBuffer;
    vertex_transfer: *SDL_GPUTransferBuffer;
    vertex_capacity: u32;

    // This frame's recording.
    vertices: [..] Render_Vertex;
    passes:   [..] Pass;
    batches:  [..] Batch;
    film_ops: [..] Film_Op;
    uploads:  [..] Upload;      // This frame's render_update_image calls.
    lighting: Lighting;
    image:    *SDL_GPUTexture;
    world_draw: World_Draw;
    stencil:  u8;
    sky:      Sky;
    clip:     Clip_Plane;
};

Upload :: struct {
    texture:  *SDL_GPUTexture;
    transfer: *SDL_GPUTransferBuffer;
    width, height: s32;
}

// In one copy pass, before anything draws with them.
run_uploads :: (command_buffer: *SDL_GPUCommandBuffer) {
    if !renderer.uploads return;
    copy := SDL_BeginGPUCopyPass(command_buffer);
    for renderer.uploads {
        source := SDL_GPUTextureTransferInfo.{transfer_buffer = it.transfer};
        region := SDL_GPUTextureRegion.{texture = it.texture, w = xx it.width, h = xx it.height, d = 1};
        SDL_UploadToGPUTexture(copy, *source, *region, true);
    }
    SDL_EndGPUCopyPass(copy);
    array_reset_keeping_memory(*renderer.uploads);
}

// The light table of an RGB view (scene.frag.hlsl): rows 0-31 each entry's color at that
// light level (Light_Fit's curves), row 31 the palette itself; row 32 the light-only view's
// scale by level (red) and the smoothed light ramp (blue). Without a colormap, the identity:
// every level as it is.
LIGHT_TABLE_ROWS :: LIGHT_LEVELS + 1;

upload_light_table :: (view: *View, palette: *Palette, colormap: *Colormap) {
    WIDTH :: 256;
    identity: Colormap;
    if !colormap {
        for * level: identity.levels  for * level.* it.* = cast(u8) it_index;
        colormap = *identity;
    }
    fit := New(Light_Fit,, temp);
    fit.* = fit_light(palette, colormap);
    texels := NewArray(WIDTH * LIGHT_TABLE_ROWS * 4, float,, temp);
    for level: 0..LIGHT_LEVELS-1  for i: 0..255 {
        texel := texels.data + (level * WIDTH + i) * 4;
        c := fit.curves[level][i];
        texel[0], texel[1], texel[2], texel[3] = c.x, c.y, c.z, 1;
    }
    row := texels.data + LIGHT_LEVELS * WIDTH * 4;
    for 0..LIGHT_LEVELS-1  row[it * 4] = fit.scale[it];
    for 0..LIGHT_RAMP_COUNT-1  row[it * 4 + 2] = fit.ramp[it];
    if !view.light_table  view.light_table = create_texture(WIDTH, LIGHT_TABLE_ROWS, .R32G32B32A32_FLOAT, SDL_GPU_TEXTUREUSAGE_SAMPLER);
    upload_texture(view.light_table, WIDTH, LIGHT_TABLE_ROWS, texels.data, texels.count * size_of(float));
}

srgb_to_linear :: (v: float) -> float {
    if v <= 0.04045 return v / 12.92;
    return pow((v + 0.055) / 1.055, 2.4);
}

make_lighting_uniform :: (l: Lighting) -> Lighting_Uniform {
    u: Lighting_Uniform;
    u.sector_ambient = l.sector_ambient;
    u.scaled_ambient = get_scaled_ambient(l.sector_ambient);
    u.world_ambient  = l.world_ambient;
    u.headlight      = xx l.headlight;
    u.light_offset   = l.light_offset;
    return u;
}

add_vertices :: (vertices: [] Render_Vertex, points: bool) {
    if !vertices || !renderer.passes return;
    last := ifx renderer.batches.count > renderer.passes[renderer.passes.count - 1].first_batch then *renderer.batches[renderer.batches.count - 1] else null;
    world_draw := ifx points then World_Draw.POINTS else renderer.world_draw;
    if !last || last.image != renderer.image || last.points != points || last.world_draw != world_draw || last.stencil != renderer.stencil || memcmp(*last.clip, *renderer.clip, size_of(Clip_Plane)) != 0
       || memcmp(*last.lighting, *renderer.lighting, size_of(Lighting)) != 0 || memcmp(*last.sky, *renderer.sky, size_of(Sky)) != 0 {
        last = array_add(*renderer.batches);
        last.image    = renderer.image;
        last.lighting = renderer.lighting;
        last.points   = points;
        last.world_draw = world_draw;
        last.stencil  = renderer.stencil;
        last.sky      = renderer.sky;
        last.clip     = renderer.clip;
        last.first    = xx renderer.vertices.count;
    }
    array_add(*renderer.vertices, ..vertices);
    last.count += xx vertices.count;
}

create_shader :: (code: string, stage: SDL_GPUShaderStage, samplers: u32, uniforms: u32) -> *SDL_GPUShader {
    info: SDL_GPUShaderCreateInfo;
    info.code_size = xx code.count;
    info.code = code.data;
    info.entrypoint = "main".data;
    info.format = SDL_GPU_SHADERFORMAT_SPIRV;
    info.stage = stage;
    info.num_samplers = samplers;
    info.num_uniform_buffers = uniforms;
    shader := SDL_CreateGPUShader(renderer.device, *info);
    if !shader log_error("SDL_CreateGPUShader failed: %", to_string(SDL_GetError()));
    return shader;
}

// world: for world views, the pipeline of that kind of draw (see World_Draw).
create_scene_pipeline :: (vertex: *SDL_GPUShader, fragment: *SDL_GPUShader, primitive: SDL_GPUPrimitiveType, world: World_Draw = .NONE, format := SDL_GPUTextureFormat.R16_UNORM) -> *SDL_GPUGraphicsPipeline {
    buffer: SDL_GPUVertexBufferDescription;
    buffer.slot = 0;
    buffer.input_rate = .VERTEX;
    buffer.pitch = size_of(Render_Vertex);

    #assert size_of(Render_Vertex) == 32;
    attributes: [5] SDL_GPUVertexAttribute;
    attributes[0] = .{location = 0, buffer_slot = 0, format = .FLOAT3, offset = 0};
    attributes[1] = .{location = 1, buffer_slot = 0, format = .FLOAT2, offset = 12};
    attributes[2] = .{location = 2, buffer_slot = 0, format = .FLOAT,  offset = 20};
    attributes[3] = .{location = 3, buffer_slot = 0, format = .FLOAT,  offset = 24};
    attributes[4] = .{location = 4, buffer_slot = 0, format = .UINT,   offset = 28};

    color: SDL_GPUColorTargetDescription;
    color.format = format;

    info: SDL_GPUGraphicsPipelineCreateInfo;
    info.vertex_shader   = vertex;
    info.fragment_shader = fragment;
    info.vertex_input_state.vertex_buffer_descriptions = *buffer;
    info.vertex_input_state.num_vertex_buffers = 1;
    info.vertex_input_state.vertex_attributes = attributes.data;
    info.vertex_input_state.num_vertex_attributes = attributes.count;
    info.primitive_type = primitive;
    info.rasterizer_state.fill_mode = .FILL;
    info.rasterizer_state.cull_mode = .NONE;     // Callers cull the way the original does.
    info.depth_stencil_state.enable_depth_test  = true;
    info.depth_stencil_state.enable_depth_write = true;
    info.depth_stencil_state.compare_op = .LESS_OR_EQUAL;
    info.target_info.color_target_descriptions = *color;
    info.target_info.num_color_targets = 1;
    info.target_info.depth_stencil_format = renderer.depth_format;
    info.target_info.has_depth_stencil_target = true;
    if world != .NONE  set_world_pipeline_state(*info, *color, world);

    pipeline := SDL_CreateGPUGraphicsPipeline(renderer.device, *info);
    if !pipeline log_error("SDL_CreateGPUGraphicsPipeline failed: %", to_string(SDL_GetError()));
    return pipeline;
}

create_resolve_pipeline :: (vertex: *SDL_GPUShader, fragment: *SDL_GPUShader) -> *SDL_GPUGraphicsPipeline {
    color: SDL_GPUColorTargetDescription;
    color.format = .R8G8B8A8_UNORM;
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

create_texture :: (width: s32, height: s32, format: SDL_GPUTextureFormat, usage: SDL_GPUTextureUsageFlags) -> *SDL_GPUTexture {
    info: SDL_GPUTextureCreateInfo;
    info.type   = ._2D;
    info.format = format;
    info.usage  = usage;
    info.width  = xx width;
    info.height = xx height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = ._1;
    texture := SDL_CreateGPUTexture(renderer.device, *info);
    if !texture log_error("SDL_CreateGPUTexture failed: %", to_string(SDL_GetError()));
    return texture;
}

// Uploads right away on a command buffer of its own, as ImGui's backend does for its fonts.
upload_texture :: (texture: *SDL_GPUTexture, width: s32, height: s32, data: *void, size: s64) {
    if !texture return;
    device := renderer.device;
    transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .UPLOAD, size = xx size};
    transfer := SDL_CreateGPUTransferBuffer(device, *transfer_info);
    mapped := map_transfer_or_exit(transfer, false);
    memcpy(mapped, data, size);
    SDL_UnmapGPUTransferBuffer(device, transfer);

    source := SDL_GPUTextureTransferInfo.{transfer_buffer = transfer};
    region := SDL_GPUTextureRegion.{texture = texture, w = xx width, h = xx height, d = 1};
    command_buffer := SDL_AcquireGPUCommandBuffer(device);
    copy := SDL_BeginGPUCopyPass(command_buffer);
    SDL_UploadToGPUTexture(copy, *source, *region, false);
    SDL_EndGPUCopyPass(copy);
    SDL_SubmitGPUCommandBuffer(command_buffer);
    SDL_ReleaseGPUTransferBuffer(device, transfer);
}

// Maps a transfer buffer, or, when there's none or it won't map, tells the player why and
// quits: nothing can be drawn without it, and going on would write through a null pointer.
// The usual cause is the open-file limit: NVIDIA's Linux driver holds a file descriptor for
// every block of GPU memory, and a level's art takes over a thousand.
map_transfer_or_exit :: (transfer: *SDL_GPUTransferBuffer, cycle: bool) -> *void {
    mapped: *void;
    if transfer  mapped = SDL_MapGPUTransferBuffer(renderer.device, transfer, cycle);
    if mapped return mapped;
    error := to_string(SDL_GetError());
    print("Couldn't get GPU memory: %\n", error);
    message := tprint(#string END
jaidi couldn't get the graphics memory it needs and has to quit.

The graphics driver refused to give more: either the graphics card is out of memory, or the system limits how many files a program may have open (some graphics drivers use one for each block of graphics memory). Closing other programs may help; on Linux, raising the open-file limit (ulimit -n) does.

The driver said: %
END, error);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "jaidi", temp_c_string(message), null);
    exit(1);
    return null;
}

#import "Basic";
#import "File";
#import "Math";
#import "engine/vendor/SDL3";
#import "engine/dfImage";
