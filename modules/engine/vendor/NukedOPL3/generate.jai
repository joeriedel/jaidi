// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Builds opl3.c into a shared library and regenerates the Jai bindings (windows.jai /
// linux.jai).
//
// Run from the repo root:
//   jai/bin/jai-linux modules/engine/vendor/NukedOPL3/generate.jai    (or jai/bin/jai.exe)
//
// Paths below are relative to this file's directory, where the compiler runs #run code.

using,only(NUKEDOPL3_PATH) _ :: #import,file "paths.jai";

#run,stallable {
    set_build_options_dc(.{do_output=false});
    if !compile_and_generate() {
        compiler_set_workspace_status(.FAILED);
    }
}

compile_and_generate :: () -> bool {
    src := tprint("%/opl3.c", NUKEDOPL3_PATH);
    make_directory_if_it_does_not_exist(tprint("%/bin", NUKEDOPL3_PATH));

    #if OS == .WINDOWS {
        lib_dir := tprint("%/bin/windows", NUKEDOPL3_PATH);
        make_directory_if_it_does_not_exist(lib_dir);
        // opl3.h has no export decoration, so the DLL exports through a .def listing the
        // functions the header declares, taken from the same clang AST as the bindings.
        def_path := tprint("%/NukedOPL3.def", lib_dir);
        if !write_def_file(def_path) return false;
        if !build_cpp_dynamic_lib(tprint("%/NukedOPL3", lib_dir), src, library_files = .[tprint("/DEF:%", def_path)]) {
            return false;
        }
        output_filename := "windows.jai";
    } else #if OS == .LINUX {
        lib_dir := tprint("%/bin/linux", NUKEDOPL3_PATH);
        make_directory_if_it_does_not_exist(lib_dir);
        // Without a SONAME the linker records the absolute path of the .so in every executable.
        linux_flags :: string.["-Wl,-soname,NukedOPL3.so"];
        if !build_cpp_dynamic_lib(tprint("%/NukedOPL3", lib_dir), src, extra = linux_flags) {
            return false;
        }
        output_filename := "linux.jai";
    } else {
        assert(false, "NukedOPL3: unsupported platform");
        return false;
    }

    options := get_options();
    array_add(*options.library_search_paths, lib_dir);
    array_add(*options.libraries, .{filename="NukedOPL3"});
    return generate_bindings(options, output_filename);
}

get_options :: () -> Generate_Bindings_Options {
    options: Generate_Bindings_Options;
    {
        using options;
        array_add(*include_paths, NUKEDOPL3_PATH);
        array_add(*source_files,  tprint("%/opl3.h", NUKEDOPL3_PATH));

        auto_detect_enum_prefixes           = false;
        log_stripped_declarations           = false;
        generate_compile_time_struct_checks = false;
        header                              = "// SPDX-License-Identifier: GPL-2.0-or-later";
    }
    return options;
}

exported_functions: [..] string;

write_def_file :: (path: string) -> bool {
    // A probe pass with no library, so nothing is stripped for lack of one. It logs "Could not
    // find library" for every function; that's expected.
    options := get_options();
    options.strip_flags &= ~.SYMBOLS_WITH_UNKNOWN_FOREIGN_LIBS;
    options.generate_library_declarations = false;
    options.visitor = (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
        // The generator's pool is freed when it returns.
        push_allocator(context.default_allocator);
        if !parent_decl && decl.kind == .FUNCTION  array_add(*exported_functions, copy_string(decl.name));
        return .STOP;
    };
    _, ok := generate_bindings(options);
    if !ok || !exported_functions return false;

    builder: String_Builder;
    append(*builder, "EXPORTS\n");
    for exported_functions  print_to_builder(*builder, "    %\n", it);
    return write_entire_file(path, *builder);
}

#import "Basic";
#import "Bindings_Generator";
#import "BuildCpp";
#import "Compiler";
#import "File";
