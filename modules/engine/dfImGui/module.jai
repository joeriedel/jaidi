// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Dear ImGui integration for SDL3 + SDL_GPU, implemented as native-Jai ports of
// the upstream platform/renderer backends (see imgui_impl_sdl3.jai and
// imgui_impl_sdlgpu3.jai). This module exposes a small app-facing API; the GPU
// device/swapchain is owned by the caller.
//
// Per-frame usage. You own the command buffer, swapchain and render pass, so you
// can render your scene first and overlay ImGui on top in the same pass:
//   im_new_frame();
//   ImGui.ShowDemoWindow(*open);                 // build your UI
//   ImGui.Render();
//   draw_data := ImGui.GetDrawData();            // fetch once, thread it
//   cmd := SDL_AcquireGPUCommandBuffer(device);
//   SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, *tex, null, null);
//   minimized := draw_data.DisplaySize.x <= 0 || draw_data.DisplaySize.y <= 0;
//   if tex && !minimized {
//       im_prepare(draw_data, cmd);              // copy pass: BEFORE any render pass
//       pass := SDL_BeginGPURenderPass(cmd, ...);
//       ... render your scene into `pass` ...
//       im_render(draw_data, cmd, pass);         // overlay ImGui
//       SDL_EndGPURenderPass(pass);
//   }
//   SDL_SubmitGPUCommandBuffer(cmd);

im_init :: (window: *SDL_Window, device: *SDL_GPUDevice, color_format: SDL_GPUTextureFormat) {
    ImGui.CreateContext();
    io := ImGui.GetIO();
    io.ConfigFlags |= .NavEnableKeyboard;
    io.ConfigFlags |= .NavEnableGamepad;
    io.ConfigFlags |= .DockingEnable;
    io.ConfigFlags |= .ViewportsEnable;

    ImGui.StyleColorsDark();

    // When viewports are enabled, tweak WindowRounding/WindowBg so platform
    // windows look identical to docked ones.
    style := ImGui.GetStyle();
    if io.ConfigFlags & .ViewportsEnable {
        style.WindowRounding = 0.0;
        style.Colors[ImGuiCol.WindowBg].w = 1.0;
    }

    ui_scale = im_get_ui_scale(window);
    style.ScaleAllSizes(style, ui_scale);
    style.FontScaleDpi = ui_scale;

    ImGui_ImplSDL3_InitForSDLGPU(window);

    init_info: ImGui_ImplSDLGPU3_InitInfo;
    init_info.Device = device;
    init_info.ColorTargetFormat = color_format;
    init_info.MSAASamples = ._1;
    init_info.SwapchainComposition = .SDR;
    init_info.PresentMode = .VSYNC;
    ImGui_ImplSDLGPU3_Init(*init_info);
}

// The scale the desktop asks for beyond what the window's pixel density already gives: 1 under
// Wayland and on macOS, where SDL hands out a denser framebuffer; the desktop's setting under X11
// (Xft.dpi) and on Windows, where windows are sized in pixels.
im_get_ui_scale :: (window: *SDL_Window) -> float {
    density := SDL_GetWindowPixelDensity(window);
    scale := SDL_GetWindowDisplayScale(window);
    if density <= 0 || scale <= 0 return 1;
    return scale / density;
}

// A size in the tools' units (logical pixels) to ImGui's: the same under Wayland and macOS, times
// the desktop's scale where ImGui works in pixels.
im_scale :: (size: float) -> float {
    return size * ui_scale;
}

im_scale :: (size: ImVec2) -> ImVec2 {
    return .{size.x * ui_scale, size.y * ui_scale};
}

im_process_event :: (event: *SDL_Event) -> bool {
    return ImGui_ImplSDL3_ProcessEvent(event);
}

im_new_frame :: () {
    ImGui_ImplSDLGPU3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui.NewFrame();
}

// Uploads vertex/index/texture data for `draw_data`. MUST be called before
// beginning the render pass it will be drawn in — SDL_GPU forbids copy passes
// while a render/compute pass is bound — so call it before SDL_BeginGPURenderPass
// (and before any of your own scene upload/copy passes' render pass).
im_prepare :: (draw_data: *ImDrawData, command_buffer: *SDL_GPUCommandBuffer) {
    ImGui_ImplSDLGPU3_PrepareDrawData(draw_data, command_buffer);
}

// Draws `draw_data` into an already-begun render pass. Call after rendering your
// own scene into the same pass to overlay ImGui on top.
im_render :: (draw_data: *ImDrawData, command_buffer: *SDL_GPUCommandBuffer, render_pass: *SDL_GPURenderPass) {
    ImGui_ImplSDLGPU3_RenderDrawData(draw_data, command_buffer, render_pass);
}

// With multi-viewport enabled, renders/presents the secondary OS windows (each
// gets its own command buffer + swapchain via the renderer's RenderWindow
// callback). Call once per frame after rendering the main window, before its
// SDL_SubmitGPUCommandBuffer. No-op when ViewportsEnable is off.
im_render_viewports :: () {
    io := ImGui.GetIO();
    if io.ConfigFlags & .ViewportsEnable {
        ImGui.UpdatePlatformWindows();
        ImGui.RenderPlatformWindowsDefault();
    }
}

im_shutdown :: (device: *SDL_GPUDevice) {
    SDL_WaitForGPUIdle(device);
    ImGui_ImplSDL3_Shutdown();
    ImGui_ImplSDLGPU3_Shutdown();
    ImGui.DestroyContext();
}

#load "shaders.jai";
#load "imgui_impl_sdlgpu3.jai";
#load "imgui_impl_sdl3.jai";

#scope_module

#import "engine/vendor/SDL3";
#import "engine/vendor/ImGui";

#scope_file

ui_scale: float = 1;
