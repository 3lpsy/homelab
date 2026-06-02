# NetworkPolicies for the `grafana` namespace.
#
# Single-pod namespace (grafana + nginx + tailscale sidecars). Cross-ns
# flows this file owns:
#   - egress  grafana → oidc:443 (OIDC sign-in)
#   - egress  grafana → prometheus (prometheus ns) :9090 (datasource)

module "grafana_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.grafana.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP; oauth2 token exchange
  # against Zitadel goes via host_aliases (cross-ns, allowed below).
  allow_internet_egress = true
  # Tailscale sidecar uses TS_KUBE_SECRET to persist state to a k8s Secret.
  allow_kube_api_egress = true
}

# Cross-ns egress: grafana → oidc:443 for the OIDC sign-in flow against
# Zitadel. Mirror ingress lives in services/zitadel-network.tf as
# oidc-from-grafana.
resource "kubernetes_network_policy" "grafana_to_oidc" {
  metadata {
    name      = "grafana-to-oidc"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "grafana" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "oidc"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: grafana → prometheus (prometheus ns) :9090.
# Datasource URL is prometheus.prometheus.svc.cluster.local:9090
# (see grafana.tf datasources block). Mirror ingress lives in
# services/prometheus-network.tf as prometheus-from-grafana.
resource "kubernetes_network_policy" "grafana_to_prometheus" {
  metadata {
    name      = "grafana-to-prometheus"
    namespace = kubernetes_namespace.grafana.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "grafana" }
    }
    policy_types = ["Egress"]

    egress {
      to {
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
        port     = "9090"
      }
    }
  }
}
