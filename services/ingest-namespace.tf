resource "kubernetes_namespace" "ingest" {
  metadata {
    name = "ingest"
  }
}
