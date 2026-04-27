# Reusable namespace baseline NetworkPolicy.
#
# Applies to every pod in the namespace and provides:
#   - default-deny ingress + egress
#   - all intra-namespace ingress + egress
#   - DNS egress to kube-system (UDP + TCP 53)
#   - (toggleable) K8s API egress on TCP 6443 via ipBlock excluding cluster CIDRs
#   - (toggleable) general internet egress on all ports via ipBlock excluding cluster CIDRs
#
# Per-service additive cross-namespace allows are separate `kubernetes_network_policy`
# resources in `<service>-network.tf`.
#
# kube-router (K3s' built-in policy controller) inserts an unconditional
# ACCEPT for `--src-type LOCAL` at the top of every per-pod firewall chain,
# so kubelet probes from the local node bypass policy structurally — no
# probe-allow rule needed here.

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

resource "kubernetes_network_policy" "baseline" {
  metadata {
    name      = "default-deny"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # Intra-namespace ingress
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }
    }

    # Intra-namespace egress
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }
      }
    }

    # DNS egress to kube-system (UDP + TCP — TCP fallback for >512-byte responses)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    # K8s API egress (post-DNAT to host:6443).
    # `kubernetes.default.svc:443` is in the service CIDR but kube-proxy
    # rewrites the destination to the node IP before iptables NetworkPolicy
    # evaluation, so the policy must allow the host IP via ipBlock.
    dynamic "egress" {
      for_each = var.allow_kube_api_egress ? [1] : []
      content {
        to {
          ip_block {
            cidr = "0.0.0.0/0"
            except = [
              var.pod_cidr,
              var.service_cidr,
            ]
          }
        }
        ports {
          protocol = "TCP"
          port     = "6443"
        }
      }
    }

    # General internet egress (Tailscale Headscale + DERP, BuildKit Dockerfile
    # FROMs, exit-node WireGuard, ML model downloads, app marketplace fetches).
    # ipBlock excludes the cluster's pod + service CIDRs so pod-to-pod traffic
    # still requires explicit cross-namespace allow rules.
    dynamic "egress" {
      for_each = var.allow_internet_egress ? [1] : []
      content {
        to {
          ip_block {
            cidr = "0.0.0.0/0"
            except = [
              var.pod_cidr,
              var.service_cidr,
            ]
          }
        }
      }
    }
  }
}
