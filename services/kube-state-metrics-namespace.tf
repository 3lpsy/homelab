resource "kubernetes_namespace" "kube_state_metrics" {
  metadata {
    name = "kube-state-metrics"
  }
}
