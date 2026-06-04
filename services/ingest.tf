resource "kubernetes_namespace" "ingest" {
  metadata {
    name = "ingest"
  }
}

# In-cluster registry pull secret for the `ingest` namespace. Shared by the
# namespace's image-pulling consumers (qbt; formerly ingest-ui). Same
# resource address it had in the old ingest-ui.tf so state migrates in place.
resource "kubernetes_secret" "ingest_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.thunderbolt_registry}" = {
          username = "internal"
          password = random_password.registry_user_passwords["internal"].result
          auth     = base64encode("internal:${random_password.registry_user_passwords["internal"].result}")
        }
      }
    })
  }
}

# Dropzone PVC — owned by the `ingest` namespace. Written by syncthing
# (remote sync from trusted devices). Kept as a standalone PVC so the
# dropzone survives syncthing pod restarts.
resource "kubernetes_persistent_volume_claim" "media_dropzone" {
  lifecycle {
    prevent_destroy = true
  }
  metadata {
    name      = "media-dropzone"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.media_dropzone_size
      }
    }
  }
  wait_until_bound = false
}

# =============================================================================
# NetworkPolicies for the `ingest` namespace.
#
# Hosts: syncthing (tailnet ingress, writes to the media-dropzone PVC) and
# qbt (excluded from the baseline; its exitnode SOCKS egress is declared in
# exitnode-network.tf as exitnode-socks-from-qbt).
# =============================================================================

module "ingest_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.ingest.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr

  excluded_app_labels = ["qbt"]
}
