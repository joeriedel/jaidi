// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Bindings for Nuked OPL3, a cycle-accurate YMF262 emulator (LGPL-2.1+, built as a shared
// library). Regenerate the bindings and rebuild the library with:
//   jai/bin/jai-linux modules/engine/vendor/NukedOPL3/generate.jai    (or jai/bin/jai.exe)

#load "paths.jai";

#if OS == .LINUX {
    #load "linux.jai";
} else #if OS == .WINDOWS {
    #load "windows.jai";
} else {
    #assert false "NukedOPL3 module: unsupported platform";
}
