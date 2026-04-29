# Shared data volume for stateful MCP servers (mcp-filesystem, mcp-memory).
# Each service namespaces itself under /data/<hash(api_key+per-service-salt)>
# so they never collide on disk. RWO is fine on this single-node K3s — both
# pods land on the same node.
#
resource "kubernetes_persistent_volume_claim" "mcp_data" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "mcp-data"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "20Gi"
      }
    }
  }
  wait_until_bound = false
}
