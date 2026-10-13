// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Native-Jai port of Dear ImGui's SDL_GPU renderer backend
// (imgui_impl_sdlgpu3.cpp, version 1.92.8-docking). Paired with the SDL3
// platform backend in imgui_impl_sdl3.jai.
//
// Unlike other backends, the caller MUST call ImGui_ImplSDLGPU3_PrepareDrawData()
// BEFORE beginning the SDL_GPU render pass that contains
// ImGui_ImplSDLGPU3_RenderDrawData() (SDL_GPU forbids copy passes while a render
// pass is bound).

// Initialization data, for ImGui_ImplSDLGPU3_Init().
ImGui_ImplSDLGPU3_InitInfo :: struct {
    Device:               *SDL_GPUDevice;
    ColorTargetFormat:    SDL_GPUTextureFormat;
    MSAASamples:          SDL_GPUSampleCount          = ._1;
    SwapchainComposition: SDL_GPUSwapchainComposition = .SDR;        // Only used in multi-viewports mode.
    PresentMode:          SDL_GPUPresentMode          = .VSYNC;      // Only used in multi-viewports mode.
}

// Selected render state shared with draw callbacks (mirrors the C++ struct).
ImGui_ImplSDLGPU3_RenderState :: struct {
    Device: *SDL_GPUDevice;
}

#scope_module

// Reusable buffers for one in-flight frame.
ImGui_ImplSDLGPU3_FrameData :: struct {
    VertexBuffer:         *SDL_GPUBuffer;
    VertexTransferBuffer: *SDL_GPUTransferBuffer;
    VertexBufferSize:     u32;
    IndexBuffer:          *SDL_GPUBuffer;
    IndexTransferBuffer:  *SDL_GPUTransferBuffer;
    IndexBufferSize:      u32;
}

ImGui_ImplSDLGPU3_Data :: struct {
    InitInfo:          ImGui_ImplSDLGPU3_InitInfo;

    RenderState:       *ImGui_ImplSDLGPU3_RenderState;
    CurrentSampler:    *SDL_GPUSampler;

    VertexShader:      *SDL_GPUShader;
    FragmentShader:    *SDL_GPUShader;
    Pipeline:          *SDL_GPUGraphicsPipeline;
    TexSamplerLinear:  *SDL_GPUSampler;
    TexSamplerNearest: *SDL_GPUSampler;
    TexTransferBuffer: *SDL_GPUTransferBuffer;
    TexTransferBufferSize: u32;

    MainWindowFrameData: ImGui_ImplSDLGPU3_FrameData;
}

Vertex_UBO :: struct {
    scale:       [2] float;
    translation: [2] float;
}

get_backend_data :: () -> *ImGui_ImplSDLGPU3_Data #c_call {
    if ImGui.GetCurrentContext() then return cast(*ImGui_ImplSDLGPU3_Data) ImGui.GetIO().BackendRendererUserData;
    return null;
}

// --- Small inline helpers ImGui defines on its types (not in the bindings) ---

tex_get_id     :: (tex: *ImTextureData) -> ImTextureID { return tex.TexID; }
tex_set_id     :: (tex: *ImTextureData, id: ImTextureID) { tex.TexID = id; }
tex_set_status :: (tex: *ImTextureData, s: ImTextureStatus) { tex.Status = s; }
tex_pixels_at  :: (tex: *ImTextureData, x: int, y: int) -> *u8 {
    return tex.Pixels + (x + y * tex.Width) * tex.BytesPerPixel;
}
cmd_get_tex_id :: (cmd: *ImDrawCmd) -> ImTextureID {
    return ifx cmd.TexRef._TexData then cmd.TexRef._TexData.TexID else cmd.TexRef._TexID;
}

setup_render_state :: (draw_data: *ImDrawData, pipeline: *SDL_GPUGraphicsPipeline, command_buffer: *SDL_GPUCommandBuffer, render_pass: *SDL_GPURenderPass, fd: *ImGui_ImplSDLGPU3_FrameData, fb_width: u32, fb_height: u32) {
    bd := get_backend_data();
    bd.CurrentSampler = bd.TexSamplerLinear;

    SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

    if draw_data.TotalVtxCount > 0 {
        vertex_buffer_binding: SDL_GPUBufferBinding;
        vertex_buffer_binding.buffer = fd.VertexBuffer;
        vertex_buffer_binding.offset = 0;
        index_buffer_binding: SDL_GPUBufferBinding;
        index_buffer_binding.buffer = fd.IndexBuffer;
        index_buffer_binding.offset = 0;
        SDL_BindGPUVertexBuffers(render_pass, 0, *vertex_buffer_binding, 1);
        size: SDL_GPUIndexElementSize = ifx size_of(ImDrawIdx) == 2 then ._16BIT else ._32BIT;
        SDL_BindGPUIndexBuffer(render_pass, *index_buffer_binding, size);
    }

    viewport: SDL_GPUViewport;
    viewport.x = 0;
    viewport.y = 0;
    viewport.w = cast(float) fb_width;
    viewport.h = cast(float) fb_height;
    viewport.min_depth = 0.0;
    viewport.max_depth = 1.0;
    SDL_SetGPUViewport(render_pass, *viewport);

    ubo: Vertex_UBO;
    ubo.scale[0] = 2.0 / draw_data.DisplaySize.x;
    ubo.scale[1] = 2.0 / draw_data.DisplaySize.y;
    ubo.translation[0] = -1.0 - draw_data.DisplayPos.x * ubo.scale[0];
    ubo.translation[1] = -1.0 - draw_data.DisplayPos.y * ubo.scale[1];
    SDL_PushGPUVertexUniformData(command_buffer, 0, *ubo, size_of(Vertex_UBO));
}

create_or_resize_buffers :: (buffer: **SDL_GPUBuffer, transferbuffer: **SDL_GPUTransferBuffer, old_size: *u32, new_size: u32, usage: SDL_GPUBufferUsageFlags) {
    bd := get_backend_data();
    v := *bd.InitInfo;

    SDL_ReleaseGPUBuffer(v.Device, buffer.*);
    SDL_ReleaseGPUTransferBuffer(v.Device, transferbuffer.*);

    buffer_info: SDL_GPUBufferCreateInfo;
    buffer_info.usage = usage;
    buffer_info.size  = new_size;
    buffer_info.props = 0;
    buffer.* = SDL_CreateGPUBuffer(v.Device, *buffer_info);
    old_size.* = new_size;
    assert(buffer.* != null, "Failed to create GPU buffer: %", to_string(SDL_GetError()));

    transferbuffer_info: SDL_GPUTransferBufferCreateInfo;
    transferbuffer_info.usage = .UPLOAD;
    transferbuffer_info.size  = new_size;
    transferbuffer.* = SDL_CreateGPUTransferBuffer(v.Device, *transferbuffer_info);
    assert(transferbuffer.* != null, "Failed to create GPU transfer buffer: %", to_string(SDL_GetError()));
}

ImGui_ImplSDLGPU3_PrepareDrawData :: (draw_data: *ImDrawData, command_buffer: *SDL_GPUCommandBuffer) {
    fb_width  := cast(int)(draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
    fb_height := cast(int)(draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
    if fb_width <= 0 || fb_height <= 0 || draw_data.TotalVtxCount <= 0 return;

    // Catch up with texture updates (dynamic font atlas).
    if draw_data.Textures != null {
        for i: 0..draw_data.Textures.Size - 1 {
            tex := draw_data.Textures.Data[i];
            if tex.Status != .OK  ImGui_ImplSDLGPU3_UpdateTexture(tex);
        }
    }

    bd := get_backend_data();
    v  := *bd.InitInfo;
    fd := *bd.MainWindowFrameData;

    vertex_size := cast(u32)(draw_data.TotalVtxCount * size_of(ImDrawVert));
    index_size  := cast(u32)(draw_data.TotalIdxCount * size_of(ImDrawIdx));
    if fd.VertexBuffer == null || fd.VertexBufferSize < vertex_size
        create_or_resize_buffers(*fd.VertexBuffer, *fd.VertexTransferBuffer, *fd.VertexBufferSize, vertex_size, SDL_GPU_BUFFERUSAGE_VERTEX);
    if fd.IndexBuffer == null || fd.IndexBufferSize < index_size
        create_or_resize_buffers(*fd.IndexBuffer, *fd.IndexTransferBuffer, *fd.IndexBufferSize, index_size, SDL_GPU_BUFFERUSAGE_INDEX);

    vtx_dst := cast(*ImDrawVert) SDL_MapGPUTransferBuffer(v.Device, fd.VertexTransferBuffer, true);
    idx_dst := cast(*ImDrawIdx)  SDL_MapGPUTransferBuffer(v.Device, fd.IndexTransferBuffer, true);
    for i: 0..draw_data.CmdListsCount - 1 {
        draw_list := draw_data.CmdLists.Data[i];
        memcpy(vtx_dst, draw_list.VtxBuffer.Data, draw_list.VtxBuffer.Size * size_of(ImDrawVert));
        memcpy(idx_dst, draw_list.IdxBuffer.Data, draw_list.IdxBuffer.Size * size_of(ImDrawIdx));
        vtx_dst += draw_list.VtxBuffer.Size;
        idx_dst += draw_list.IdxBuffer.Size;
    }
    SDL_UnmapGPUTransferBuffer(v.Device, fd.VertexTransferBuffer);
    SDL_UnmapGPUTransferBuffer(v.Device, fd.IndexTransferBuffer);

    vertex_buffer_location: SDL_GPUTransferBufferLocation;
    vertex_buffer_location.offset = 0;
    vertex_buffer_location.transfer_buffer = fd.VertexTransferBuffer;
    index_buffer_location: SDL_GPUTransferBufferLocation;
    index_buffer_location.offset = 0;
    index_buffer_location.transfer_buffer = fd.IndexTransferBuffer;

    vertex_buffer_region: SDL_GPUBufferRegion;
    vertex_buffer_region.buffer = fd.VertexBuffer;
    vertex_buffer_region.offset = 0;
    vertex_buffer_region.size   = vertex_size;
    index_buffer_region: SDL_GPUBufferRegion;
    index_buffer_region.buffer = fd.IndexBuffer;
    index_buffer_region.offset = 0;
    index_buffer_region.size   = index_size;

    copy_pass := SDL_BeginGPUCopyPass(command_buffer);
    SDL_UploadToGPUBuffer(copy_pass, *vertex_buffer_location, *vertex_buffer_region, true);
    SDL_UploadToGPUBuffer(copy_pass, *index_buffer_location, *index_buffer_region, true);
    SDL_EndGPUCopyPass(copy_pass);
}

draw_callback_reset_render_state  :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call {} // identifier only
draw_callback_set_sampler_linear  :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call { bd := get_backend_data(); bd.CurrentSampler = bd.TexSamplerLinear; }
draw_callback_set_sampler_nearest :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call { bd := get_backend_data(); bd.CurrentSampler = bd.TexSamplerNearest; }

ImGui_ImplSDLGPU3_RenderDrawData :: (draw_data: *ImDrawData, command_buffer: *SDL_GPUCommandBuffer, render_pass: *SDL_GPURenderPass, pipeline: *SDL_GPUGraphicsPipeline = null) {
    fb_width  := cast(int)(draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
    fb_height := cast(int)(draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
    if fb_width <= 0 || fb_height <= 0 return;

    bd := get_backend_data();
    fd := *bd.MainWindowFrameData;

    if pipeline == null  pipeline = bd.Pipeline;

    clip_off   := draw_data.DisplayPos;
    clip_scale := draw_data.FramebufferScale;

    platform_io := ImGui.GetPlatformIO();
    render_state: ImGui_ImplSDLGPU3_RenderState;
    render_state.Device = bd.InitInfo.Device;
    bd.RenderState = *render_state;
    platform_io.Renderer_RenderState = *render_state;

    setup_render_state(draw_data, pipeline, command_buffer, render_pass, fd, cast(u32) fb_width, cast(u32) fb_height);

    global_vtx_offset := 0;
    global_idx_offset := 0;
    for li: 0..draw_data.CmdListsCount - 1 {
        draw_list := draw_data.CmdLists.Data[li];
        for ci: 0..draw_list.CmdBuffer.Size - 1 {
            pcmd := *draw_list.CmdBuffer.Data[ci];
            if pcmd.UserCallback != null {
                if pcmd.UserCallback == draw_callback_reset_render_state
                    setup_render_state(draw_data, pipeline, command_buffer, render_pass, fd, cast(u32) fb_width, cast(u32) fb_height);
                else
                    pcmd.UserCallback(draw_list, pcmd);
            } else {
                clip_min_x := (pcmd.ClipRect.x - clip_off.x) * clip_scale.x;
                clip_min_y := (pcmd.ClipRect.y - clip_off.y) * clip_scale.y;
                clip_max_x := (pcmd.ClipRect.z - clip_off.x) * clip_scale.x;
                clip_max_y := (pcmd.ClipRect.w - clip_off.y) * clip_scale.y;

                if clip_min_x < 0.0  clip_min_x = 0.0;
                if clip_min_y < 0.0  clip_min_y = 0.0;
                if clip_max_x > cast(float) fb_width   clip_max_x = cast(float) fb_width;
                if clip_max_y > cast(float) fb_height  clip_max_y = cast(float) fb_height;
                if clip_max_x <= clip_min_x || clip_max_y <= clip_min_y  continue;

                scissor_rect: SDL_Rect;
                scissor_rect.x = cast(s32) clip_min_x;
                scissor_rect.y = cast(s32) clip_min_y;
                scissor_rect.w = cast(s32)(clip_max_x - clip_min_x);
                scissor_rect.h = cast(s32)(clip_max_y - clip_min_y);
                SDL_SetGPUScissor(render_pass, *scissor_rect);

                binding: SDL_GPUTextureSamplerBinding;
                binding.texture = cast(*SDL_GPUTexture) cmd_get_tex_id(pcmd);
                binding.sampler = bd.CurrentSampler;
                SDL_BindGPUFragmentSamplers(render_pass, 0, *binding, 1);

                SDL_DrawGPUIndexedPrimitives(render_pass, pcmd.ElemCount, 1, cast(u32)(pcmd.IdxOffset + cast(u32) global_idx_offset), cast(s32)(pcmd.VtxOffset + cast(u32) global_vtx_offset), 0);
            }
        }
        global_idx_offset += draw_list.IdxBuffer.Size;
        global_vtx_offset += draw_list.VtxBuffer.Size;
    }

    full_scissor: SDL_Rect;
    full_scissor.x = 0;
    full_scissor.y = 0;
    full_scissor.w = cast(s32) fb_width;
    full_scissor.h = cast(s32) fb_height;
    SDL_SetGPUScissor(render_pass, *full_scissor);

    bd.RenderState = null;
    platform_io.Renderer_RenderState = null;
}

destroy_texture :: (tex: *ImTextureData) {
    bd := get_backend_data();
    if tex_get_id(tex) != ImTextureID_Invalid {
        raw_tex := cast(*SDL_GPUTexture) tex_get_id(tex);
        if raw_tex  SDL_ReleaseGPUTexture(bd.InitInfo.Device, raw_tex);
    }
    tex_set_id(tex, ImTextureID_Invalid);
    tex_set_status(tex, .Destroyed);
}

ImGui_ImplSDLGPU3_UpdateTexture :: (tex: *ImTextureData) {
    bd := get_backend_data();
    v  := *bd.InitInfo;

    if tex.Status == .WantCreate {
        assert(tex.TexID == ImTextureID_Invalid && tex.BackendUserData == null);
        assert(tex.Format == .RGBA32);

        texture_info: SDL_GPUTextureCreateInfo;
        texture_info.type   = ._2D;
        texture_info.format = .R8G8B8A8_UNORM;
        texture_info.usage  = SDL_GPU_TEXTUREUSAGE_SAMPLER;
        texture_info.width  = cast(u32) tex.Width;
        texture_info.height = cast(u32) tex.Height;
        texture_info.layer_count_or_depth = 1;
        texture_info.num_levels = 1;
        texture_info.sample_count = ._1;

        raw_tex := SDL_CreateGPUTexture(v.Device, *texture_info);
        assert(raw_tex != null, "Failed to create texture: %", to_string(SDL_GetError()));
        tex_set_id(tex, cast(ImTextureID) raw_tex);
    }

    if tex.Status == .WantCreate || tex.Status == .WantUpdates {
        raw_tex := cast(*SDL_GPUTexture) tex_get_id(tex);
        assert(tex.Format == .RGBA32);

        upload_x := ifx tex.Status == .WantCreate then 0 else cast(int) tex.UpdateRect.x;
        upload_y := ifx tex.Status == .WantCreate then 0 else cast(int) tex.UpdateRect.y;
        upload_w := ifx tex.Status == .WantCreate then cast(int) tex.Width  else cast(int) tex.UpdateRect.w;
        upload_h := ifx tex.Status == .WantCreate then cast(int) tex.Height else cast(int) tex.UpdateRect.h;
        upload_pitch := cast(u32)(upload_w * tex.BytesPerPixel);
        upload_size  := cast(u32)(upload_w * upload_h * tex.BytesPerPixel);

        if bd.TexTransferBufferSize < upload_size {
            SDL_ReleaseGPUTransferBuffer(v.Device, bd.TexTransferBuffer);
            transferbuffer_info: SDL_GPUTransferBufferCreateInfo;
            transferbuffer_info.usage = .UPLOAD;
            transferbuffer_info.size  = upload_size + 1024;
            bd.TexTransferBufferSize  = upload_size + 1024;
            bd.TexTransferBuffer = SDL_CreateGPUTransferBuffer(v.Device, *transferbuffer_info);
            assert(bd.TexTransferBuffer != null, "Failed to create transfer buffer: %", to_string(SDL_GetError()));
        }

        texture_ptr := SDL_MapGPUTransferBuffer(v.Device, bd.TexTransferBuffer, true);
        for y: 0..upload_h - 1 {
            dst := cast(*u8) texture_ptr + y * upload_pitch;
            memcpy(dst, tex_pixels_at(tex, upload_x, upload_y + y), upload_pitch);
        }
        SDL_UnmapGPUTransferBuffer(v.Device, bd.TexTransferBuffer);

        transfer_info: SDL_GPUTextureTransferInfo;
        transfer_info.offset = 0;
        transfer_info.transfer_buffer = bd.TexTransferBuffer;

        texture_region: SDL_GPUTextureRegion;
        texture_region.texture = raw_tex;
        texture_region.x = cast(u32) upload_x;
        texture_region.y = cast(u32) upload_y;
        texture_region.w = cast(u32) upload_w;
        texture_region.h = cast(u32) upload_h;
        texture_region.d = 1;

        cmd := SDL_AcquireGPUCommandBuffer(v.Device);
        copy_pass := SDL_BeginGPUCopyPass(cmd);
        SDL_UploadToGPUTexture(copy_pass, *transfer_info, *texture_region, false);
        SDL_EndGPUCopyPass(copy_pass);
        SDL_SubmitGPUCommandBuffer(cmd);

        tex_set_status(tex, .OK);
    }

    if tex.Status == .WantDestroy && tex.UnusedFrames > 0  destroy_texture(tex);
}

create_shaders :: () {
    bd := get_backend_data();
    v  := *bd.InitInfo;

    driver := to_string(SDL_GetGPUDeviceDriver(v.Device));

    vertex_shader_info: SDL_GPUShaderCreateInfo;
    vertex_shader_info.entrypoint = "main".data;
    vertex_shader_info.stage = .VERTEX;
    vertex_shader_info.num_uniform_buffers = 1;

    fragment_shader_info: SDL_GPUShaderCreateInfo;
    fragment_shader_info.entrypoint = "main".data;
    fragment_shader_info.stage = .FRAGMENT;
    fragment_shader_info.num_samplers = 1;

    if driver == "vulkan" {
        vertex_shader_info.format    = SDL_GPU_SHADERFORMAT_SPIRV;
        vertex_shader_info.code      = spirv_vertex.data;
        vertex_shader_info.code_size = spirv_vertex.count;
        fragment_shader_info.format    = SDL_GPU_SHADERFORMAT_SPIRV;
        fragment_shader_info.code      = spirv_fragment.data;
        fragment_shader_info.code_size = spirv_fragment.count;
    } else if driver == "direct3d12" {
        vertex_shader_info.format    = SDL_GPU_SHADERFORMAT_DXBC;
        vertex_shader_info.code      = dxbc_vertex.data;
        vertex_shader_info.code_size = dxbc_vertex.count;
        fragment_shader_info.format    = SDL_GPU_SHADERFORMAT_DXBC;
        fragment_shader_info.code      = dxbc_fragment.data;
        fragment_shader_info.code_size = dxbc_fragment.count;
    } else {
        assert(false, "ImGui SDL_GPU backend: unsupported GPU driver '%' (need vulkan or direct3d12)", driver);
    }

    bd.VertexShader   = SDL_CreateGPUShader(v.Device, *vertex_shader_info);
    bd.FragmentShader = SDL_CreateGPUShader(v.Device, *fragment_shader_info);
    assert(bd.VertexShader != null,   "Failed to create vertex shader: %",   to_string(SDL_GetError()));
    assert(bd.FragmentShader != null, "Failed to create fragment shader: %", to_string(SDL_GetError()));
}

create_graphics_pipeline :: () {
    bd := get_backend_data();
    v  := *bd.InitInfo;
    create_shaders();

    vertex_buffer_desc: [1] SDL_GPUVertexBufferDescription;
    vertex_buffer_desc[0].slot = 0;
    vertex_buffer_desc[0].input_rate = .VERTEX;
    vertex_buffer_desc[0].instance_step_rate = 0;
    vertex_buffer_desc[0].pitch = size_of(ImDrawVert);

    dummy: ImDrawVert = ---;
    base   := cast(*u8) *dummy;
    off_pos := cast(u32)(cast(*u8) *dummy.pos - base);
    off_uv  := cast(u32)(cast(*u8) *dummy.uv  - base);
    off_col := cast(u32)(cast(*u8) *dummy.col - base);

    vertex_attributes: [3] SDL_GPUVertexAttribute;
    vertex_attributes[0].buffer_slot = 0;
    vertex_attributes[0].format = .FLOAT2;
    vertex_attributes[0].location = 0;
    vertex_attributes[0].offset = off_pos;
    vertex_attributes[1].buffer_slot = 0;
    vertex_attributes[1].format = .FLOAT2;
    vertex_attributes[1].location = 1;
    vertex_attributes[1].offset = off_uv;
    vertex_attributes[2].buffer_slot = 0;
    vertex_attributes[2].format = .UBYTE4_NORM;
    vertex_attributes[2].location = 2;
    vertex_attributes[2].offset = off_col;

    vertex_input_state: SDL_GPUVertexInputState;
    vertex_input_state.num_vertex_attributes = 3;
    vertex_input_state.vertex_attributes = vertex_attributes.data;
    vertex_input_state.num_vertex_buffers = 1;
    vertex_input_state.vertex_buffer_descriptions = vertex_buffer_desc.data;

    rasterizer_state: SDL_GPURasterizerState;
    rasterizer_state.fill_mode  = .FILL;
    rasterizer_state.cull_mode  = .NONE;
    rasterizer_state.front_face = .COUNTER_CLOCKWISE;
    rasterizer_state.enable_depth_bias = false;
    rasterizer_state.enable_depth_clip = false;

    multisample_state: SDL_GPUMultisampleState;
    multisample_state.sample_count = v.MSAASamples;
    multisample_state.enable_mask  = false;

    depth_stencil_state: SDL_GPUDepthStencilState;
    depth_stencil_state.enable_depth_test   = false;
    depth_stencil_state.enable_depth_write  = false;
    depth_stencil_state.enable_stencil_test = false;

    blend_state: SDL_GPUColorTargetBlendState;
    blend_state.enable_blend = true;
    blend_state.src_color_blendfactor = .SRC_ALPHA;
    blend_state.dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA;
    blend_state.color_blend_op = .ADD;
    blend_state.src_alpha_blendfactor = .ONE;
    blend_state.dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA;
    blend_state.alpha_blend_op = .ADD;
    blend_state.color_write_mask = cast(SDL_GPUColorComponentFlags)(SDL_GPU_COLORCOMPONENT_R | SDL_GPU_COLORCOMPONENT_G | SDL_GPU_COLORCOMPONENT_B | SDL_GPU_COLORCOMPONENT_A);

    color_target_desc: [1] SDL_GPUColorTargetDescription;
    color_target_desc[0].format = v.ColorTargetFormat;
    color_target_desc[0].blend_state = blend_state;

    target_info: SDL_GPUGraphicsPipelineTargetInfo;
    target_info.num_color_targets = 1;
    target_info.color_target_descriptions = color_target_desc.data;
    target_info.has_depth_stencil_target = false;

    pipeline_info: SDL_GPUGraphicsPipelineCreateInfo;
    pipeline_info.vertex_shader = bd.VertexShader;
    pipeline_info.fragment_shader = bd.FragmentShader;
    pipeline_info.vertex_input_state = vertex_input_state;
    pipeline_info.primitive_type = .TRIANGLELIST;
    pipeline_info.rasterizer_state = rasterizer_state;
    pipeline_info.multisample_state = multisample_state;
    pipeline_info.depth_stencil_state = depth_stencil_state;
    pipeline_info.target_info = target_info;

    bd.Pipeline = SDL_CreateGPUGraphicsPipeline(v.Device, *pipeline_info);
    assert(bd.Pipeline != null, "Failed to create graphics pipeline: %", to_string(SDL_GetError()));
}

ImGui_ImplSDLGPU3_CreateDeviceObjects :: () {
    bd := get_backend_data();
    v  := *bd.InitInfo;

    ImGui_ImplSDLGPU3_DestroyDeviceObjects();

    if bd.TexSamplerLinear == null {
        sampler_info: SDL_GPUSamplerCreateInfo;
        sampler_info.min_filter = .LINEAR;
        sampler_info.mag_filter = .LINEAR;
        sampler_info.mipmap_mode = .LINEAR;
        sampler_info.address_mode_u = .CLAMP_TO_EDGE;
        sampler_info.address_mode_v = .CLAMP_TO_EDGE;
        sampler_info.address_mode_w = .CLAMP_TO_EDGE;
        sampler_info.mip_lod_bias = 0.0;
        sampler_info.min_lod = -1000.0;
        sampler_info.max_lod = 1000.0;
        sampler_info.enable_anisotropy = false;
        sampler_info.max_anisotropy = 1.0;
        sampler_info.enable_compare = false;
        bd.TexSamplerLinear = SDL_CreateGPUSampler(v.Device, *sampler_info);
        assert(bd.TexSamplerLinear != null, "Failed to create sampler: %", to_string(SDL_GetError()));

        sampler_info.min_filter = .NEAREST;
        sampler_info.mag_filter = .NEAREST;
        sampler_info.mipmap_mode = .NEAREST;
        bd.TexSamplerNearest = SDL_CreateGPUSampler(v.Device, *sampler_info);
        assert(bd.TexSamplerNearest != null, "Failed to create sampler: %", to_string(SDL_GetError()));
    }

    create_graphics_pipeline();
}

destroy_frame_data :: () {
    bd := get_backend_data();
    v  := *bd.InitInfo;
    fd := *bd.MainWindowFrameData;
    SDL_ReleaseGPUBuffer(v.Device, fd.VertexBuffer);
    SDL_ReleaseGPUBuffer(v.Device, fd.IndexBuffer);
    SDL_ReleaseGPUTransferBuffer(v.Device, fd.VertexTransferBuffer);
    SDL_ReleaseGPUTransferBuffer(v.Device, fd.IndexTransferBuffer);
    fd.VertexBuffer = null;
    fd.IndexBuffer = null;
    fd.VertexTransferBuffer = null;
    fd.IndexTransferBuffer = null;
    fd.VertexBufferSize = 0;
    fd.IndexBufferSize = 0;
}

ImGui_ImplSDLGPU3_DestroyDeviceObjects :: () {
    bd := get_backend_data();
    v  := *bd.InitInfo;

    destroy_frame_data();

    platform_io := ImGui.GetPlatformIO();
    for i: 0..platform_io.Textures.Size - 1 {
        tex := platform_io.Textures.Data[i];
        if tex.RefCount == 1  destroy_texture(tex);
    }
    if bd.TexTransferBuffer { SDL_ReleaseGPUTransferBuffer(v.Device, bd.TexTransferBuffer); bd.TexTransferBuffer = null; }
    if bd.VertexShader      { SDL_ReleaseGPUShader(v.Device, bd.VertexShader); bd.VertexShader = null; }
    if bd.FragmentShader    { SDL_ReleaseGPUShader(v.Device, bd.FragmentShader); bd.FragmentShader = null; }
    if bd.TexSamplerLinear  { SDL_ReleaseGPUSampler(v.Device, bd.TexSamplerLinear); bd.TexSamplerLinear = null; }
    if bd.TexSamplerNearest { SDL_ReleaseGPUSampler(v.Device, bd.TexSamplerNearest); bd.TexSamplerNearest = null; }
    if bd.Pipeline          { SDL_ReleaseGPUGraphicsPipeline(v.Device, bd.Pipeline); bd.Pipeline = null; }
}

ImGui_ImplSDLGPU3_Init :: (info: *ImGui_ImplSDLGPU3_InitInfo) -> bool {
    io := ImGui.GetIO();
    assert(io.BackendRendererUserData == null, "Already initialized a renderer backend!");

    bd := New(ImGui_ImplSDLGPU3_Data);
    io.BackendRendererUserData = bd;
    io.BackendRendererName = "imgui_impl_sdlgpu3".data;
    io.BackendFlags |= .RendererHasVtxOffset;
    io.BackendFlags |= .RendererHasTextures;
    io.BackendFlags |= .RendererHasViewports;

    platform_io := ImGui.GetPlatformIO();
    platform_io.DrawCallback_ResetRenderState  = draw_callback_reset_render_state;
    platform_io.DrawCallback_SetSamplerLinear  = draw_callback_set_sampler_linear;
    platform_io.DrawCallback_SetSamplerNearest = draw_callback_set_sampler_nearest;

    assert(info.Device != null);
    assert(info.ColorTargetFormat != .INVALID);

    bd.InitInfo = info.*;

    init_multi_viewport_support();
    return true;
}

ImGui_ImplSDLGPU3_Shutdown :: () {
    bd := get_backend_data();
    assert(bd != null, "No renderer backend to shutdown, or already shutdown?");
    io := ImGui.GetIO();
    platform_io := ImGui.GetPlatformIO();

    shutdown_multi_viewport_support();
    ImGui_ImplSDLGPU3_DestroyDeviceObjects();

    io.BackendRendererName = null;
    io.BackendRendererUserData = null;
    io.BackendFlags &= ~(ImGuiBackendFlags.RendererHasVtxOffset | .RendererHasTextures | .RendererHasViewports);
    platform_io.ClearRendererHandlers(platform_io);
    free(bd);
}

ImGui_ImplSDLGPU3_NewFrame :: () {
    bd := get_backend_data();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplSDLGPU3_Init()?");
    if !bd.TexSamplerLinear  ImGui_ImplSDLGPU3_CreateDeviceObjects();
}

// --- Multi-viewport / platform interface support ---

renderer_create_window :: (viewport: *ImGuiViewport) #c_call {
    data := get_backend_data();
    window := SDL_GetWindowFromID(cast(SDL_WindowID)(cast(u64) viewport.PlatformHandle));
    SDL_ClaimWindowForGPUDevice(data.InitInfo.Device, window);
    SDL_SetGPUSwapchainParameters(data.InitInfo.Device, window, data.InitInfo.SwapchainComposition, data.InitInfo.PresentMode);
    viewport.RendererUserData = cast(*void) 1;
}

renderer_render_window :: (viewport: *ImGuiViewport, render_arg: *void) #c_call {
    // ImGui calls this from C with no Jai context; PrepareDrawData/RenderDrawData
    // are native procs, so push the main-thread context captured at init.
    push_context g_context {
        data := get_backend_data();
        window := SDL_GetWindowFromID(cast(SDL_WindowID)(cast(u64) viewport.PlatformHandle));
        draw_data := viewport.DrawData;

        command_buffer := SDL_AcquireGPUCommandBuffer(data.InitInfo.Device);

        swapchain_texture: *SDL_GPUTexture;
        SDL_AcquireGPUSwapchainTexture(command_buffer, window, *swapchain_texture, null, null);

        if swapchain_texture != null {
            ImGui_ImplSDLGPU3_PrepareDrawData(draw_data, command_buffer);
            target_info: SDL_GPUColorTargetInfo;
            target_info.texture = swapchain_texture;
            target_info.clear_color = .{0.0, 0.0, 0.0, 1.0};
            target_info.load_op = .CLEAR;
            target_info.store_op = .STORE;
            target_info.mip_level = 0;
            target_info.layer_or_depth_plane = 0;
            target_info.cycle = false;
            render_pass := SDL_BeginGPURenderPass(command_buffer, *target_info, 1, null);
            ImGui_ImplSDLGPU3_RenderDrawData(draw_data, command_buffer, render_pass);
            SDL_EndGPURenderPass(render_pass);
        }

        SDL_SubmitGPUCommandBuffer(command_buffer);
    }
}

renderer_destroy_window :: (viewport: *ImGuiViewport) #c_call {
    data := get_backend_data();
    if viewport.RendererUserData {
        window := SDL_GetWindowFromID(cast(SDL_WindowID)(cast(u64) viewport.PlatformHandle));
        SDL_ReleaseWindowFromGPUDevice(data.InitInfo.Device, window);
    }
    viewport.RendererUserData = null;
}

init_multi_viewport_support :: () {
    platform_io := ImGui.GetPlatformIO();
    platform_io.Renderer_RenderWindow  = renderer_render_window;
    platform_io.Renderer_CreateWindow  = renderer_create_window;
    platform_io.Renderer_DestroyWindow = renderer_destroy_window;
}

shutdown_multi_viewport_support :: () {
    ImGui.DestroyPlatformWindows();
}

#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "Basic";
