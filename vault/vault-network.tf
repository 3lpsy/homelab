# NetworkPolicies for the `vault` namespace. Enforced by K3s' built-in
# kube-router netpol controller (always on; not a CNI feature).

# Default-deny + intra-ns + DNS + K8s API egress + internet egress.
#
# Internet egress is required by the colocated tailscale sidecar in the
# vault-0 pod for two layers of WireGuard traffic:
#   1. Direct NAT-punched UDP to peer WAN endpoints (anywhere on the
#      public internet — Tailscale negotiates per-peer endpoints via
#      Headscale).
#   2. DERP fallback over TCP 443 to Tailscale's relay servers when
#      direct UDP isn't possible.
# Without it, vault POD's responses to inbound tailnet traffic (e.g.
# operator running `vault status` over Tailscale) get dropped on the
# pod's veth egress chain because tailscaled can't push the encapsulated
# wireguard packets out.
#
# Vault itself (the binary) egresses essentially nowhere: auto-unseal
# polls only localhost (data/scripts/unseal.sh.tpl); Vault only calls the
# K8s API for TokenReview, which the K8s API egress allow covers.
module "vault_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.vault.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = true
  allow_kube_api_egress = true
}

# Vault-specific cross-namespace ingress.
#
# 8200 — plaintext, in-cluster Vault API. CSI driver in vault-csi reaches
#        this for SecretProviderClass mounts.
# 8201 — TLS, Vault's own listener with the magic-domain cert. Pods that
#        can't reach :8200 because they're outside vault-csi (tls-rotator
#        writes back rotated certs; openobserve-bootstrap in monitoring
#        writes service-account creds) hit :8201 instead. Each consuming
#        pod uses host_aliases to pin `vault.<hs>.<magic>` to the vault
#        Service ClusterIP — the same FQDN the cert is issued for, so SNI
#        + cert validation work without a Tailscale sidecar.
resource "kubernetes_network_policy" "vault_cross_ns" {
  metadata {
    name      = "vault-cross-ns"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "vault"
      }
    }
    policy_types = ["Ingress"]

    # vault-csi → 8200
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "vault-csi"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8200"
      }
    }

    # tls-rotator (cert rotation writes) + monitoring (openobserve-bootstrap
    # service-account creds) → 8201. Kept in a single ingress block with
    # multiple `from` selectors — kube-router collapses same-port rules from
    # different namespace_selectors into one iptables rule with a unioned src
    # ipset and only populates one ns's pods if you split them. One block here
    # forces the union explicitly and keeps both ns's pods in the ipset.
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "tls-rotator"
          }
        }
      }
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
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

