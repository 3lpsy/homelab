locals {
  # Single Rust workspace ships every MCP server. The whole workspace travels
  # as the BuildKit context for each build (cargo-chef in the Dockerfile makes
  # the dep layer cacheable across builds). Each per-server module passes
  # `build_args = { BIN = "mcp-<name>" }` to bake the right binary.
  #
  # `abspath()` is required: `fileset("${path.module}/../...", "**")` returns
  # an "inconsistent result" error in Terraform because the `..` in the base
  # path resolves differently across plan/apply phases. Canonicalising removes
  # the `..` so fileset gets a stable input.
  mcp_rs_root = abspath("${path.module}/../data/images/mcp-rs")
  mcp_rs_files = {
    for f in fileset(local.mcp_rs_root, "**") :
    f => file("${local.mcp_rs_root}/${f}")
    if !startswith(f, "target/") && !startswith(f, ".git/")
  }

  # One shared cache tag so the heavy cargo-chef dep layer is exported and
  # imported by all 7 build jobs. Without this, each per-server module would
  # derive its own `<image>:cache` and rebuild the dep layer from scratch.
  mcp_rs_cache_ref = "${local.thunderbolt_registry}/mcp-rs:cache"
}
