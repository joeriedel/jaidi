// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Loaded into every suite by tests.jai, which calls run_test for each @test procedure and then
// finish_suite.

// Returns the condition, so a test can stop at a failure that would derail what follows.
check :: (condition: bool, message: string, args: .. Any, loc := #caller_location) -> bool {
    if condition return true;
    test_state.failed = true;
    print("    FAIL %:%: ", loc.fully_pathed_filename, loc.line_number);
    print(message, ..args);
    print("\n");
    return false;
}

// Ends the calling test as skipped when the retail data isn't in dark/.
skip_without_dark :: () #expand {
    _, found := find_dark_data_dir();
    if !found {
        test_state.skipped = true;
        `return;
    }
}

run_test :: (name: string, proc: ()) {
    test_state.failed  = false;
    test_state.skipped = false;
    proc();
    if test_state.failed {
        test_state.fail_count += 1;
        print("  FAIL %\n", name);
    } else if test_state.skipped {
        test_state.skip_count += 1;
        print("  skip % (no dark/)\n", name);
    } else {
        test_state.pass_count += 1;
        print("  ok   %\n", name);
    }
}

finish_suite :: (suite: string) {
    print("  % passed, % failed, % skipped\n", test_state.pass_count, test_state.fail_count, test_state.skip_count);
    if test_state.fail_count compiler_set_workspace_status(.FAILED);
}

#scope_file

test_state: struct {
    failed, skipped: bool;
    pass_count, fail_count, skip_count: int;
};

#import "Basic";
#import "Compiler";
#import "engine/dfArchive";
