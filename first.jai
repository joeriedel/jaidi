// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Build: jai first.jai            -> bin/jaidi, optimized by LLVM, with debug info
//        jai first.jai - check    -> typecheck only, no output
//        jai first.jai - release  -> bin/jaidi, optimized by LLVM, no debug info
//        jai first.jai - ship     -> bin/jaidi without the tools and dev options (SHIP);
//                                    with release for a test build: - release ship
//        jai first.jai - windows  -> bin/windows/jaidi.exe, cross-compiled on Linux against the
//                                    MSVC and Windows SDK libraries from xwin (XWIN, or /opt/xwin)
//        jai first.jai - out=DIR  -> the executable and its libraries in DIR instead of bin

#run {
    options := get_build_options();

    check_only := false;
    release := false;
    ship := false;
    windows := OS == .WINDOWS;
    out := "";
    for options.compile_time_command_line {
        if it == "check"   check_only = true;
        if it == "release" release = true;
        if it == "ship"    ship = true;
        if it == "windows" windows = true;
        if begins_with(it, "out=") out = slice(it, 4, it.count - 4);
    }
    cross := windows && OS != .WINDOWS;

    options.text_output_flags = .OUTPUT_TIMING_INFO;
    options.output_type = ifx check_only then .NO_OUTPUT else .EXECUTABLE;
    options.output_path = ifx out then out else ifx cross then "bin/windows" else "bin";
    options.output_executable_name = "jaidi";
    if release {
        set_optimization(*options, .OPTIMIZED, preserve_debug_info = false);
        options.backend = .LLVM;
        options.intermediate_path = ".build/release";
    } else {
        // Optimized all the same: the in-between fitting and the cutscenes' decoding are far
        // too slow unoptimized to work with.
        set_optimization(*options, .OPTIMIZED);
        options.backend = .LLVM;
        options.intermediate_path = ".build";
    }
    if cross {
        options.os_target = .WINDOWS;
        options.cpu_target = .X64;
        options.use_custom_link_command = true;
        options.intermediate_path = tprint("%/windows", options.intermediate_path);
    } else if windows && ship {
        options.additional_linker_arguments = WINDOWS_GUI_LINKER_ARGUMENTS;
    }

    if !check_only make_directory_if_it_does_not_exist(options.output_path, recursive = true);

    w := compiler_create_workspace("jaidi");
    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_string(tprint("SHIP :: %;\nDEV :: !SHIP;\n", ship), w);
    add_build_file("main.jai", w);

    while true {
        msg := compiler_wait_for_message();
        if msg.kind == {
            case .TYPECHECKED;
                do_error_checking(null, msg);
            case .PHASE;
                phase := cast(*Message_Phase) msg;
                #if OS != .WINDOWS {
                    if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                        if !link_windows(phase, options.output_path, release, ship) || !copy_dlls(options.output_path, .WINDOWS) {
                            compiler_set_workspace_status(.FAILED, w);
                        }
                        compiler_custom_link_command_is_complete(w);
                    }
                }
                if phase.phase == .POST_WRITE_EXECUTABLE && !phase.executable_write_failed && !cross {
                    if !copy_dlls(options.output_path, OS) {
                        compiler_set_workspace_status(.FAILED, w);
                    }
                }
            case .COMPLETE;
                break;
        }
    }

    compiler_end_intercept(w);
    set_build_options_dc(.{do_output=false});
}

// Ship builds have no console window. The C runtime's entry point still calls main.
WINDOWS_GUI_LINKER_ARGUMENTS :: string.["/SUBSYSTEM:windows", "/ENTRY:mainCRTStartup"];

// Links a cross-compiled Windows build with the compiler's lld.
link_windows :: (phase: *Message_Phase, output_path: string, release: bool, ship: bool) -> bool {
    // The cross-compile runs on Linux; a Windows host has no getenv to read XWIN with.
    xwin: string;
    #if OS != .WINDOWS  xwin = to_string(getenv("XWIN"));
    if !xwin xwin = "/opt/xwin";
    if !is_directory(xwin) {
        log_error("No MSVC and Windows SDK libraries at %. Unpack them with xwin splat and point XWIN there.", xwin);
        return false;
    }

    args: [..] string;
    array_add(*args, tprint("%/bin/lld-linux", compiler_get_base_path()), "-flavor", "link");
    array_add(*args, "/nologo", "/MACHINE:X64", "/INCREMENTAL:NO", tprint("/OUT:%/jaidi.exe", output_path));
    if !release && !ship array_add(*args, "/DEBUG");
    if ship array_add(*args, ..WINDOWS_GUI_LINKER_ARGUMENTS);
    for string.["crt/lib/x86_64", "sdk/lib/um/x86_64", "sdk/lib/ucrt/x86_64"] {
        array_add(*args, tprint("/LIBPATH:%/%", xwin, it));
    }
    array_add(*args, ..phase.compiler_generated_object_files);
    // The compiler asks for both C runtimes. Take the DLL one, which vc_redist installs, as a
    // native build does. xwin's library names are lower case (DbgHelp.lib is dbghelp.lib).
    array_add(*args, "/NODEFAULTLIB:libcmt");
    for phase.system_libraries {
        if it != "libcmt.lib" array_add(*args, to_lower_copy(it));
    }
    array_add(*args, ..phase.user_libraries);

    result := run_command(..args);
    return result.type == .EXITED && result.exit_code == 0;
}

copy_to_path :: (src: string, dst: string, path: string) -> bool {
    d := tprint("%/%", path, dst);
    dt, ds, dok := file_modtime_and_size(d);
    if dok {
        st, ss, sok := file_modtime_and_size(src);
        if sok && st <= dt && ss == ds {
            return true;
        }
    }
    ok := copy_file(src, d);
    if ok print("Copied % -> %\n", src, d);
    return ok;
}

copy_dlls :: (output_path: string, target: Operating_System_Tag) -> bool {
    ok := true;
    if target == .WINDOWS {
        ok &&= copy_to_path(tprint("%/SDL3.dll", SDL3_LIB_DIR), "SDL3.dll", output_path);
        ok &&= copy_to_path(tprint("%/bin/windows/ImGui.dll", IMGUI_DIR), "ImGui.dll", output_path);
        ok &&= copy_to_path(tprint("%/bin/windows/NukedOPL3.dll", NUKEDOPL3_DIR), "NukedOPL3.dll", output_path);
    } else if target == .LINUX {
        ok &&= copy_to_path(tprint("%/libSDL3.so.0.4.8", SDL3_LIB_DIR), "libSDL3.so.0", output_path);
        ok &&= copy_to_path(tprint("%/bin/linux/ImGui.so", IMGUI_DIR), "ImGui.so", output_path);
        ok &&= copy_to_path(tprint("%/bin/linux/NukedOPL3.so", NUKEDOPL3_DIR), "NukedOPL3.so", output_path);
    } else {
        log_error("copy_dlls: unsupported platform %", target);
        ok = false;
    }
    return ok;
}

#import "Basic";
#import "Compiler";
#import "Check";
#import "String";
#import "File";
#import "File_Utilities";
#import "Process";
#if OS != .WINDOWS #import "POSIX";

using,only(SDL_PATH) _ :: #import,file "modules/engine/vendor/SDL3/paths.jai";
SDL3_LIB_DIR :: #run tprint("modules/engine/vendor/SDL3/%/lib", SDL_PATH);

using,only(IMGUI_PATH) _ :: #import,file "modules/engine/vendor/ImGui/paths.jai";
IMGUI_DIR :: #run tprint("modules/engine/vendor/ImGui/%", IMGUI_PATH);

using,only(NUKEDOPL3_PATH) _ :: #import,file "modules/engine/vendor/NukedOPL3/paths.jai";
NUKEDOPL3_DIR :: #run tprint("modules/engine/vendor/NukedOPL3/%", NUKEDOPL3_PATH);
