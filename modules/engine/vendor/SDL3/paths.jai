// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Joseph Riedel

// Single source of truth for the vendored SDL3 version/directory.
// Kept separate from module.jai so generate.jai can read it WITHOUT
// transitively #loading the platform binding file it is regenerating.

SDL_PATH :: "release-3.4.8";
