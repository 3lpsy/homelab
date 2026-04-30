# NetworkPolicies for the `litellm` namespace.
#
# Hosts: litellm + litellm-postgres. Both reach each other intra-ns.
# litellm proxies to upstream providers (Bedrock, DeepInfra) via the
# public internet — covered by the baseline's internet egress.

module "litellm_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.litellm.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-ns ingress: thunderbolt-backend → litellm:443. Replaces the
# Tailscale-routed egress that thunderbolt-backend used to do via its
# now-removed sidecar (env THUNDERBOLT_INFERENCE_URL). nginx terminates
# TLS with the litellm.<hs>.<magic> cert; ClusterIP DNAT preserves SNI.
resource "kubernetes_network_policy" "litellm_from_thunderbolt" {
  metadata {
    name      = "litellm-from-thunderbolt"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.thunderbolt.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "thunderbolt-backend" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: mcp-litellm → litellm:443. Replaces the Tailscale-routed
# egress that the mcp-litellm pod used to do via its now-removed sidecar
# (env LITELLM_BASE_URL). The mcp namespace has no baseline NetworkPolicy so
# no source-side egress allow is needed.
resource "kubernetes_network_policy" "litellm_from_mcp_litellm" {
  metadata {
    name      = "litellm-from-mcp-litellm"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "mcp-litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns ingress: navidrome-ingest → litellm:443. The worker tags new
# dropzone files via LiteLLM (filename NER). Source-side egress allow
# lives in services/navidrome-ingest-network.tf.
resource "kubernetes_network_policy" "litellm_from_navidrome_ingest" {
  metadata {
    name      = "litellm-from-navidrome-ingest"
    namespace = kubernetes_namespace.litellm.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "litellm" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.navidrome.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "navidrome-ingest" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
