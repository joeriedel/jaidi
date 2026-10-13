#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Runs the dev container (docker/build.sh builds it) with the source folder mounted at the
# same path, the display, the GPU and the sound. docker/run.local.sh, if present, adds
# mounts of your own to EXTRA_ARGS.
set -e
cd "$(dirname "$0")/.."

WAYLAND_ARGS=()
if [ -n "$WAYLAND_DISPLAY" ]; then
    WAYLAND_ARGS+=(
        -e WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
        -v "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/tmp/$WAYLAND_DISPLAY:z"
        -e XDG_RUNTIME_DIR=/tmp
    )
fi

X11_ARGS=()
if [ -n "$DISPLAY" ]; then
    X11_ARGS+=(
        -e DISPLAY="$DISPLAY"
        -v /tmp/.X11-unix:/tmp/.X11-unix
    )
    if [ -f "${XAUTHORITY:-$HOME/.Xauthority}" ]; then
        X11_ARGS+=(
            -v "${XAUTHORITY:-$HOME/.Xauthority}":/root/.Xauthority:z
            -e XAUTHORITY=/root/.Xauthority
        )
    fi
fi

# NVIDIA through its CDI spec (see the README), otherwise the DRI devices (AMD, Intel).
GPU_ARGS=(--device /dev/dri)
if [ -f /etc/cdi/nvidia.yaml ] || [ -f /var/run/cdi/nvidia.yaml ]; then
    GPU_ARGS+=(--device nvidia.com/gpu=all)
fi

# PipeWire and PulseAudio sockets, so SDL can play sound. The container's XDG_RUNTIME_DIR is /tmp.
AUDIO_ARGS=()
if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
    AUDIO_ARGS+=(-v "$XDG_RUNTIME_DIR/pipewire-0:/tmp/pipewire-0")
fi
if [ -S "$XDG_RUNTIME_DIR/pulse/native" ]; then
    AUDIO_ARGS+=(-v "$XDG_RUNTIME_DIR/pulse/native:/tmp/pulse/native" -e PULSE_SERVER=unix:/tmp/pulse/native)
fi

EXTRA_ARGS=()
if [ -f "$HOME/.tmux.conf" ]; then
    EXTRA_ARGS+=(-v "$HOME/.tmux.conf":/root/.tmux.conf:z)
fi
if [ -d "$HOME/.oh-my-zsh" ]; then
    EXTRA_ARGS+=(-v "$HOME/.oh-my-zsh":/root/.oh-my-zsh:z)
fi
if [ -f "$HOME/.p10k.zsh" ]; then
    EXTRA_ARGS+=(-v "$HOME/.p10k.zsh":/root/.p10k.zsh:z)
fi
if [ -f docker/run.local.sh ]; then
    source docker/run.local.sh
fi

podman run -it --rm \
    --security-opt label=disable \
    --hostname jaidi-dev \
    --tz=local \
    -v "$(pwd)":"$(pwd)":Z \
    -w "$(pwd)" \
    -e JAIDI_ROOT="$(pwd)" \
    -v "$(pwd)/docker/zshrc":/root/.zshrc:z \
    -v "$(pwd)/docker/nvim":/root/.config/nvim:z \
    "${GPU_ARGS[@]}" \
    "${WAYLAND_ARGS[@]}" \
    "${X11_ARGS[@]}" \
    "${AUDIO_ARGS[@]}" \
    "${EXTRA_ARGS[@]}" \
    jaidi-dev
