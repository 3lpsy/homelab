# Shared tinyproxy config for all exit-node pods. Content is identical per
# pod — the only variation between exit-nodes is which WireGuard tunnel the
# pod egresses through, which is handled by the wireguard container, not
# tinyproxy.

resource "kubernetes_config_map" "exitnode_tinyproxy_config" {
  metadata {
    name      = "exitnode-tinyproxy-config"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  data = {
    "tinyproxy.conf" = <<-EOT
      User tinyproxy
      Group tinyproxy
      Port 8888
      Listen 0.0.0.0
      Timeout 600
      LogLevel Warning
      MaxClients 100
      DisableViaHeader Yes
      Allow ${var.k8s_pod_cidr}
      Allow ${var.k8s_service_cidr}
    EOT
  }
}
