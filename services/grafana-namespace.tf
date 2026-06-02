resource "kubernetes_namespace" "grafana" {
  metadata {
    name = "grafana"
  }
}
