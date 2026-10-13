// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

using,only(SDL_PATH) _ :: #import,file "paths.jai";

HEADERS_TO_EXCLUDE 
    :: string.[
        "SDL_egl.h", 
        "SDL_opengl.h", 
        "SDL_opengl_glext.h", 
        "SDL_opengles.h", 
        "SDL_opengles2.h", 
        "SDL_opengles2_gl2.h",
        "SDL_opengles2_gl2ext.h"
];

sdl_include_path :: (path: string) -> string {
    return tprint("%/include/SDL3/%", SDL_PATH, path);
}

sdl_lib_path :: (path: string) -> string {
    return tprint("%s/lib/%", SDL_PATH, path);
}

map :: (arr: [] $T, f: (T) -> $R) -> [..] R {
    result: [..] R;
    for arr {
        array_add(*result, f(it));
    }
    return result;
}

// Vulkan handle types SDL declares for SDL_Vulkan_* functions.
// These are omitted from generated output because module.jai manages them
// via the VULKAN_TYPES_DEFINED module parameter (either module-private or exported).
VULKAN_TYPES_TO_OMIT :: string.[
    "VkInstance_T", "VkInstance",
    "VkPhysicalDevice_T", "VkPhysicalDevice",
    "VkSurfaceKHR_T", "VkSurfaceKHR",
    "VkAllocationCallbacks",
];

sdl_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    if !parent_decl && array_find(VULKAN_TYPES_TO_OMIT, decl.name) {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
    }
    return .RECURSE;
}

// Generate SDL3 bindings
#run {
    print("Generating SDL3 bindings\n");
    set_build_options_dc(.{do_output=false});

    output_filename: string;
    opts: Generate_Bindings_Options;
    {
        using opts;

        #if OS == .WINDOWS {
            output_filename = "windows.jai";
            array_add(*libraries, .{filename=tprint("%/lib/SDL3.lib", SDL_PATH), identifier="SDL3"});
        } else #if OS == .LINUX {
            output_filename = "linux.jai";
            array_add(*libraries, .{filename=tprint("%/lib/libSDL3.so", SDL_PATH), identifier="libSDL3"});
        } else #if OS == .MACOS {
            output_filename = "macos.jai";
        } else {
            assert(false);
        }

    	generate_compile_time_struct_checks = false;
        header = "// SPDX-License-Identifier: GPL-2.0-or-later";
        headers := file_list(tprint("%/include/SDL3", SDL_PATH), recursive = false);
        for headers {
            HEADERS_TO_EXCLUDE_WITH_FULL_PATH:: #run map(HEADERS_TO_EXCLUDE, sdl_include_path);
            if array_find(HEADERS_TO_EXCLUDE_WITH_FULL_PATH, it) {
                remove it;
            }
        }

        array_add(*source_files, ..headers);
        array_add(*include_paths, sprint("%/include", SDL_PATH));
        visitor = sdl_visitor;
    }

    if !generate_bindings(opts, output_filename) {
        log_error("failed to generate SDL3 bindings");
        compiler_set_workspace_status(.FAILED);
    }
}

#import "Basic";
#import "Compiler";
#import "Bindings_Generator";
#import "File_Utilities";
#import "File";
