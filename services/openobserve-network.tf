# NetworkPolicies for the `openobserve` namespace.
#
# Holds openobserve + its bootstrap and provisioner Jobs.
#
# Cross-namespace flows this file owns:
#   - egress  openobserve-bootstrap → vault:8201 (writes service-account creds)
#   - egress  openobserve-provisioner → ntfy (ntfy ns) :8080 (alert dest test)
#   - ingress otel-collector (otel-collector ns) → openobserve :5080 (OTLP)

module "openobserve_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.openobserve.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # openobserve's tailscale sidecar reaches Headscale + DERP.
  allow_internet_egress = true
  # Bootstrap pod uses its SA token to log in to Vault; provisioner reads
  # the OO API for Job status.
  allow_kube_api_egress = true
}

# Cross-ns egress: openobserve-bootstrap Job → vault:8201.
# Bootstrap writes service-account creds back to Vault via host_aliases
# (FQDN pinned to vault Service ClusterIP). Mirror of the ingress allow
# in vault/vault-network.tf (single ingress block w/ multiple `from`).
resource "kubernetes_network_policy" "openobserve_bootstrap_to_vault" {
  metadata {
    name      = "openobserve-bootstrap-to-vault"
    namespace = kubernetes_namespace.openobserve.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "openobserve-bootstrap" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8201"
      }
    }
  }
}

# Cross-ns egress: openobserve-provisioner Job → ntfy (ntfy ns) :8080.
# Provisioner POSTs a test alert to ntfy.<ntfy-ns>.svc:8080 when wiring
# an OO alert destination. Mirror ingress lives in
# services/ntfy.tf as ntfy-from-openobserve-provisioner.
resource "kubernetes_network_policy" "openobserve_provisioner_to_ntfy" {
  metadata {
    name      = "openobserve-provisioner-to-ntfy"
    namespace = kubernetes_namespace.openobserve.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "openobserve-provisioner" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.ntfy.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "ntfy" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}

# Cross-ns ingress: otel-collector (otel-collector ns) → openobserve :5080.
# OTLP/HTTP at /api/<org>/v1/{logs,metrics,traces}. Mirror egress lives in
# services/otel-collector.tf as otel-collector-to-openobserve.
resource "kubernetes_network_policy" "openobserve_from_otel_collector" {
  metadata {
    name      = "openobserve-from-otel-collector"
    namespace = kubernetes_namespace.openobserve.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "openobserve" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.otel_collector.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "otel-collector" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5080"
      }
    }
  }
}
