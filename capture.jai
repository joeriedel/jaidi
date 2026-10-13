// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Saving the window to a PNG, for the dev screenshots and the CI test: the frame's UI is drawn
// again into a texture of its own, which works with the window hidden, and read back once the
// frame is submitted.

Frame_Capture :: struct {
    transfer: *SDL_GPUTransferBuffer;
    width, height: u32;
    bgra: bool;
}

// Called with the frame's command buffer once the window is drawn.
queue_frame_capture :: (capture: *Frame_Capture, device: *SDL_GPUDevice, command_buffer: *SDL_GPUCommandBuffer, draw_data: *ImDrawData, format: SDL_GPUTextureFormat) {
    width  := cast(u32) (draw_data.DisplaySize.x * draw_data.FramebufferScale.x);
    height := cast(u32) (draw_data.DisplaySize.y * draw_data.FramebufferScale.y);
    info: SDL_GPUTextureCreateInfo;
    info.type = ._2D;
    info.format = format;
    info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = width;
    info.height = height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    texture := SDL_CreateGPUTexture(device, *info);
    defer SDL_ReleaseGPUTexture(device, texture);

    target: SDL_GPUColorTargetInfo;
    target.texture = texture;
    target.clear_color = .{0, 0, 0, 1};
    target.load_op = .CLEAR;
    target.store_op = .STORE;
    pass := SDL_BeginGPURenderPass(command_buffer, *target, 1, null);
    im_render(draw_data, command_buffer, pass);
    SDL_EndGPURenderPass(pass);

    transfer_info := SDL_GPUTransferBufferCreateInfo.{usage = .DOWNLOAD, size = width * height * 4};
    capture.transfer = SDL_CreateGPUTransferBuffer(device, *transfer_info);
    capture.width, capture.height = width, height;
    capture.bgra = format == .B8G8R8A8_UNORM || format == .B8G8R8A8_UNORM_SRGB;
    copy := SDL_BeginGPUCopyPass(command_buffer);
    region := SDL_GPUTextureRegion.{texture = texture, w = width, h = height, d = 1};
    destination := SDL_GPUTextureTransferInfo.{transfer_buffer = capture.transfer};
    SDL_DownloadFromGPUTexture(copy, *region, *destination);
    SDL_EndGPUCopyPass(copy);
}

is_frame_capture_queued :: (capture: Frame_Capture) -> bool {
    return capture.transfer != null;
}

// After the frame is submitted: writes the queued capture to path. Also returns how much of
// the picture isn't black and roughly how many colors it has (to 5 bits a channel), for telling
// a blank frame from a drawn one.
write_frame_capture :: (capture: *Frame_Capture, device: *SDL_GPUDevice, path: string) -> ok: bool, lit: float, colors: int {
    SDL_WaitForGPUIdle(device);
    pixels := cast(*u8) SDL_MapGPUTransferBuffer(device, capture.transfer, false);
    count := capture.width * capture.height;
    seen: [32 * 32 * 32 / 64] u64;
    lit := 0;
    for 0..count-1 {
        p := pixels + it * 4;
        if capture.bgra  p[0], p[2] = p[2], p[0];
        p[3] = 255;
        if p[0] > 8 || p[1] > 8 || p[2] > 8  lit += 1;
        color := ((cast(u32) p[0] >> 3) << 10) | ((cast(u32) p[1] >> 3) << 5) | (cast(u32) p[2] >> 3);
        ONE: u64 : 1;
        seen[color >> 6] |= ONE << (color & 63);
    }
    colors := 0;
    for seen  colors += popcount(it);
    ok := stbi_write_png(temp_c_string(path), xx capture.width, xx capture.height, 4, pixels, xx (capture.width * 4)) != 0;
    SDL_UnmapGPUTransferBuffer(device, capture.transfer);
    SDL_ReleaseGPUTransferBuffer(device, capture.transfer);
    capture.transfer = null;
    if !ok  print("Couldn't write %\n", path);
    return ok, ifx count then lit / cast(float) count else 0, colors;
}

#scope_file

#import "Basic";
#import "Bit_Operations";
#import "stb_image_write";
#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";
#import "engine/dfImGui";
