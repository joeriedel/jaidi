# SPDX-License-Identifier: GPL-2.0-or-later
#
# The dev container. docker/build.sh builds it, docker/run.sh runs it; see README.md.
#
# Host setup required before running this container:
#
#   NVIDIA GPU (CDI — replaces the older nvidia-container-runtime approach):
#     sudo dnf install nvidia-container-toolkit
#     sudo mkdir -p /etc/cdi && sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
#
#   Re-run the nvidia-ctk generate command after any NVIDIA driver update.
#   The CDI config is what makes "--device nvidia.com/gpu=all" in run.sh work.

FROM registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk:latest

# EXTRAS=1 adds what our own setup uses: Claude Code, the GitHub CLI, subversion and headless
# Ghidra. build.sh sets it when docker/run.local.sh is present.
ARG EXTRAS=0

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y \
    curl \
    git \
    openssh-client \
    unzip \
    ripgrep \
    fd-find \
    python3 \
    g++ \
    cmake \
    ninja-build \
    tmux \
    zsh \
    wl-clipboard \
    xclip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && locale-gen en_US.UTF-8

# neovim — pre-built binary; medic's glibc 2.40 satisfies its runtime requirements
ARG NVIM_VERSION=v0.12.2
RUN mkdir -p /opt \
    && curl -LO "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
    && tar -xzf nvim-linux-x86_64.tar.gz -C /opt \
    && ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
    && rm nvim-linux-x86_64.tar.gz

# codelldb DAP adapter — update CODELLDB_VERSION when rebuilding
ARG CODELLDB_VERSION=v1.12.2
RUN curl -LO "https://github.com/vadimcn/codelldb/releases/download/${CODELLDB_VERSION}/codelldb-linux-x64.vsix" \
    && unzip codelldb-linux-x64.vsix -d /opt/codelldb \
    && rm codelldb-linux-x64.vsix \
    && chmod +x /opt/codelldb/extension/adapter/codelldb

# Wrapper so `jai` resolves to the runtime-mounted compiler. run.sh mounts the repo at its host
# path and exports it as JAIDI_ROOT.
RUN printf '#!/bin/bash\nexec "${JAIDI_ROOT:?JAIDI_ROOT not set}/jai/bin/jai-linux" "$@"\n' \
        > /usr/local/bin/jai \
    && chmod +x /usr/local/bin/jai

# Compile Jai tree-sitter parser (constantitus/tree-sitter-jai — actively maintained,
# LANGUAGE_VERSION 14, plain C scanner, no regeneration needed).
RUN git clone --depth=1 https://github.com/constantitus/tree-sitter-jai /tmp/ts-jai \
    && mkdir -p /root/.local/share/nvim/site/parser \
               /root/.local/share/nvim/site/queries/jai \
    && gcc -shared -fPIC -O2 \
           -o /root/.local/share/nvim/site/parser/jai.so \
           /tmp/ts-jai/src/parser.c /tmp/ts-jai/src/scanner.c \
           -I /tmp/ts-jai/src \
    && cp /tmp/ts-jai/queries/highlights.scm \
          /root/.local/share/nvim/site/queries/jai/highlights.scm \
    && rm -rf /tmp/ts-jai

# Claude Code — native binary via signed apt repo
RUN if [ "$EXTRAS" != 1 ]; then exit 0; fi \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && apt-get install -y claude-code subversion \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI via its signed apt repo. run.local.sh mounts ~/.config/gh so its login persists.
RUN if [ "$EXTRAS" != 1 ]; then exit 0; fi \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Build Jails LSP from source with the jai compiler.
# Uses the trangius fork: upstream SogoCZE/Jails (as of v0.2.2) leaves textDocument/hover
# unanswered and lacks references/implementation/rename, which hangs Claude Code's LSP client.
# The fork's jai_parser submodule has an SSH URL, so rewrite GitHub SSH URLs to HTTPS here.
ARG JAILS_REPO=https://github.com/trangius/Jails
ARG JAILS_COMMIT=aae19c5f6ee7ec2ae55b925ce3d043a3a06a470b
RUN --mount=type=bind,source=jai,target=/tmp/jai \
    git init -q /tmp/jails-src \
    && cd /tmp/jails-src \
    && git remote add origin "${JAILS_REPO}" \
    && git fetch -q --depth=1 origin "${JAILS_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && git -c url."https://github.com/".insteadOf="git@github.com:" \
           submodule update -q --init --recursive --depth=1 \
    && /tmp/jai/bin/jai-linux build.jai - -release \
    && cp bin/jails /usr/local/bin/jails \
    && rm -rf /tmp/jails-src

# Ghidra, headless only, for reading the original executables (DARK.EXE, IMUSE.ENG, *.MDR).
# Run it as `analyzeHeadless`.
ARG GHIDRA_TAG=Ghidra_12.1.4_build
ARG GHIDRA_ZIP=ghidra_12.1.4_PUBLIC_20260921.zip
ARG GHIDRA_SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
RUN if [ "$EXTRAS" != 1 ]; then exit 0; fi \
    && apt-get update && apt-get install -y openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fLO "https://github.com/NationalSecurityAgency/ghidra/releases/download/${GHIDRA_TAG}/${GHIDRA_ZIP}" \
    && echo "${GHIDRA_SHA256}  ${GHIDRA_ZIP}" | sha256sum -c - \
    && unzip -q "${GHIDRA_ZIP}" -d /opt \
    && mv /opt/ghidra_* /opt/ghidra \
    && ln -sf /opt/ghidra/support/analyzeHeadless /usr/local/bin/analyzeHeadless \
    && rm "${GHIDRA_ZIP}"

COPY docker/zshrc /root/.zshrc

# Neovim config + pre-install plugins
COPY docker/nvim /root/.config/nvim
RUN nvim --headless "+Lazy! sync" +qa 2>&1 || true

ENV SHELL=/bin/zsh
CMD ["/bin/zsh"]
