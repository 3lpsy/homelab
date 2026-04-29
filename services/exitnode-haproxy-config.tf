# HAProxy config for the rotating-exit pod. Renders one `server` line per
# entry in local.exitnode_names (defined in services/exitnode.tf), so adding
# a new wg-<name>.conf to var.wireguard_config_dir automatically extends the
# rotation pool on the next apply.
resource "kubernetes_config_map" "exitnode_haproxy_config" {
  metadata {
    name      = "exitnode-haproxy-config"
    namespace = kubernetes_namespace.exitnode.metadata[0].name
  }

  data = {
    "haproxy.cfg" = templatefile("${path.module}/../data/exitnode-haproxy/haproxy.cfg.tpl", {
      exitnode_names = keys(local.exitnode_names)
      exitnode_ns    = kubernetes_namespace.exitnode.metadata[0].name
    })
  }
}
