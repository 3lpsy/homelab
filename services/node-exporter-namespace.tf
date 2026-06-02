resource "kubernetes_namespace" "node_exporter" {
  metadata {
    name = "node-exporter"
  }
}
