// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Compiles the vendored Dear ImGui C++ sources into a library and regenerates
// the Jai bindings (windows.jai / linux.jai).
//
// Run from this directory:
//   jai/bin/jai.exe modules/engine/vendor/ImGui/generate.jai
//
// ImGui is built as a DYNAMIC library (ImGui.dll + import lib). This is
// deliberate:
//   - the bindings generator can load it to introspect which symbols actually
//     exist (e.g. to strip inline functions);
//   - foreign ImGui procedures can be called at compile time (a ,no_dll static
//     lib cannot be called during #run);
//   - a single shared ImGui.dll keeps one ImGui context/state across a future
//     hot-reloadable game DLL and its host (a static lib would give each its own
//     copy). The project links the import lib and loads ImGui.dll at runtime, so
//     ImGui.dll must be copied next to the executable (see first.jai copy_dlls).
//
// Backends are intentionally NOT built or bound — the platform/renderer backend
// is written in native Jai.

using,only(IMGUI_PATH) _ :: #import,file "paths.jai";

DECLARATIONS_TO_OMIT :: string.[
    // We provide custom declarations for these in module.jai:
    "ImVec2",
    "ImVec4",
    "ImColor",
    "ImVector",
    "ImDrawCallback",

    // Jai has its own, better String_Builder.
    "ImGuiTextBuffer",

    "ImDrawCallback_ResetRenderState", // casting an integer to a function pointer is not supported in Jai.
];

#run,stallable {
    set_build_options_dc(.{do_output=false});
    if !compile_and_generate() {
        compiler_set_workspace_status(.FAILED);
    }
}

compile_and_generate :: () -> bool {
    imgui_src_files: [..] string;
    array_add(*imgui_src_files, tprint("%/imgui.cpp",         IMGUI_PATH));
    array_add(*imgui_src_files, tprint("%/imgui_widgets.cpp", IMGUI_PATH));
    array_add(*imgui_src_files, tprint("%/imgui_draw.cpp",    IMGUI_PATH));
    array_add(*imgui_src_files, tprint("%/imgui_tables.cpp",  IMGUI_PATH));
    array_add(*imgui_src_files, tprint("%/imgui_demo.cpp",    IMGUI_PATH)); // for ShowDemoWindow()

    // The built libs live INSIDE the versioned source dir (IMGUI_PATH) so they
    // are part of the vendored external alongside the ImGui release.
    success := true;
    #if OS == .WINDOWS {
        make_directory_if_it_does_not_exist(tprint("%/bin",         IMGUI_PATH));
        make_directory_if_it_does_not_exist(tprint("%/bin/windows", IMGUI_PATH));
        // IMGUI_DISABLE_WIN32_DEFAULT_IME_FUNCTIONS so we don't drag in imm32;
        // module.jai links user32 for the default clipboard handlers.
        win_flags :: string.["/DIMGUI_API=__declspec(dllexport)", "/DIMGUI_DISABLE_WIN32_DEFAULT_IME_FUNCTIONS"];
        success &&= build_cpp_dynamic_lib(tprint("%/bin/windows/ImGui", IMGUI_PATH), ..imgui_src_files, extra = win_flags);
    } else #if OS == .LINUX {
        make_directory_if_it_does_not_exist(tprint("%/bin",       IMGUI_PATH));
        make_directory_if_it_does_not_exist(tprint("%/bin/linux", IMGUI_PATH));
        // Without a SONAME the linker records the absolute path of ImGui.so in every executable.
        linux_flags :: string.["-Wl,-soname,ImGui.so"];
        success &&= build_cpp_dynamic_lib(tprint("%/bin/linux/ImGui", IMGUI_PATH), ..imgui_src_files, extra = linux_flags);
    } else {
        assert(false, "ImGui: unsupported platform");
    }
    if !success return false;

    defer array_reset(*begin_end_string_args);

    output_filename: string;
    options: Generate_Bindings_Options;
    {
        using options;

        #if OS == .WINDOWS {
            array_add(*library_search_paths, tprint("%/bin/windows", IMGUI_PATH));
            output_filename = "windows.jai";
        } else #if OS == .LINUX {
            array_add(*library_search_paths, tprint("%/bin/linux", IMGUI_PATH));
            output_filename = "linux.jai";
        } else {
            assert(false);
        }

        array_add(*libraries,     .{filename="ImGui"});
        array_add(*include_paths, IMGUI_PATH);
        array_add(*source_files,  tprint("%/imgui.h", IMGUI_PATH));
        array_add(*extra_clang_arguments, "-x", "c++", "-DWIN32_LEAN_AND_MEAN");
        // Keep ImGui's native prefixes on all bound symbols (project convention:
        // bound C/C++ keeps its original prefix). We let the generator keep the
        // C++ `ImGui` namespace as a Jai `struct` (the default), so functions are
        // called `ImGui.Foo` (mirroring `ImGui::Foo`). Types live at C++ global
        // scope and already carry their `ImGui`/`Im` prefix, so we DON'T strip.

        auto_detect_enum_prefixes            = false;
        log_stripped_declarations            = false;
        generate_compile_time_struct_checks  = false;
        header                               = "// SPDX-License-Identifier: GPL-2.0-or-later";
        strip_flags |= .INLINED_FUNCTIONS; // inline functions aren't present in the static library.

        visitor = imgui_visitor;
        get_func_args_for_printing = imgui_get_function_arg_for_printing;
    }

    return generate_bindings(options, output_filename);
}

begin_end_string_args: [..] *Declaration;
enums_for_typedefs:    Table(string, *Enum);

imgui_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    // ImGui has "typedef int" aliases for each enum. We want the real Jai enums
    // directly (for type safety, .unary dots, etc.) so we drop the int typedefs.
    get_associated_enum_name :: (name: string) -> string {
        if name.count > 1 && name[name.count - 1] != #char "_" {
            return tprint("%_", name);
        }
        return name;
    }

    if !parent_decl {
        if array_find(DECLARATIONS_TO_OMIT, decl.name) {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }
        if decl.name == "ImGuiContext" {
            decl.output_name = decl.name; // Don't shorten ImGuiContext to Context (would conflict).
        }

        if decl.kind == .TYPEDEF {
            old_name := decl.name;
            if old_name {
                new_name := get_associated_enum_name(old_name);
                for context.generator.global_scope.members {
                    if it.kind != .ENUM || it.name != new_name     continue;

                    en := cast(*Enum) it;

                    // Don't output the integer typedef.
                    decl.decl_flags |= .OMIT_FROM_OUTPUT;

                    // Make sure enums like "FocusFlags_" come out as "FocusFlags".
                    if en.output_name.count > 2 && en.output_name[en.output_name.count - 1] == #char "_" {
                        en.output_name.count -= 1;
                    }

                    if decl.comment.text && !en.comment.text {
                        en.comment = decl.comment;
                    }

                    table_add(*enums_for_typedefs, old_name, en);
                    break;
                }
            }
        }
    }

    // Function arguments / struct fields that use one of those int-typedef types.
    if parent_decl &&
        (parent_decl.kind == .FUNCTION || parent_decl.kind == .STRUCT) &&
        decl.kind == .DECLARATION && decl.type.type_of_typedef != null
    {
        old_name := decl.type.type_of_typedef.name;
        if old_name {
            found, en := table_find(*enums_for_typedefs, old_name);
            if found {
                change_type_to_enum(decl, en);
            }
        }
    }

    if decl.kind == .ENUM {
        en := cast(*Enum) decl;

        // ImGui's flag enums all end in "…Flags_".
        if ends_with(decl.name, "Flags_") {
            en.flags |= .IS_ENUM_FLAGS;
            en.flags |= .VALUES_IN_HEX;

            // ImGui's internal "InvalidMask_" sentinels are ~(mask), and since
            // 1.92 they set the high bit, so the constant-folded value sign-
            // extends to a 64-bit literal (e.g. 0xffffffff8000000f). Combined
            // with VALUES_IN_HEX above, that prints as a 64-bit hex literal that
            // won't fit the enum. ImGui flags are C 'int', so the enum MUST stay
            // 32-bit (widening it would change struct layouts and the call ABI).
            // The low 32 bits are a valid pattern, so keep the member but mask
            // the literal back to 32 bits. (Only flag enums need this — non-flag
            // enums print decimal, where a plain -1 is already fine.)
            for en.enumerates {
                if !it.expression || it.expression.kind != .LITERAL continue;
                lit := cast(*Literal) it.expression;
                if lit.literal_kind == {
                    case .INTEGER;
                        if lit.int_value < 0 || lit.int_value > 0xFFFF_FFFF  lit.int_value &= 0xFFFF_FFFF;
                    case .UNSIGNED_INTEGER;
                        if lit.uint_value > 0xFFFF_FFFF                      lit.uint_value &= 0xFFFF_FFFF;
                }
            }
        }
    }

    if decl.kind == .FUNCTION {
        func := cast(*Function) decl;
        type := func.type.type_of_function;
        // ImGui has pairs of args like "text_begin"/"text_end" (pointers to the
        // start and end of a string). We generate wrappers taking a Jai string.
        for type.arguments {
            if it_index == 0 || !ends_with(it.name, "_end")     continue;
            arg_type := find_underlying_type(it.type);
            if !arg_type.pointer_to || !(arg_type.pointer_to.number_flags & ._8BIT) continue; // only *u8 ranges

            name_part := slice(it.name, 0, it.name.count - "_end".count);
            if !name_part   continue;

            name_part_with_begin := tprint("%_begin", name_part);
            prev_arg := type.arguments[it_index - 1];
            if prev_arg.name == name_part || prev_arg.name == name_part_with_begin {
                array_add(*begin_end_string_args, prev_arg);
                func.decl_flags |= .NEEDS_ARGUMENT_WRAPPER;
            }
        }
    }

    return .RECURSE;
}

// Collapse _begin/_end pointer pairs into a single Jai string argument.
imgui_get_function_arg_for_printing :: (func: *Function, type: *Function_Type, mode: Arg_Print_Mode) -> [] *Declaration {
    args: [..] *Declaration;
    for type.arguments {
        if array_find(begin_end_string_args, it) {
            if mode == {
                case .OUTER_WRAPPER;
                    arg_copy := New(Declaration);
                    (arg_copy.*) = it.*;
                    arg_copy.type = context.generator.type_def_jai_string;
                    if ends_with(it.name, "_begin") {
                        arg_copy.output_name = slice(it.name, 0, it.name.count - "_begin".count);
                    }
                    array_add(*args, arg_copy);
                    it_index += 1; // skip the matching _end arg
                    continue;

                case .INNER_WRAPPER_CALL;
                    base_arg_name := it.name;
                    if ends_with(it.name, "_begin") {
                        base_arg_name = slice(it.name, 0, it.name.count - "_begin".count);
                    }

                    arg_copy := New(Declaration);
                    (arg_copy.*) = it.*;
                    arg_copy.output_name = tprint("%.data", base_arg_name);
                    array_add(*args, arg_copy);

                    arg_copy_2 := New(Declaration);
                    (arg_copy_2.*) = it.*;
                    arg_copy_2.output_name = tprint("%.data + %.count", base_arg_name, base_arg_name);
                    array_add(*args, arg_copy_2);

                    it_index += 1; // skip the matching _end arg
                    continue;
            }
        }

        array_add(*args, it);
    }

    return args;
}

#import "Basic";
#import "Bindings_Generator";
#import "BuildCpp";
#import "Compiler";
#import "File";
#import "Hash_Table";
#import "String";
