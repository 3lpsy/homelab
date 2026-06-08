# opencode `web` server image with a full polyglot dev toolchain baked
# in. Layers ordered bottom-to-top from least likely to invalidate to
# most likely — a new opencode-ai release only rebuilds the top layer,
# adding an npm LSP rebuilds from layer 4, and so on.
#
# Target arch: amd64 (delphi cluster node). Re-add ARCH detection if
# this image ever needs to run on arm64 nodes.
FROM oven/bun:1

ENV DEBIAN_FRONTEND=noninteractive

# npm registry → in-cluster Verdaccio proxy (7-day supply-chain gate). Passed as
# a build_arg from services/opencode-jobs.tf so it tracks var.npm_domain (same
# source of truth as the runtime .npmrc ConfigMap). Two env vars on purpose:
#   - BUN_CONFIG_REGISTRY  — bun's GUARANTEED native registry knob. NPM_CONFIG_*
#     support in bun is "npm-compatible" but undocumented for case/precedence,
#     and bun has a known bug ignoring $HOME/.npmrc (oven-sh/bun#22971) — so we
#     don't trust it alone for the `bun install -g` steps below.
#   - NPM_CONFIG_REGISTRY  — honored by pnpm (and the npm→pnpm shim in §4).
# Both persist into the runtime image (the mounted .npmrc sets the same value).
# The npm CLI itself is removed in §4; pnpm/bun are the only package managers,
# both gated through this proxy. See docs/DEP_SAFETY.md.
#
# BUN_CONFIG_MAX_HTTP_REQUESTS caps bun's parallel HTTP (fetch + install). Set
# GLOBAL here (not just on build steps) so the runtime opencode AGENT's own
# `bun install` in user projects is throttled too — single-threaded Verdaccio +
# the cooldown filter can't take bun's default ~48-way burst (it abandons
# stragglers → "failed to resolve"). Trade-off: this also caps the opencode web
# server's own runtime HTTP concurrency to 8 — fine for a single-user agent;
# raise it if that proves limiting. Re-exported in §5b bashrc for SSH shells.
ARG NPM_REGISTRY
ENV BUN_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    BUN_CONFIG_MAX_HTTP_REQUESTS=8

# crates.io → in-cluster chilled-crates proxy (same 7-day gate). Cargo env-config
# form of `[source.crates-io] replace-with` + `[registries.chilled-crates] index`,
# so image-build cargo routes through the proxy too — specifically cargo-binstall's
# source-compile fallback (§2b/§5c) when no GitHub-release binary matches, and any
# `cargo install`/build during the image build. Runtime cargo is ADDITIONALLY
# covered by the mounted /usr/local/cargo/config.toml ConfigMap (services/opencode.tf),
# which carries the same values. build_arg from services/opencode-jobs.tf (tracks
# var.crates_domain). See docs/DEP_SAFETY.md.
ARG CRATES_REGISTRY
ENV CARGO_SOURCE_CRATES_IO_REPLACE_WITH=chilled-crates \
    CARGO_REGISTRIES_CHILLED_CRATES_INDEX=${CRATES_REGISTRY}

# ─── 1. System base — apt utilities. Rebuilds rarely. ──────────────────────
# Build deps + core CLIs the agent reaches for. fd-find / batcat install
# under non-canonical names on Debian; symlink to expected names.
#
# The libwebkit2gtk-4.1 / libxdo / libayatana-appindicator3 / librsvg2 /
# lld / file set is the Dioxus desktop-build dependency list (Debian trixie
# equivalents of the Ubuntu names from the Dioxus getting-started guide).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget unzip xz-utils file \
      git make build-essential pkg-config \
      jq ripgrep fd-find bat tree less \
      shellcheck shfmt \
      neovim tmux openssh-client \
      libwebkit2gtk-4.1-dev libxdo-dev libssl-dev \
      libayatana-appindicator3-dev librsvg2-dev lld \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && rm -rf /var/lib/apt/lists/*

# ─── 1b. Non-root runtime user + shared toolchain locations ────────────────
# opencode `web` runs as this user (the entrypoint drops to it from root —
# see data/opencode/entrypoint.sh). uid/gid 1001 deliberately, NOT 1000,
# which oven/bun:1 already assigns to its own `bun` user. No sudo, no
# supplementary privileged groups: root stays reachable ONLY via opkssh sshd,
# never by privilege escalation from `user`.
RUN groupadd --gid 1001 user \
 && useradd --uid 1001 --gid 1001 --create-home --home-dir /home/user --shell /bin/bash user
#
# Every toolchain that would otherwise install under /root (unreadable to a
# non-root user at mode 0700) is redirected to a shared /usr/local|/opt path
# so BOTH `user` and a root SSH session see it. These dirs are made writable
# at the end of their install layers (rust-image pattern) so runtime
# `cargo install` / `bun install -g` / `uv tool install` as `user` still work.
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    BUN_INSTALL=/usr/local/bun \
    UV_PYTHON_INSTALL_DIR=/usr/local/uv/python \
    UV_TOOL_DIR=/usr/local/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    PATH=/usr/local/cargo/bin:/usr/local/bun/bin:$PATH

# ─── 2. Rust toolchain + rust-analyzer — bumps per Rust release (~6wk) ────
# CARGO_HOME / RUSTUP_HOME are the shared /usr/local paths set in §1b.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --component rust-analyzer \
 && rustup component add clippy rustfmt

# ─── 2b. Cargo dev tools — compiled from source THROUGH the crates proxy ────
# Built with `cargo install` (NOT cargo-binstall): the from-source compile pulls
# every crate through chilled-crates (the CARGO_* env at §top), so these tool
# installs are gated like all other crates. cargo-binstall is intentionally NOT
# installed — it fetches prebuilt binaries from GitHub releases + queries the
# crates.io API, both of which bypass the gate. Trade-off: a cold build compiles
# these (minutes) instead of downloading (~30s). Placed HIGH — right after the
# toolchain — so the heavy compiles cache and survive every later layer's
# changes; they only rebuild when the Rust toolchain (§2) does. This is also why
# dioxus-cli + just (formerly their own late §5c/§5e layers) now live here.
#   - udeps + expand are invoked with +nightly at runtime (nightly installed
#     here), but build fine on stable. audit is stable.
#   - dioxus-cli (dx) needs the wasm32 target (added here).
#   - just is a command runner.
# Last cargo-touching layer → make CARGO_HOME/RUSTUP_HOME world-writable
# (rust-image pattern) so a runtime `cargo install` as `user` still works.
RUN rustup toolchain install nightly --profile minimal \
 && rustup target add wasm32-unknown-unknown \
 && cargo install --locked cargo-udeps cargo-expand cargo-audit \
 && cargo install --locked dioxus-cli \
 && cargo install --locked just \
 && chmod -R a+w "$CARGO_HOME" "$RUSTUP_HOME"

# ─── 2c. mold — fastest Linux linker. apt (gated), stable, caches like §2b. ─
# Beats the lld from §1 (which stays as a fallback). Installed only; WIRED IN
# via cargo config you add later (rustflags `-C link-arg=-fuse-ld=mold`). gcc 14
# (trixie) supports -fuse-ld=mold directly, so no clang needed for it.
RUN apt-get update && apt-get install -y --no-install-recommends mold \
 && rm -rf /var/lib/apt/lists/*

# ─── 2d. cargo-nextest — faster, better-isolated test runner. ──────────────
# Own layer (NOT folded into §2b's && chain) so adding it doesn't invalidate
# §2b's heavy compiles, and a future nextest bump doesn't rebuild sccache.
# cargo install --locked (NOT binstall) to stay behind the crates gate. Re-chmod
# a+w: this adds new bins + registry entries under CARGO_HOME after §2b's chmod.
RUN cargo install --locked cargo-nextest \
 && chmod -R a+w "$CARGO_HOME"

# ─── 2e. sccache — compilation cache. Own layer (caches independently). ────
# Installed only; OPT IN via cargo config (`[build] rustc-wrapper = "sccache"`)
# or RUSTC_WRAPPER, and point SCCACHE_DIR at the PVC so the cache survives pod
# restarts. NOTE: sccache and incremental compilation are mutually exclusive —
# best for clean/branch-switch builds, not tight edit-rebuild loops (see the
# config proposal in the PR description / docs).
RUN cargo install --locked sccache \
 && chmod -R a+w "$CARGO_HOME"

# ─── 2f. Cranelift codegen backend (nightly) — faster DEV codegen. ─────────
# rustup component on the nightly toolchain installed in §2b. Faster debug
# compiles than LLVM (dev-only; release still uses LLVM). Installed only —
# opt in per-project via `[profile.dev] codegen-backend = "cranelift"` +
# `[unstable] codegen-backend = true`, with a nightly toolchain. Writes under
# RUSTUP_HOME, so re-chmod it (not CARGO_HOME) for runtime use by `user`.
RUN rustup component add --toolchain nightly rustc-codegen-cranelift-preview \
 && chmod -R a+w "$RUSTUP_HOME"

# ─── 3. uv + Python 3.14 + Python tooling — uv ships weekly ───────────────
# uv binary → /usr/local/bin (UV_INSTALL_DIR). uv-managed Python →
# UV_PYTHON_INSTALL_DIR, uv tools (ruff, basedpyright) → UV_TOOL_DIR with
# their shims in UV_TOOL_BIN_DIR=/usr/local/bin — all shared paths set in §1b
# so `user` (not just root) can use them. chmod a+rwX so a runtime
# `uv tool install` / `uv python install` as `user` can write the dirs too.
ENV UV_INSTALL_DIR=/usr/local/bin
# 7-day PyPI publish cooldown for every uv invocation — the build-time tool
# installs below AND runtime `uvx` / `uv tool install` as `user`. uv refuses any
# dep published more recently. Threaded from var.pip_proxy_cooldown_value via the
# BuildKit build-arg. See docs/PYTHON_SAFETY.md.
ARG UV_EXCLUDE_NEWER="7 days"
ENV UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER}
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && uv python install 3.14 \
 && uv tool install ruff \
 && uv tool install basedpyright \
 && chmod -R a+rwX /usr/local/uv

# ─── 4. Node 22 runtime + pnpm + npm-distributed LSPs — turn over monthly ───
# The node runtime stays (the LSP servers are #!/usr/bin/env node), but the
# bundled npm/npx CLIs are BANNED: every package install must go through bun or
# pnpm against the Verdaccio proxy (§top), so the 7-day supply-chain gate can't
# be sidestepped by an `npm install`. We therefore:
#   1. delete the npm/npx/corepack CLIs nodesource bundles (corepack is Node's
#      pnpm/yarn shim manager — an ungated npm-registry fetch path we don't use),
#   2. install pnpm via bun (pulled through the proxy via NPM_CONFIG_REGISTRY),
#   3. symlink npm→pnpm and npx→bunx so any stray `npm`/`npx` call still works
#      AND stays gated (pnpm honors NPM_CONFIG_REGISTRY/.npmrc; bunx is bun).
# typescript-language-server + tsc for TS; bash/yaml language servers for the
# homelab's heavy YAML+shell footprint; vscode-langservers-extracted bundles
# JSON/HTML/CSS/ESLint LSPs. Installed with bun (gated). See docs/DEP_SAFETY.md.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /usr/lib/node_modules/npm /usr/local/lib/node_modules/npm \
      /usr/lib/node_modules/corepack /usr/local/lib/node_modules/corepack \
      /usr/bin/npm /usr/bin/npx /usr/bin/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
 && bun install -g pnpm \
 && ln -sf /usr/local/bun/bin/pnpm /usr/local/bin/npm \
 && ln -sf "$(command -v bunx)" /usr/local/bin/npx \
 && bun install -g \
      typescript \
      typescript-language-server \
      bash-language-server \
      yaml-language-server \
      vscode-langservers-extracted \
 && rm -rf /var/lib/apt/lists/*

# ─── 5. Static-binary CLIs from upstream releases ──────────────────────────
# yq (Go), gh (GitHub CLI), terraform-ls, delta (git-diff renderer).
# Versions pinned where the upstream offers a stable release URL.
RUN mkdir -p /etc/apt/keyrings \
 # yq — single Go binary, latest is fine
 && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
       -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq \
 # gh CLI via GitHub's apt repo
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 # terraform-ls (HashiCorp)
 && TFLS_VERSION=0.36.4 \
 && curl -fsSL "https://releases.hashicorp.com/terraform-ls/${TFLS_VERSION}/terraform-ls_${TFLS_VERSION}_linux_amd64.zip" \
       -o /tmp/tfls.zip \
 && unzip /tmp/tfls.zip -d /usr/local/bin \
 && rm /tmp/tfls.zip \
 # delta — git-diff renderer (rust binary, musl static)
 && DELTA_VERSION=0.18.2 \
 && curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
       -o /tmp/delta.tgz \
 && tar -xzf /tmp/delta.tgz -C /tmp \
 && mv "/tmp/delta-${DELTA_VERSION}-x86_64-unknown-linux-musl/delta" /usr/local/bin/delta \
 && rm -rf /tmp/delta.tgz "/tmp/delta-${DELTA_VERSION}-x86_64-unknown-linux-musl" \
 && rm -rf /var/lib/apt/lists/*

# ─── 5a2. fj (forgejo-cli) — Forgejo-native CLI for PRs/issues/Actions ──────
# Remote API client (like gh/tea). Authenticates with a Forgejo PAT, configured
# at runtime from ~/.local/share/forgejo-cli/keys.json (written by the entrypoint
# from FORGEJO_TOKEN — a write:repository,write:issue token minted for the
# RESTRICTED `opencode` Forgejo user by the git bootstrap). Lets opencode read
# PRs/commits + Actions tasks and dispatch/comment. Pinned + checksum-verified
# (it's a contrib tool, not first-party Forgejo).
RUN curl -fsSL -o /tmp/fj.tgz \
      "https://codeberg.org/forgejo-contrib/forgejo-cli/releases/download/v0.5.0/forgejo-cli-x86_64-linux.tar.gz" \
 && echo "a6fe25844cb15d8a97e4909933a336e4969b228bffc0da489e100d5860362255  /tmp/fj.tgz" | sha256sum -c - \
 && tar -xzf /tmp/fj.tgz -C /usr/local/bin fj \
 && chmod 0755 /usr/local/bin/fj \
 && rm -f /tmp/fj.tgz

# ─── 5b. SSH server + opkssh (OpenID-authenticated SSH) ────────────────────
# Lets the user SSH straight into THIS container (not the tailscale
# sidecar) authenticated by Zitadel. opkssh's `verify` runs as the
# AuthorizedKeysCommand: the client's SSH cert carries a Zitadel ID token,
# which opkssh checks against the issuer's JWKS + /etc/opk policy. No
# static SSH keys, no CA daemon. sshd binds in the pod's shared netns so
# it's reachable on the tailnet IP (the tailscale ingress sidecar); the
# pod-network side stays blocked by the netpol default-deny baseline.
#
# Host key + /etc/opk perms are finalized at runtime by entrypoint.sh
# (host key persists on the opencode-data PVC; ConfigMap-mounted opk
# config is copied to /etc/opk with the root:opksshuser 640 opkssh wants).
ENV OPKSSH_VERSION=0.14.0
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --no-create-home --shell /usr/sbin/nologin opksshuser \
 && curl -fsSL "https://github.com/openpubkey/opkssh/releases/download/v${OPKSSH_VERSION}/opkssh-linux-amd64" \
       -o /usr/local/bin/opkssh \
 && chown root:root /usr/local/bin/opkssh \
 && chmod 0755 /usr/local/bin/opkssh \
 && mkdir -p /run/sshd /etc/opk \
 && printf '%s\n' \
      'PubkeyAuthentication yes' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin prohibit-password' \
      'AuthorizedKeysCommand /usr/local/bin/opkssh verify %u %k %t' \
      'AuthorizedKeysCommandUser opksshuser' \
      'HostKey /home/user/.local/share/opencode/sshd/ssh_host_ed25519_key' \
      > /etc/ssh/sshd_config.d/opkssh.conf

# Default git identity for opencode commits. Written SYSTEM-WIDE
# (/etc/gitconfig) rather than a user ~/.gitconfig: opencode runs as `user`
# (not root), and a root-only --global config wouldn't apply. --system is
# read by every account (both `user` and a root SSH session). Override
# per-repo via `git -c user.email=… -c user.name=…` if needed.
#
# Email value is generic on purpose — Forgejo's UI links commits to a
# user by matching the email field on the user record. The `opencode`
# Forgejo user is created with email `opencode@<magic_domain>` by the
# Forgejo bootstrap; to make the UI link commits to that user, override
# user.email per-repo.
#
# init.defaultBranch = main matches Forgejo's default (and current
# upstream convention), so `git init` inside the pod produces repos
# that align with what `git push` to Forgejo expects.
RUN git config --system user.name  "opencode" \
 && git config --system user.email "opencode@local" \
 && git config --system init.defaultBranch main \
 && git config --system pull.rebase false

# Shell environment for humans, in ONE place. /etc/bash.bashrc is sourced by
# every interactive bash — opencode's spawned `/terminal` (non-login) AND SSH
# login shells (Debian's /etc/profile sources /etc/bash.bashrc) — for both
# `user` and `root` (system-wide). sshd hands SSH sessions a fresh env (the
# §1b Docker ENV toolchain paths don't propagate), so the relocated /usr/local
# homes + PATH are re-exported here; the PATH guard avoids duplicate entries in
# nested shells. `ll` alias rides along (aliases aren't inherited, so they must
# be sourced per interactive shell).
RUN printf '%s\n' \
      '' \
      '# opencode: relocated /usr/local toolchains (see Dockerfile §1b).' \
      'export CARGO_HOME=/usr/local/cargo' \
      'export RUSTUP_HOME=/usr/local/rustup' \
      'export BUN_INSTALL=/usr/local/bun' \
      'export UV_PYTHON_INSTALL_DIR=/usr/local/uv/python' \
      'export UV_TOOL_DIR=/usr/local/uv/tools' \
      'case ":$PATH:" in' \
      '  *:/usr/local/cargo/bin:*) ;;' \
      '  *) export PATH="/usr/local/cargo/bin:/usr/local/bun/bin:$PATH" ;;' \
      'esac' \
      "alias ll='ls -alh'" \
      >> /etc/bash.bashrc \
 # Re-export the package-proxy registry vars for SSH login shells. sshd hands a
 # scrubbed env (the Docker ENV at the top doesn't propagate), and bun IGNORES
 # $HOME/.npmrc (oven-sh/bun#22971), so without this an interactive `bun install`
 # over SSH would bypass Verdaccio and hit npmjs direct. BUN_CONFIG_REGISTRY is
 # bun's reliable knob; NPM_CONFIG_REGISTRY covers pnpm. Baked from the
 # NPM_REGISTRY build_arg (literal URL). opencode-spawned shells already inherit
 # these via setpriv, so this only matters for SSH. See docs/DEP_SAFETY.md.
 && printf '%s\n' \
      "export BUN_CONFIG_REGISTRY=${NPM_REGISTRY}" \
      "export NPM_CONFIG_REGISTRY=${NPM_REGISTRY}" \
      "export BUN_CONFIG_MAX_HTTP_REQUESTS=8" \
      "export UV_EXCLUDE_NEWER='${UV_EXCLUDE_NEWER}'" \
      >> /etc/bash.bashrc

# ─── 5d. Tailwind CSS CLI — dioxus styling pipeline ────────────────────────
# v4 standalone CLI; installs a `tailwindcss` binary on PATH. Own layer so
# an opencode bump (§6) doesn't reinstall it.
RUN bun install -g @tailwindcss/cli

# ─── 5h. Chromium + chromedriver for thirtyfour e2e testing ────────────────
# thirtyfour (Rust WebDriver client) drives a REAL browser through a WebDriver
# server, so it needs BOTH the driver AND the browser. chromium + chromium-driver
# (chromedriver) come from the Debian repo, version-locked together (148.x) so
# the driver always matches the browser. chromedriver installs at
# /usr/bin/chromedriver (on PATH); chromium at /usr/bin/chromium. (Firefox /
# geckodriver omitted by request — add firefox-esr + the Mozilla geckodriver
# release here if you ever want the gecko engine too.)
# Placed LOW (just above the setuid strip + opencode) so adding it leaves the
# expensive Rust/Python/node layers above fully cached — only §6 rebuilds.
# IN-CONTAINER NOTE: pass `--no-sandbox` in your thirtyfour Chrome caps — the
# chromium setuid sandbox helper is stripped by §5i below, and userns sandboxing
# isn't available in this pod anyway. Add `--headless=new` for headless runs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium chromium-driver \
 && rm -rf /var/lib/apt/lists/*

# ─── 5i. Setuid hardening — no privesc path to root for `user` ─────────────
# opencode runs as the unprivileged `user`; the ONLY way to root is opkssh
# sshd. Strip the setuid/setgid bit from EVERY binary. Removes
# su/mount/umount/passwd/chsh/chfn/
# gpasswd/newgrp/etc. + chromium's chrome-sandbox helper (§5h, hence
# `--no-sandbox` for thirtyfour) as escalation surface. sudo is NOT installed;
# root has no password (opkssh-only). Combined with allow_privilege_escalation
# = false on the pod, `user` has no path to root.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# ─── 6. opencode itself — changes most often ──────────────────────────────
# bun global dir is /usr/local/bun (BUN_INSTALL, §1b) — opencode + the §5d
# tailwindcss CLI land there, on the shared PATH. chmod a+rwX so a runtime
# `bun install -g` as `user` still works. /home/user dirs are pre-created +
# chowned so opencode (uid 1001) owns its config/state/working tree from the
# first boot (the entrypoint also chowns the PVC/emptyDir mounts at runtime).
# BUN_CONFIG_MAX_HTTP_REQUESTS (global ENV at top) throttles bun AND its `fetch`,
# so it also caps opencode-ai's postinstall (which fetches the ~13 platform
# packages under bun) — the path that was 502'ing Verdaccio.
RUN bun install -g opencode-ai \
 && mkdir -p /home/user/.config/opencode /home/user/.local/share/opencode /home/user/working \
 && chown -R user:user /home/user \
 && chmod -R a+rwX /usr/local/bun

# opencode treats CWD as the project root. Starting in /home/user/working
# (instead of / or /home/user) keeps clones, scratch files, and edits in one
# place — and the PVC subPath mount in services/opencode.tf persists it
# across pod restarts.
WORKDIR /home/user/working
ENV HOME=/home/user

EXPOSE 4096
EXPOSE 22

# entrypoint.sh finalizes the sshd host key + /etc/opk perms, starts sshd
# in the background, then execs `opencode web`. Baked from the build
# context (services/opencode-jobs.tf adds it to context_files).
#
# `web` (not `serve`) so the same process serves the browser SPA, REST
# API, OpenAPI schema, and SSE event stream. `opencode attach <url>`
# from a desktop CLI talks to the same backend.
#
# 0.0.0.0 (not 127.0.0.1): kubelet TCP probes hit the pod's eth0 IP, so
# a loopback bind makes them fail and triggers a liveness kill loop.
# Cross-pod :4096 is still blocked by the netpol-baseline default-deny
# ingress; localhost connections from the nginx + oauth2-proxy sidecars
# in this same pod are unaffected.
COPY entrypoint.sh /usr/local/bin/opencode-entrypoint.sh
RUN chmod 0755 /usr/local/bin/opencode-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]
