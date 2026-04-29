# NetworkPolicies for the `monitoring` namespace.
#
# The namespace hosts: prometheus + alertmanager + ntfy-bridge (one pod,
# three sidecars), grafana, ntfy, openobserve, openobserve-bootstrap,
# openobserve-provisioner, otel-collector, node-exporter, kube-state-metrics,
# reloader, headscale-host-otel installer.
#
# Cross-namespace flows today:
#   - openobserve-bootstrap → vault:8201 (writes service-account creds via
#     own Tailscale sidecar; allow on Vault side covers it)
#   - Prometheus scrapes:
#       * self (intra-ns)
#       * kube-state-metrics (intra-ns)
#       * node-exporter on every node:9100 (host-network, ipBlock egress)
#       * kubelet on every node:10250 (host-network, ipBlock egress)
#       * cadvisor via kubelet:10250 (host-network, ipBlock egress)
#       * openwrt over Tailscale (covered by baseline internet egress)
#       * kubernetes-pods discovery — currently no pods carry the
#         `prometheus.io/scrape=true` annotation cluster-wide, so this
#         job collects no targets. If the annotation gets set in the
#         future, add a per-target cross-ns egress here.
#   - Reloader: kube-API only (covered by baseline)
#   - kube-state-metrics: kube-API only (covered by baseline)
#   - mcp-prometheus → prometheus:9090 (allow lives in mcp namespace)
#
# Internet + K8s API egress on (defaults). Both required: Tailscale
# sidecars (grafana, ntfy, openobserve, prometheus admin tunnel) need
# internet for Headscale/DERP; Reloader and kube-state-metrics need API.

module "monitoring_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.monitoring.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-namespace egress: monitoring → vault:8201.
# Used by openobserve-bootstrap to write service-account creds back to
# Vault via host_aliases (FQDN pinned to the vault Service ClusterIP).
# Mirror of the ingress allow in vault/vault-network.tf.
resource "kubernetes_network_policy" "monitoring_to_vault" {
  metadata {
    name      = "monitoring-to-vault"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {}
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

# Cross-namespace ingress: mcp-prometheus → prometheus:9090.
# Mirror of the egress allow in services/mcp-prometheus-network.tf.
# NetworkPolicies are bidirectional — both source egress AND dest ingress
# must permit, or the SYN gets dropped at one of the two pod chains.
resource "kubernetes_network_policy" "prometheus_from_mcp_prometheus" {
  metadata {
    name      = "prometheus-from-mcp-prometheus"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "prometheus"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "mcp"
          }
        }
        pod_selector {
          match_labels = {
            app = "mcp-prometheus"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}

# Prometheus egress to host-network scrape targets (node-exporter on 9100,
# kubelet/cadvisor on 10250). Both run on the K3s node's host network, so
# their endpoint IP is the node IP — outside the cluster CIDRs and only
# reachable via ipBlock allow.
resource "kubernetes_network_policy" "prometheus_scrape_host_targets" {
  metadata {
    name      = "prometheus-scrape-host-targets"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "prometheus"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            var.k8s_pod_cidr,
            var.k8s_service_cidr,
          ]
        }
      }
      ports {
        protocol = "TCP"
        port     = "9100"
      }
      ports {
        protocol = "TCP"
        port     = "10250"
      }
    }
  }
}
