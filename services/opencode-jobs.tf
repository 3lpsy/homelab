# BuildKit Job for the opencode `web` image.
#
# Pushes ${local.thunderbolt_registry}/opencode:latest. Rebuilds keyed
# off the Dockerfile hash, so a steady-state apply is a no-op.

module "opencode_build" {
  source = "./../templates/buildkit-job"

  name      = "opencode"
  image_ref = local.opencode_image

  context_files = {
    "Dockerfile"   = file("${path.module}/../data/images/opencode/Dockerfile")
    "entrypoint.sh" = file("${path.module}/../data/opencode/entrypoint.sh")
  }

  # npm registry → in-cluster Verdaccio proxy. Same FQDN the runtime .npmrc
  # uses; the build pod resolves it via the npm host_alias threaded through
  # local.buildkit_job_shared. bun + pnpm both read NPM_CONFIG_REGISTRY from
  # this. See docs/DEP_SAFETY.md.
  build_args = {
    NPM_REGISTRY = "https://${local.opencode_npm_proxy_fqdn}/"
    # crates.io → chilled-crates sparse index (same form as the runtime cargo
    # config + the mcp-rs builds). Gates the image-build cargo path.
    CRATES_REGISTRY = "sparse+https://${local.opencode_crates_proxy_fqdn}/index/"
    # 7-day PyPI publish cooldown for every uv invocation (build + runtime).
    UV_EXCLUDE_NEWER = var.pip_proxy_cooldown_value
  }

  # Heavy: §2b now compiles the cargo dev tools FROM SOURCE (cargo install
  # dioxus-cli/udeps/expand/audit/just) instead of cargo-binstall — dioxus-cli in
  # particular pulls hundreds of crates and needs lots of RAM. Sized generously
  # for artemis. If you don't need dioxus, dropping it from the Dockerfile §2b
  # would shrink this a lot.
  resources = {
    requests = { cpu = "2", memory = "4Gi" }
    limits   = { cpu = "8", memory = "16Gi" }
  }
  # 30m: a COLD build now compiles cargo-nextest + sccache FROM SOURCE (§2d/§2e,
  # sccache alone is ~5-10m), adds the cranelift component (§2f), and installs
  # chromium + chromedriver (§5h) on top of §2b's dioxus-cli/udeps/etc. compiles.
  # This is the terraform WAIT timeout (Job → Complete), not a pod deadline —
  # too-short just fails `apply` while the build keeps running. Warm rebuilds
  # (cached layers) finish in seconds, so the headroom is free.
  timeout = "30m"

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}
