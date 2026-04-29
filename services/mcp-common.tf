locals {
  # Shared bootstrap package shipped into every per-MCP build context as a
  # subdirectory. Keys are the intended subpaths (`mcp_common/<f>`); the
  # buildkit-job module sanitizes them to flat ConfigMap data keys and uses
  # `items[].path` on the volume mount to materialize the originals at
  # /workspace/mcp_common/<f>. Any change here re-hashes every consuming MCP
  # build job (templates/buildkit-job mixes context_dirs into context_hash).
  mcp_common_files = {
    for f in fileset("${path.module}/../data/images/mcp-common/mcp_common", "*.py") :
    "mcp_common/${f}" => file("${path.module}/../data/images/mcp-common/mcp_common/${f}")
  }
}
