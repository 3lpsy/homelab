resource "kubernetes_namespace" "headlamp" {
  metadata {
    name = "headlamp"
  }
}
