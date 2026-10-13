// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

#load "paths.jai";

#if OS == .LINUX {
    #load "linux.jai";
} else #if OS == .WINDOWS {
    #load "windows.jai";
}

SDL_WINDOW_FULLSCREEN          : SDL_WindowFlags : 0x0000000000000001;
SDL_WINDOW_OPENGL              : SDL_WindowFlags : 0x0000000000000002;
SDL_WINDOW_OCCLUDED            : SDL_WindowFlags : 0x0000000000000004;
SDL_WINDOW_HIDDEN              : SDL_WindowFlags : 0x0000000000000008;
SDL_WINDOW_BORDERLESS          : SDL_WindowFlags : 0x0000000000000010;
SDL_WINDOW_RESIZABLE           : SDL_WindowFlags : 0x0000000000000020;
SDL_WINDOW_MINIMIZED           : SDL_WindowFlags : 0x0000000000000040;
SDL_WINDOW_MAXIMIZED           : SDL_WindowFlags : 0x0000000000000080;
SDL_WINDOW_MOUSE_GRABBED       : SDL_WindowFlags : 0x0000000000000100;
SDL_WINDOW_INPUT_FOCUS         : SDL_WindowFlags : 0x0000000000000200;
SDL_WINDOW_MOUSE_FOCUS         : SDL_WindowFlags : 0x0000000000000400;
SDL_WINDOW_EXTERNAL            : SDL_WindowFlags : 0x0000000000000800;
SDL_WINDOW_MODAL               : SDL_WindowFlags : 0x0000000000001000;
SDL_WINDOW_HIGH_PIXEL_DENSITY  : SDL_WindowFlags : 0x0000000000002000;
SDL_WINDOW_MOUSE_CAPTURE       : SDL_WindowFlags : 0x0000000000004000;
SDL_WINDOW_MOUSE_RELATIVE_MODE : SDL_WindowFlags : 0x0000000000008000;
SDL_WINDOW_ALWAYS_ON_TOP       : SDL_WindowFlags : 0x0000000000010000;
SDL_WINDOW_UTILITY             : SDL_WindowFlags : 0x0000000000020000;
SDL_WINDOW_TOOLTIP             : SDL_WindowFlags : 0x0000000000040000;
SDL_WINDOW_POPUP_MENU          : SDL_WindowFlags : 0x0000000000080000;
SDL_WINDOW_KEYBOARD_GRABBED    : SDL_WindowFlags : 0x0000000000100000;
SDL_WINDOW_FILL_DOCUMENT       : SDL_WindowFlags : 0x0000000000200000;
SDL_WINDOW_VULKAN              : SDL_WindowFlags : 0x0000000010000000;
SDL_WINDOW_METAL               : SDL_WindowFlags : 0x0000000020000000;
SDL_WINDOW_TRANSPARENT         : SDL_WindowFlags : 0x0000000040000000;
SDL_WINDOW_NOT_FOCUSABLE       : SDL_WindowFlags : 0x0000000080000000;

#scope_module

VkInstance_T :: struct {}
VkInstance :: *VkInstance_T;
VkPhysicalDevice_T :: struct {}
VkPhysicalDevice :: *VkPhysicalDevice_T;
VkSurfaceKHR_T :: struct {}
VkSurfaceKHR :: *VkSurfaceKHR_T;
VkAllocationCallbacks :: struct {}

