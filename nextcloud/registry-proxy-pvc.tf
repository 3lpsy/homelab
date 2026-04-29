# Single shared cache PVC. Both Distribution containers (docker.io and
# ghcr.io upstreams) write here under separate `rootdirectory` subpaths,
# so blobs/manifests from each upstream stay in their own subtree.
#
# No `prevent_destroy` — every layer is regen-able by re-pulling on cache
# miss. Kopia explicitly excludes this PVC (cluster.tf).
resource "kubernetes_persistent_volume_claim" "registry_proxy_data" {
  metadata {
    name      = "registry-proxy-data"
    namespace = kubernetes_namespace.registry_proxy.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = "100Gi"
      }
    }
  }
  wait_until_bound = false
}
