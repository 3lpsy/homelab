# tls-rotator CronJob: daily renewal of every entry in local.rotated_certs.
#
# Rotation flow per run:
#   1. Vault login via this pod's SA token.
#   2. Read tls-rotator/aws (long-lived IAM key) and tls-rotator/acme-account
#      (account_key_pem + email) from Vault.
#   3. AssumeRole into the route53-scoped IAM role -> temporary STS creds.
#   4. For each cert: read current PEM from Vault. If >RENEW_THRESHOLD_DAYS
#      remain, skip. Else stage to lego dir and `lego renew`. Write new PEM
#      back to Vault. Reloader (in the `monitoring` namespace, also part of
#      this services deployment) sees the synced K8s secret change and rolls
#      the consuming Deployment.
#
# Vault writes go to vault's TLS listener on 8201 — Vault's NetworkPolicy
# only admits the vault-csi namespace on 8200. The Job pod uses
# host_aliases to pin `vault.<hs>.<magic>` to the vault Service ClusterIP
# (vault deployment exposes it as `vault_cluster_ip` via remote-state) so
# SNI carries the FQDN and the existing TLS cert validates without going
# through a Tailscale sidecar.
#
# CronJob fires daily on `var.tls_rotator_schedule`. Trigger an out-of-band
# run with `kubectl create job --from=cronjob/tls-rotator -n tls-rotator <name>`.

locals {
  # Single source of truth: the 20 service certs the worker rotates.
  # Adding a service = add one entry here AND add `ignore_changes = [data_json]`
  # to the existing vault_kv_secret_v2.<svc>_tls resource.
  # `vault_path` matches the `name` of the existing vault_kv_secret_v2.<svc>_tls
  # resource exactly — those are the live KV paths the workloads consume.
  rotated_certs = [
    # User-facing service certs (`nextcloud`, `mcp`, `searxng`, `litellm`,
    # `thunderbolt`, etc. namespaces).
    { name = "podcasts", domain = "${var.git_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "podcasts/tls" },
    { name = "git", domain = "${var.git_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "git/tls" },
    { name = "nextcloud", domain = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "nextcloud/tls" },
    { name = "collabora", domain = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "collabora/tls" },
    { name = "immich", domain = "${var.immich_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "immich/tls" },
    { name = "registry", domain = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "registry/tls" },
    { name = "radicale", domain = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "radicale/tls" },
    { name = "navidrome", domain = "${var.navidrome_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "navidrome/tls" },
    { name = "jellyfin", domain = "${var.jellyfin_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "jellyfin/tls" },
    { name = "registry-dockerio", domain = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "registry-dockerio/tls" },
    { name = "registry-ghcrio", domain = "${var.registry_ghcrio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "registry-ghcrio/tls" },
    { name = "exitnode-haproxy", domain = "${var.exitnode_haproxy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "exitnode-haproxy/tls" },
    { name = "frigate", domain = "${var.frigate_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "frigate/tls" },
    { name = "thunderbolt", domain = local.thunderbolt_fqdn, vault_path = "thunderbolt/tls" },
    { name = "mcp-shared", domain = local.mcp_shared_fqdn, vault_path = "mcp/mcp-shared/tls" },
    { name = "homeassist", domain = "${var.homeassist_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "homeassist/tls" },
    { name = "homeassist-z2m", domain = "${var.homeassist_z2m_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "homeassist/z2m/tls" },
    { name = "pihole", domain = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "pihole/tls" },
    { name = "searxng", domain = "${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "searxng/tls" },
    { name = "litellm", domain = "${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "litellm/tls" },
    { name = "opencode", domain = "${var.opencode_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "opencode/tls" },
    # Zitadel lives in the vault-conf deployment (oidc namespace) — domain
    # comes from vault-conf outputs to keep it in lockstep with the pod's
    # ZITADEL_EXTERNALDOMAIN. vault_path matches what service-tls-vault
    # writes from vault-conf.
    { name = "zitadel", domain = "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "zitadel/tls" },
    # Monitoring-namespace service certs.
    { name = "grafana", domain = "${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "grafana/tls" },
    { name = "headlamp", domain = "${var.headlamp_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "headlamp/tls" },
    { name = "ntfy", domain = "${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "ntfy/tls" },
    { name = "openobserve", domain = "${var.openobserve_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "openobserve/tls" },
    { name = "prometheus", domain = "${var.prometheus_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "prometheus/tls" },
  ]

  vault_tailnet_url_for_rotator = "https://vault.${var.headscale_subdomain}.${var.headscale_magic_domain}:8201"
}

resource "kubernetes_config_map" "tls_rotator_certs" {
  metadata {
    name      = "tls-rotator-certs"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
  }

  data = {
    "certs.json" = jsonencode(local.rotated_certs)
  }
}

resource "kubernetes_manifest" "tls_rotator_cronjob" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "CronJob"
    metadata = {
      name      = "tls-rotator"
      namespace = kubernetes_namespace.tls_rotator.metadata[0].name
      labels    = { app = "tls-rotator" }
    }
    spec = {
      schedule                   = var.tls_rotator_schedule
      timeZone                   = "America/Chicago"
      suspend                    = false
      concurrencyPolicy          = "Forbid"
      successfulJobsHistoryLimit = 1
      failedJobsHistoryLimit     = 3
      startingDeadlineSeconds    = 600

      jobTemplate = {
        spec = {
          backoffLimit            = 1
          ttlSecondsAfterFinished = 86400
          template = {
            metadata = {
              labels = { app = "tls-rotator" }
              annotations = {
                # Roll the CronJob's pod template when the cert manifest
                # changes so Job specs pick up the new ConfigMap content.
                "certs-hash" = sha1(kubernetes_config_map.tls_rotator_certs.data["certs.json"])
              }
            }
            spec = {
              restartPolicy      = "Never"
              serviceAccountName = kubernetes_service_account.tls_rotator.metadata[0].name

              imagePullSecrets = [
                { name = kubernetes_secret.tls_rotator_registry_pull_secret.metadata[0].name },
              ]

              hostAliases = [
                {
                  ip        = data.terraform_remote_state.vault.outputs.vault_cluster_ip
                  hostnames = ["vault.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
                },
              ]

              # Block until vault is TCP-reachable. Sidesteps the kube-router
              # netpol-ipset registration race — see data/scripts/wait-for-vault.sh.tpl.
              initContainers = [
                {
                  name  = "wait-for-vault"
                  image = var.image_busybox
                  command = [
                    "sh", "-c",
                    templatefile("${path.module}/../data/scripts/wait-for-vault.sh.tpl", {
                      vault_host = "vault.${var.headscale_subdomain}.${var.headscale_magic_domain}"
                      vault_port = "8201"
                    })
                  ]
                  resources = {
                    requests = { cpu = "10m", memory = "16Mi" }
                    limits   = { cpu = "100m", memory = "32Mi" }
                  }
                },
              ]

              containers = [
                {
                  name            = "rotate"
                  image           = local.tls_rotator_image
                  imagePullPolicy = "Always"
                  env = [
                    { name = "VAULT_ADDR", value = local.vault_tailnet_url_for_rotator },
                    { name = "VAULT_ROLE", value = vault_kubernetes_auth_backend_role.tls_rotator.role_name },
                    { name = "VAULT_MOUNT", value = data.terraform_remote_state.vault_conf.outputs.kv_mount_path },
                    { name = "ACME_SERVER", value = var.acme_server_url },
                    { name = "RENEW_THRESHOLD_DAYS", value = tostring(var.tls_rotator_renew_threshold_days) },
                    { name = "CERTS_FILE", value = "/etc/tls-rotator/certs.json" },
                    { name = "RECURSIVE_NAMESERVERS", value = join(",", [for ns in var.recursive_nameservers : "${ns}:53"]) },
                  ]
                  volumeMounts = [
                    { name = "certs", mountPath = "/etc/tls-rotator", readOnly = true },
                    { name = "work", mountPath = "/work" },
                  ]
                  resources = {
                    requests = { cpu = "50m", memory = "128Mi" }
                    limits   = { cpu = "1", memory = "512Mi" }
                  }
                  securityContext = {
                    runAsNonRoot             = true
                    runAsUser                = 1000
                    runAsGroup               = 1000
                    allowPrivilegeEscalation = false
                    capabilities             = { drop = ["ALL"] }
                  }
                },
              ]

              volumes = [
                {
                  name = "certs"
                  configMap = {
                    name = kubernetes_config_map.tls_rotator_certs.metadata[0].name
                  }
                },
                { name = "work", emptyDir = {} },
              ]
            }
          }
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.jobTemplate.metadata",
    "spec.jobTemplate.spec.template.metadata.labels",
    "spec.jobTemplate.spec.template.spec.containers[0].terminationMessagePath",
    "spec.jobTemplate.spec.template.spec.containers[0].terminationMessagePolicy",
  ]

  depends_on = [
    kubernetes_namespace.tls_rotator,
    kubernetes_secret.tls_rotator_registry_pull_secret,
    kubernetes_config_map.tls_rotator_certs,
    vault_kubernetes_auth_backend_role.tls_rotator,
    vault_kv_secret_v2.tls_rotator_aws,
    vault_kv_secret_v2.tls_rotator_acme_account,
    module.tls_rotator_build,
  ]
}

# =============================================================================
# Namespace, ServiceAccount, RBAC, Vault wiring (formerly tls-rotator-secrets.tf)
#
# The worker runs in its own namespace so its Vault policy (which can write to
# every per-service `<svc>/tls` path) is isolated from the consuming workloads.
#
# The worker writes rotated certs back to Vault. Vault's NetworkPolicy only
# admits the vault-csi namespace on 8200, so writes go to vault's TLS
# listener on 8201 via the cluster network. The Job pod uses host_aliases
# to pin `vault.<hs>.<magic>` to the vault Service ClusterIP so SNI + cert
# validation continue to work; cross-ns ingress is permitted by
# vault_cross_ns in vault/vault-network.tf.
# =============================================================================

resource "kubernetes_namespace" "tls_rotator" {
  metadata {
    name = "tls-rotator"
  }
}

resource "kubernetes_service_account" "tls_rotator" {
  metadata {
    name      = "tls-rotator"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
  }
  automount_service_account_token = true
}

# Pull secret so the worker pod can fetch its image from the in-cluster
# registry (which lives on the tailnet via the registry namespace).
resource "kubernetes_secret" "tls_rotator_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
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

# ACME account material for the worker. Reuses the existing account from the
# homelab module so we share rate-limit accounting with TF-issued certs.
resource "vault_kv_secret_v2" "tls_rotator_acme_account" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "tls-rotator/acme-account"
  data_json = jsonencode({
    email           = data.terraform_remote_state.homelab.outputs.acme_registration_email
    account_key_pem = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  })
}

# Vault policy: read its own creds + read/create/update on every per-service
# tls path the worker rotates. Paths come from local.rotated_certs in this
# file so the policy and the worker's manifest stay in sync.
resource "vault_policy" "tls_rotator" {
  name = "tls-rotator-policy"

  policy = join("\n", concat(
    [
      <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/tls-rotator/aws" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/tls-rotator/acme-account" {
  capabilities = ["read"]
}
EOT
    ],
    [
      for c in local.rotated_certs :
      <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/${c.vault_path}" {
  capabilities = ["read", "create", "update"]
}
EOT
    ]
  ))
}

resource "vault_kubernetes_auth_backend_role" "tls_rotator" {
  backend                          = "kubernetes"
  role_name                        = "tls-rotator"
  bound_service_account_names      = [kubernetes_service_account.tls_rotator.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_namespace.tls_rotator.metadata[0].name]
  token_policies                   = [vault_policy.tls_rotator.name]
  token_ttl                        = 3600
}

# =============================================================================
# BuildKit image build (formerly tls-rotator-jobs.tf)
#
# Context covers Dockerfile + rotate.py so a change to either triggers a
# rebuild via the shared buildkit-job module's content hash.
# =============================================================================

locals {
  tls_rotator_image = "${local.thunderbolt_registry}/tls-rotator:latest"
}

module "tls_rotator_build" {
  source = "./../templates/buildkit-job"

  name      = "tls-rotator"
  image_ref = local.tls_rotator_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/tls-rotator/Dockerfile")
    "rotate.py"  = file("${path.module}/../data/images/tls-rotator/rotate.py")
  }

  build_args = {
    UV_EXCLUDE_NEWER = var.pip_proxy_cooldown_value
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

# =============================================================================
# NetworkPolicies for the `tls-rotator` namespace (formerly tls-rotator-network.tf)
#
# CronJob runs daily, renewing certs via lego (DNS-01 against Route53)
# and writing back to Vault on :8201 via the cluster network — pod uses
# host_aliases pinning `vault.<hs>.<magic>` to the vault Service
# ClusterIP. The cross-ns egress allow below is load-bearing.
#
# Internet egress is required for DNS-01 (TCP 443 to AWS APIs) and
# in-cluster ACME validation traffic — covered by the baseline's
# internet egress.
# =============================================================================

module "tls_rotator_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.tls_rotator.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}

# Cross-namespace egress: tls-rotator → vault:8201 (cert writes).
resource "kubernetes_network_policy" "tls_rotator_to_vault" {
  metadata {
    name      = "tls-rotator-to-vault"
    namespace = kubernetes_namespace.tls_rotator.metadata[0].name
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
