# opencode `web` server image with a full polyglot dev toolchain baked
# in. Layers ordered bottom-to-top from least likely to invalidate to
# most likely — a new opencode-ai release only rebuilds the top layer,
# adding an npm LSP rebuilds from layer 4, and so on.
#
# Target arch: amd64 (delphi cluster node). Re-add ARCH detection if
# this image ever needs to run on arm64 nodes.
FROM oven/bun:1

ENV DEBIAN_FRONTEND=noninteractive

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

# ─── 2b. Cargo helper binaries an LLM actually reaches for ────────────────
# udeps + expand need nightly (unstable cargo features / proc-macro
# expander); audit is stable. cargo-binstall fetches pre-built binaries
# from each crate's GitHub releases and only falls back to compile-from-
# source when no release artifact matches the target — turns a ~5-minute
# compile chain into ~30 seconds of download. All three of these crates
# publish musl/glibc x86_64 release binaries, so the fast path hits.
RUN rustup toolchain install nightly --profile minimal \
 && curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
    | bash \
 && cargo binstall -y --locked cargo-udeps cargo-expand cargo-audit

# ─── 3. uv + Python 3.14 + Python tooling — uv ships weekly ───────────────
# uv binary → /usr/local/bin (UV_INSTALL_DIR). uv-managed Python →
# UV_PYTHON_INSTALL_DIR, uv tools (ruff, basedpyright) → UV_TOOL_DIR with
# their shims in UV_TOOL_BIN_DIR=/usr/local/bin — all shared paths set in §1b
# so `user` (not just root) can use them. chmod a+rwX so a runtime
# `uv tool install` / `uv python install` as `user` can write the dirs too.
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && uv python install 3.14 \
 && uv tool install ruff \
 && uv tool install basedpyright \
 && chmod -R a+rwX /usr/local/uv

# ─── 4. Node 22 + npm-distributed LSPs — turn over monthly ─────────────────
# typescript-language-server + tsc for TS; bash/yaml language servers
# for the homelab's heavy YAML+shell footprint; vscode-langservers-extracted
# bundles JSON/HTML/CSS/ESLint LSPs.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g \
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
      >> /etc/bash.bashrc

# ─── 5c. Dioxus toolchain — wasm target + dioxus-cli (dx) ──────────────────
# Placed below the Rust install (§2) + cargo-binstall (§2b) so those heavy
# layers stay cached; a dioxus-cli bump only rebuilds from here. `stable`
# is already the default toolchain (§2) — reinstall is idempotent. binstall
# fetches the dx prebuilt binary; --force overwrites any stale dx.
RUN rustup toolchain install stable \
 && rustup target add wasm32-unknown-unknown \
 && cargo binstall -y dioxus-cli --force

# ─── 5d. Tailwind CSS CLI — dioxus styling pipeline ────────────────────────
# v4 standalone CLI; installs a `tailwindcss` binary on PATH. Own layer so
# an opencode bump (§6) doesn't reinstall it.
RUN bun install -g @tailwindcss/cli

# ─── 5e. just — command runner (Makefile alternative) ─────────────────────
# Static Rust binary via binstall (§2b); own layer so it doesn't churn the
# opencode layer below. Last cargo-touching layer → make CARGO_HOME +
# RUSTUP_HOME world-writable (rust-image pattern) so `user` can run cargo /
# rustup at runtime (registry cache + toolchain writes land here).
RUN cargo binstall -y just \
 && chmod -R a+w "$CARGO_HOME" "$RUSTUP_HOME"

# ─── 5g. Rootless podman (+ compose) for one-off nested dev containers ─────
# Lets opencode spawn throwaway dev containers INSIDE this pod — not
# docker-in-docker, not the host containerd. Works unprivileged because the
# k3s nodes give us userns (no seccomp block) + native rootless overlayfs
# (kernel ≥ 7.0.9), so NO /dev/fuse and NO fuse-overlayfs are needed. crun
# over runc (lighter, better cgroup-v2 + rootless). uidmap ships the setuid
# newuidmap/newgidmap helpers that map the subuid range; slirp4netns gives
# nested containers userspace networking (NATs out as the pod's own egress).
# /etc/subuid + subgid grant root one full /16 of subordinate ids (podman
# default range).
#
# `podman compose` is wired to the Docker Compose v2 binary as its provider
# (compose_providers below) — podman is the engine, there is NO Docker
# daemon. `podman compose up` drives rootless podman against a transient
# socket podman provisions itself. Invoke `podman compose`, not bare
# `docker-compose` (the latter would hunt for a dockerd that isn't here).
RUN apt-get update && apt-get install -y --no-install-recommends \
      podman crun uidmap slirp4netns \
 && rm -rf /var/lib/apt/lists/* \
 # Subordinate id ranges: `user` (uid 1001) runs rootless podman, so it needs
 # its OWN non-overlapping subuid/subgid range. root keeps 100000-165535;
 # `user` gets 165536-231071. Overlapping ranges are rejected by newuidmap.
 && printf '%s\n' 'root:100000:65536' 'user:165536:65536' > /etc/subuid \
 && printf '%s\n' 'root:100000:65536' 'user:165536:65536' > /etc/subgid \
 # Docker Compose v2 (static Go binary) as podman's compose provider. Latest
 # release, matching yq's URL form in §5. amd64-only (image targets amd64).
 && curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
       -o /usr/local/bin/docker-compose \
 && chmod +x /usr/local/bin/docker-compose \
 && mkdir -p /etc/containers \
 # containers.conf: cgroupfs + cgroups disabled (no cgroup-v2 delegation
 # rootless-in-pod; the pod's own k8s limits still cap the whole thing),
 # crun runtime, slirp4netns networking, file event logger (no journald).
 # compose_providers pins `podman compose` to the docker-compose binary above.
 && printf '%s\n' \
      '[engine]' \
      'cgroup_manager = "cgroupfs"' \
      'events_logger = "file"' \
      'runtime = "crun"' \
      'compose_providers = ["docker-compose"]' \
      'compose_warning_logs = false' \
      '' \
      '[containers]' \
      'cgroups = "disabled"' \
      'netns = "slirp4netns"' \
      > /etc/containers/containers.conf \
 # storage.conf: native kernel overlay (NO mount_program key = no
 # fuse-overlayfs). graphroot defaults to $HOME/.local/share/containers,
 # which opencode.tf backs with a disk emptyDir to dodge overlay-on-overlay.
 # vfs is the fallback if native overlay is ever rejected.
 && printf '%s\n' \
      '[storage]' \
      'driver = "overlay"' \
      'runroot = "/run/containers/storage"' \
      '' \
      '[storage.options.overlay]' \
      '# no mount_program => native rootless overlay' \
      > /etc/containers/storage.conf \
 # policy.json: permissive — single-user dev pod, no image signing.
 && printf '%s\n' \
      '{ "default": [ { "type": "insecureAcceptAnything" } ] }' \
      > /etc/containers/policy.json

# ─── 5h. Setuid hardening — no privesc path to root for `user` ─────────────
# opencode runs as the unprivileged `user`; the ONLY way to root is opkssh
# sshd. Strip the setuid/setgid bit from every binary EXCEPT podman's id-map
# helpers (newuidmap/newgidmap), which rootless podman genuinely needs and
# which only write a userns uid_map (not a general root-shell vector). This
# removes su/mount/umount/passwd/chsh/chfn/gpasswd/newgrp/etc. as escalation
# surface. sudo is NOT installed (and must never be); root has no password
# (opkssh-only). allow_privilege_escalation stays true in the pod (podman),
# so the boundary is the absence of escalation TARGETS, enforced here.
RUN find / -xdev -perm /6000 -type f \
      ! -path /usr/bin/newuidmap \
      ! -path /usr/bin/newgidmap \
      -exec chmod a-s {} + 2>/dev/null || true

# ─── 6. opencode itself — changes most often ──────────────────────────────
# bun global dir is /usr/local/bun (BUN_INSTALL, §1b) — opencode + the §5d
# tailwindcss CLI land there, on the shared PATH. chmod a+rwX so a runtime
# `bun install -g` as `user` still works. /home/user dirs are pre-created +
# chowned so opencode (uid 1001) owns its config/state/working tree from the
# first boot (the entrypoint also chowns the PVC/emptyDir mounts at runtime).
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
