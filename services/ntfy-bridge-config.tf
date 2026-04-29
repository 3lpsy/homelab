resource "kubernetes_config_map" "ntfy_bridge_script" {
  metadata {
    name      = "ntfy-bridge-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "ntfy-bridge.py" = file("${path.module}/../data/scripts/ntfy-bridge.py")
  }
}
