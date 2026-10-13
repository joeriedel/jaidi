// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Runs the test suites in tests/. A suite is tests/<name>.jai; every procedure in it marked
// @test runs at compile time, so no executable is built.
//
//   jai/bin/jai-linux tests.jai              all suites
//   jai/bin/jai-linux tests.jai - dfArchive  one suite

#run {
    set_build_options_dc(.{do_output=false});

    suites: [..] string;
    for get_build_options().compile_time_command_line  array_add(*suites, it);
    if !suites {
        for file_list("tests") {
            name := path_filename(it);
            if ends_with(name, ".jai") && name != "support.jai"  array_add(*suites, path_strip_extension(name));
        }
        quick_sort(suites, compare);
    }

    failed := 0;
    for suites  if !run_suite(it) failed += 1;
    if failed {
        print("\n% of % suites failed.\n", failed, suites.count);
        compiler_set_workspace_status(.FAILED);
    }
}

run_suite :: (suite: string) -> bool {
    path := tprint("tests/%.jai", suite);
    if !file_exists(path) {
        print("No suite '%' (%).\n", suite, path);
        return false;
    }
    print("== %\n", suite);

    w := compiler_create_workspace(suite);
    options := get_build_options(w);
    options.output_type = .NO_OUTPUT;
    options.intermediate_path = ".build";
    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_file("tests/support.jai", w);
    add_build_file(path, w);

    // The compiler's paths use forward slashes everywhere; get_absolute_path gives backslashes
    // on Windows.
    suite_path := get_absolute_path(path);
    path_overwrite_separators(suite_path, #char "/");

    tests: [..] string;
    runner_added := false;
    ok := true;
    while true {
        msg := compiler_wait_for_message();
        if msg.kind == {
            case .TYPECHECKED;
                typechecked := cast(*Message_Typechecked) msg;
                for typechecked.procedure_headers {
                    header := it.expression;
                    if !header.enclosing_load || header.enclosing_load.fully_pathed_filename != suite_path continue;
                    for header.notes  if it.text == "test"  array_add(*tests, header.name);
                }

            case .PHASE;
                phase := cast(*Message_Phase) msg;
                if phase.phase == .TYPECHECKED_ALL_WE_CAN && !runner_added {
                    runner_added = true;
                    builder: String_Builder;
                    append(*builder, "#run {\n");
                    for tests  print_to_builder(*builder, "    run_test(\"%1\", %1);\n", it);
                    print_to_builder(*builder, "    finish_suite(\"%\");\n}\n", suite);
                    add_build_string(builder_to_string(*builder), w);
                }

            case .COMPLETE;
                complete := cast(*Message_Complete) msg;
                ok = complete.error_code == .NONE;
                break;
        }
    }
    compiler_end_intercept(w);
    return ok;
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Sort";
#import "String";
