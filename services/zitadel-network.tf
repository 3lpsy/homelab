# NetworkPolicies for the `oidc` namespace.
#
# The oidc namespace is created by vault-conf (vault-conf/zitadel.tf) and
# hosts the Zitadel IdP, its Postgres, the PAT-sync sidecar, and any
# config-time Jobs (e.g. zitadel-domain-verify).
#
# This file owns:
#   - the netpol-baseline for the namespace (default-deny + DNS + internet
#     + kube-API egress, all intra-ns)
#   - cross-namespace ingress allows for OIDC consumers calling Zitadel:443
#     (one policy per consuming ns, scoped to the consuming pod's label,
#     mirroring the egress allow that lives in the consumer's own
#     `<ns>-network.tf`)
#
# Apply order: vault-conf apply runs Zitadel first without netpols (all
# traffic allowed). Services apply then locks the namespace down. Zitadel's
# real traffic (intra-ns Postgres, internet via TS sidecar to Headscale +
# DERP + SES, kube-API for TS_KUBE_SECRET) stays covered by the baseline.

module "oidc_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = "oidc"
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # Zitadel TS sidecar needs Headscale/DERP, the SMTP sender reaches SES.
  allow_internet_egress = true
  # TS sidecar uses TS_KUBE_SECRET to persist state to a k8s Secret.
  allow_kube_api_egress = true
}

# Mirror of services/monitoring-network.tf:`grafana_to_oidc`. Without this,
# kube-router drops Grafana → Zitadel SYNs at the Zitadel pod's ingress chain
# even though the source-side egress allows it. NetworkPolicies are
# bidirectional — both ends must permit.
#
# Pod-scoped to `app = "zitadel"` per memory feedback_netpol_least_privilege.
resource "kubernetes_network_policy" "oidc_from_grafana" {
  metadata {
    name      = "oidc-from-grafana"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "grafana"
          }
        }
        pod_selector {
          match_labels = {
            app = "grafana"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/opencode-network.tf:`opencode_to_oidc`. Opencode's
# oauth2-proxy sidecar talks to Zitadel for the code+PKCE flow, JWKS, and
# bearer-JWT validation (CLI path).
resource "kubernetes_network_policy" "oidc_from_opencode" {
  metadata {
    name      = "oidc-from-opencode"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "opencode"
          }
        }
        pod_selector {
          match_labels = {
            app = "opencode"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/homeassist.tf:`homeassist_to_oidc`. HA's auth_oidc
# integration fetches discovery + JWKS + token endpoint from Zitadel.
resource "kubernetes_network_policy" "oidc_from_homeassist" {
  metadata {
    name      = "oidc-from-homeassist"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "homeassist"
          }
        }
        pod_selector {
          match_labels = {
            app = "homeassist"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/nextcloud-network.tf:`nextcloud_to_oidc`. Nextcloud's
# user_oidc app calls /.well-known/openid-configuration + JWKS + userinfo
# on each login.
resource "kubernetes_network_policy" "oidc_from_nextcloud" {
  metadata {
    name      = "oidc-from-nextcloud"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "nextcloud"
          }
        }
        pod_selector {
          match_expressions {
            key      = "app"
            operator = "In"
            values   = ["nextcloud", "nextcloud-configure-oidc"]
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/jellyfin.tf:`jellyfin_to_oidc`. The 9p4 SSO plugin
# fetches discovery + JWKS + token + userinfo from Zitadel during the
# OIDC code-exchange dance. Same label covers both the main pod and the
# jellyfin-seed Job.
resource "kubernetes_network_policy" "oidc_from_jellyfin" {
  metadata {
    name      = "oidc-from-jellyfin"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "jellyfin"
          }
        }
        pod_selector {
          match_expressions {
            key      = "app"
            operator = "In"
            values   = ["jellyfin", "jellyfin-seed"]
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/audiobookshelf.tf:`audiobookshelf_to_oidc`. ABS verifies
# OIDC tokens by fetching Zitadel's discovery doc + JWKS + userinfo on each
# login, and the seed Job calls /api/auth-settings against ABS itself (intra-ns,
# not in scope here) plus /auth/openid/config?issuer=… against Zitadel.
resource "kubernetes_network_policy" "oidc_from_audiobookshelf" {
  metadata {
    name      = "oidc-from-audiobookshelf"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "audiobookshelf"
          }
        }
        pod_selector {
          match_expressions {
            key      = "app"
            operator = "In"
            values   = ["audiobookshelf", "audiobookshelf-seed"]
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/immich-v2.tf:`immich_to_oidc`. Immich's OIDC handler
# calls Zitadel's discovery, JWKS, /oauth/v2/token, and /oidc/v1/userinfo
# endpoints during the auth-code dance.
resource "kubernetes_network_policy" "oidc_from_immich" {
  metadata {
    name      = "oidc-from-immich"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "immich"
          }
        }
        pod_selector {
          match_labels = {
            app = "immich"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/rustical.tf:`rustical_to_oidc`. OIDC code+PKCE
# auth flow needs Rustical to call Zitadel's /oauth/v2/token endpoint.
resource "kubernetes_network_policy" "oidc_from_rustical" {
  metadata {
    name      = "oidc-from-rustical"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "rustical"
          }
        }
        pod_selector {
          match_labels = {
            app = "rustical"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/git.tf:`git_to_oidc`. Forgejo's OAuth2 source (Zitadel)
# performs the discovery + code+PKCE dance against /.well-known/openid-
# configuration, JWKS, /oauth/v2/token, /oidc/v1/userinfo on first sign-in
# and on token refresh.
resource "kubernetes_network_policy" "oidc_from_git" {
  metadata {
    name      = "oidc-from-git"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "git"
          }
        }
        pod_selector {
          match_expressions {
            key      = "app"
            operator = "In"
            values   = ["forgejo", "forgejo-bootstrap"]
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/frigate.tf:`frigate_to_oidc`. The oauth2-proxy sidecar
# in the frigate pod calls Zitadel's discovery, JWKS, /oauth/v2/token, and
# /oidc/v1/userinfo endpoints during the OIDC code+PKCE dance.
resource "kubernetes_network_policy" "oidc_from_frigate" {
  metadata {
    name      = "oidc-from-frigate"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "frigate"
          }
        }
        pod_selector {
          match_labels = {
            app = "frigate"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/thunderbolt-network.tf:`thunderbolt_to_oidc`.
# Thunderbolt's backend uses Better Auth's genericOAuth plugin, which
# fetches /.well-known/openid-configuration, JWKS, /oauth/v2/token, and
# /oidc/v1/userinfo during the OIDC code+PKCE dance.
resource "kubernetes_network_policy" "oidc_from_thunderbolt" {
  metadata {
    name      = "oidc-from-thunderbolt"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "thunderbolt"
          }
        }
        pod_selector {
          match_labels = {
            app = "thunderbolt-backend"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/litellm-network.tf:`litellm_to_oidc`. LiteLLM's SSO
# callback handler (FOSS GENERIC provider) calls Zitadel's /oauth/v2/token
# and /oidc/v1/userinfo server-side during the OIDC code-exchange dance.
resource "kubernetes_network_policy" "oidc_from_litellm" {
  metadata {
    name      = "oidc-from-litellm"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "litellm"
          }
        }
        pod_selector {
          match_labels = {
            app = "litellm"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/homeassist-z2m.tf:`homeassist_z2m_to_oidc`. The
# oauth2-proxy sidecar in the z2m pod calls Zitadel's discovery, JWKS,
# /oauth/v2/token, and /oidc/v1/userinfo endpoints during the OIDC
# code+PKCE dance.
resource "kubernetes_network_policy" "oidc_from_homeassist_z2m" {
  metadata {
    name      = "oidc-from-homeassist-z2m"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "homeassist"
          }
        }
        pod_selector {
          match_labels = {
            app = "homeassist-z2m"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/prometheus-network.tf:`prometheus_to_oidc`. The
# oauth2-proxy sidecar in the prometheus pod calls Zitadel's discovery,
# JWKS, /oauth/v2/token, and /oidc/v1/userinfo endpoints during the OIDC
# code+PKCE dance.
resource "kubernetes_network_policy" "oidc_from_prometheus" {
  metadata {
    name      = "oidc-from-prometheus"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "prometheus"
          }
        }
        pod_selector {
          match_labels = {
            app = "prometheus"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/pihole-network.tf:`pihole_to_oidc`. The oauth2-proxy
# sidecar in the pihole pod calls Zitadel's discovery, JWKS,
# /oauth/v2/token, and /oidc/v1/userinfo endpoints during the OIDC
# code+PKCE dance.
resource "kubernetes_network_policy" "oidc_from_pihole" {
  metadata {
    name      = "oidc-from-pihole"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "pihole"
          }
        }
        pod_selector {
          match_labels = {
            app = "pihole"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Cross-namespace egress: zitadel pod (pat-sync sidecar) → vault:8201.
# Mirrors services/tls-rotator-network.tf:`tls_rotator_to_vault`. The
# pat-sync sidecar reads /zitadel/bootstrap/{login-client,tf-provider}.pat
# from the bootstrap PVC and pushes them into Vault KV. Without this allow,
# the baseline's internet-egress (which excludes the cluster service CIDR)
# leaves vault.<hs>.<magic>:8201 (a ClusterIP via host_aliases) unreachable.
# History: vault-conf apply runs zitadel first without netpols, so the
# original PAT sync slipped through during that window. After services
# apply locks the ns down, any subsequent re-sync (e.g. after a postgres
# wipe + FIRSTINSTANCE re-bootstrap reissues fresh PATs) gets blocked,
# leaving Vault holding a stale PAT and the zitadel TF provider stranded
# on AUTH-7fs1e (Errors.Token.Invalid). Pod-scoped to `app = "zitadel"`
# per memory feedback_netpol_least_privilege.
resource "kubernetes_network_policy" "oidc_to_vault" {
  metadata {
    name      = "oidc-to-vault"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
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

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/pdf.tf:`pdf_to_oidc`. Stirling-PDF's Spring Security
# OAuth2 client fetches /.well-known/openid-configuration, JWKS,
# /oauth/v2/token, and /oidc/v1/userinfo during the OIDC code-exchange
# dance on every sign-in.
resource "kubernetes_network_policy" "oidc_from_pdf" {
  metadata {
    name      = "oidc-from-pdf"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "pdf"
          }
        }
        pod_selector {
          match_labels = {
            app = "pdf"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}

# Mirror of services/headlamp-network.tf:`headlamp_to_oidc`. Headlamp's
# server speaks OIDC code+PKCE against Zitadel for UI sign-in.
resource "kubernetes_network_policy" "oidc_from_headlamp" {
  metadata {
    name      = "oidc-from-headlamp"
    namespace = "oidc"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "zitadel"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "headlamp"
          }
        }
        pod_selector {
          match_labels = {
            app = "headlamp"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [module.oidc_netpol_baseline]
}
