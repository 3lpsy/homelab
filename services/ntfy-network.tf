# NetworkPolicies for the `ntfy` namespace.
#
# Holds the ntfy pod (ntfy + nginx + tailscale sidecars).
# Cross-namespace flows this file owns:
#   - ingress prometheus pod's ntfy-bridge sidecar → ntfy nginx :443
#   - ingress openobserve provisioner job → ntfy:8080 (alert destination test)
#   - ingress grafana → ntfy:443 (Contact Points if enabled)

module "ntfy_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.ntfy.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP.
  allow_internet_egress = true
  # Tailscale sidecar uses TS_KUBE_SECRET to persist state to a k8s Secret.
  allow_kube_api_egress = true
}

# Cross-ns ingress: prometheus pod's ntfy-bridge sidecar → ntfy nginx :443.
# Bridge resolves `ntfy.<hs>.<magic>` via host_aliases (pinned to ntfy
# Service ClusterIP) and POSTs alertmanager webhooks to it.
# Mirror of services/prometheus-network.tf:`prometheus_to_ntfy`.
resource "kubernetes_network_policy" "ntfy_from_prometheus" {
  metadata {
    name      = "ntfy-from-prometheus"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "ntfy" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.prometheus.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "prometheus" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: openobserve-provisioner job → ntfy :8080 (HTTP).
# Provisioner POSTs a test alert to the ntfy.<ntfy-ns>.svc:8080 URL when
# wiring an OO alert destination (see openobserve-provisioner.tf:
# oo_ntfy_internal_url).
resource "kubernetes_network_policy" "ntfy_from_openobserve_provisioner" {
  metadata {
    name      = "ntfy-from-openobserve-provisioner"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "ntfy" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.openobserve.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "openobserve-provisioner" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}
