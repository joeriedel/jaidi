# Nuked OPL3 provenance

- **Upstream:** https://github.com/nukeykt/Nuked-OPL3
- **Commit:** `765ec962e473aeb767e4cba74ffdc8f588ffbfe8` (master HEAD at pull time, 2026-08-24,
  "remove NEW bit checks for 4-op channels"; the header self-reports version 1.8)
- **Pulled:** 2026-10-09
- **License:** LGPL-2.1-or-later (see `LICENSE` and the notice in `opl3.h`)

Nuked OPL3 is a cycle-accurate Yamaha YMF262 (OPL3) emulator in C. Upstream has no tags, so
the directory is named `<pull-date>-<short-commit>`.

## Files

- `opl3.c`, `opl3.h`, `LICENSE`: verbatim from upstream at the commit above. Upstream has
  nothing else.
- `bin/linux/NukedOPL3.so`: built shared library.
- `bin/windows/NukedOPL3.dll`, `NukedOPL3.lib`: built DLL and its import library (MSVC), with
  `NukedOPL3.def`, the export list it was linked with.

Built as a shared library so it stays a separately replaceable component, as the LGPL asks of
code linked into jaidi (GPL).

## Build

The library is built by jaidi's `modules/engine/vendor/NukedOPL3/generate.jai` via Jai's
`BuildCpp` module, which also regenerates the bindings:

```
jai/bin/jai-linux modules/engine/vendor/NukedOPL3/generate.jai    (or jai/bin/jai.exe)
```

`OPL_ENABLE_STEREOEXT` is left at its default (0). It changes the layout of `opl3_chip`, so the
library and the bindings must be built with the same setting.

Upstream has no export decoration, so on Windows `generate.jai` writes the `.def` from the
functions the bindings generator finds in `opl3.h`.

## Local patches

None.
