# NetworkPolicies for the `opencode` namespace.
#
# Single-pod namespace (opencode + nginx + oauth2-proxy + tailscale
# sidecars). Cross-ns flows this file owns:
#   - egress  opencode (oauth2-proxy) → oidc:443 (OIDC token exchange + JWT validation)
#   - egress  opencode → litellm:443 (provider call)
#   - egress  opencode → mcp:443     (mcp-shared gateway, fan-out to MCP backends)
#   - egress  opencode → registry-proxy:443 (in-pod podman base-image pulls)

module "opencode_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.opencode.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Tailscale sidecar reaches Headscale + DERP over the public internet;
  # provider sdks (`@ai-sdk/openai-compatible`) install from npm on first
  # `opencode web` boot, also via the public internet.
  allow_internet_egress = true
  # Tailscale sidecar persists state to a k8s Secret via TS_KUBE_SECRET.
  allow_kube_api_egress = true
}

# Cross-ns egress: opencode → oidc:443 for the OIDC code+PKCE flow
# (discovery, JWKS, token exchange, userinfo) and bearer-JWT validation.
# Mirror ingress in services/zitadel-network.tf as oidc-from-opencode.
resource "kubernetes_network_policy" "opencode_to_oidc" {
  metadata {
    name      = "opencode-to-oidc"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "opencode" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "oidc" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: opencode → litellm:443 (nginx-fronted, TLS-terminating
# port on the litellm Service). Mirror ingress lives in
# services/litellm-network.tf as litellm-from-opencode.
resource "kubernetes_network_policy" "opencode_to_litellm" {
  metadata {
    name      = "opencode-to-litellm"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "opencode" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.litellm.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "litellm" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: opencode → git:{443,2222}. SSH (port 2222) is the only
# practical path for opencode's git pushes/pulls; :443 is reserved for any
# future API use (e.g. running an opencode skill that creates a repo via
# the REST surface). Mirror ingress lives in services/git.tf as
# `git_from_opencode`.
resource "kubernetes_network_policy" "opencode_to_git" {
  metadata {
    name      = "opencode-to-git"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "opencode" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.git.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "forgejo" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
      ports {
        protocol = "TCP"
        port     = "2222"
      }
    }
  }
}

# Cross-ns egress: opencode → mcp:443 (mcp-shared nginx gateway). Mirror
# ingress lives in services/mcp-shared-network.tf as
# mcp-shared-from-opencode.
resource "kubernetes_network_policy" "opencode_to_mcp_shared" {
  metadata {
    name      = "opencode-to-mcp-shared"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "opencode" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.mcp.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "mcp-shared" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# Cross-ns egress: opencode → registry-proxy:443. The in-pod podman pulls
# docker.io / ghcr.io base images through the in-cluster pull-through mirrors
# (registry-dockerio / registry-ghcrio, both in the registry-proxy ns) to dodge
# Docker Hub's per-IP anonymous rate limit. The mirror FQDNs are pinned to the
# Service ClusterIPs via host_aliases in opencode.tf; those ClusterIPs sit in
# the service CIDR that the netpol baseline's internet-egress rule excludes, so
# this explicit allow is required. Mirror ingress lives in
# services/registry-proxy.tf as registry-proxy-from-opencode.
resource "kubernetes_network_policy" "opencode_to_registry_proxy" {
  metadata {
    name      = "opencode-to-registry-proxy"
    namespace = kubernetes_namespace.opencode.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "opencode" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.registry_proxy.metadata[0].name
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
