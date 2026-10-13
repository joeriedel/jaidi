#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later

# Compiles the renderer's HLSL shaders to SPIR-V for SDL_GPU's Vulkan driver, with glslang
# (in the dev container). The .spv files are committed, so building jaidi doesn't need it.
# SDL_GPU wants combined texture-samplers, hence --auto-sampled-textures.

set -e
cd "$(dirname "$0")"
compile() {
    glslangValidator -D -V --auto-sampled-textures -S "$1" -e main "${@:4}" -o "$3" "$2" > /dev/null
}
compile vert scene.vert.hlsl   scene.vert.spv
compile vert scene.vert.hlsl   scene_points.vert.spv -DPOINTS
compile frag scene.frag.hlsl   scene.frag.spv
compile vert resolve.vert.hlsl resolve.vert.spv
compile frag resolve.frag.hlsl resolve.frag.spv
compile vert film.vert.hlsl    film.vert.spv
compile frag film.frag.hlsl    film.frag.spv
compile frag film.frag.hlsl    film_resolve.frag.spv -DRESOLVE
compile frag film.frag.hlsl    film_rgb.frag.spv -DRGB
compile frag film.frag.hlsl    film_output.frag.spv -DOUTPUT
