#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the dev container image (jaidi-dev). Run from the source folder, with jai/ in place:
# the Jails language server is built with it. With docker/run.local.sh present, the image
# gets our own extras (EXTRAS=1, see the Dockerfile).
set -e
cd "$(dirname "$0")/.."
EXTRAS=0
[ -f docker/run.local.sh ] && EXTRAS=1
podman stop jaidi-dev 2>/dev/null || true
podman build --security-opt label=disable --build-arg EXTRAS=$EXTRAS "$@" -t jaidi-dev -f docker/Dockerfile .
