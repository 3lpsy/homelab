resource "kubernetes_namespace" "otel_collector" {
  metadata {
    name = "otel-collector"
  }
}
