resource "kubernetes_namespace" "openobserve" {
  metadata {
    name = "openobserve"
  }
}
