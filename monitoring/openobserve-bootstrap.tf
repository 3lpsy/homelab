# Bootstrap OpenObserve service accounts.
#
# One-shot Job that runs after the OpenObserve Deployment is Ready. Using root
# credentials (mounted via CSI) it creates dedicated service accounts for
# ingestion and provisioning, capturing each generated password and writing it
# back to Vault. Collectors + the dashboards/alerts provisioner Job consume
# those Vault paths instead of the root creds.
#
# The Job needs direct Vault access to write service-account creds back. Since
# the vault namespace's NetworkPolicy only admits the vault-csi namespace on
# port 8200, the Job instead reaches Vault via a Tailscale sidecar using the
# reusable `pod_provisioner` tailnet user, hitting the external FQDN on 8201.
#
# Seed Vault KV entries are created with empty placeholders so CSI
# SecretProviderClasses can mount the paths before the bootstrap Job finishes
# its first run. Once bootstrap writes the real values, Reloader rolls the
# consumers automatically.

locals {
  openobserve_service_accounts = [
    {
      name       = "ingester"
      email      = "ingester@${var.headscale_subdomain}.${var.headscale_magic_domain}"
      first_name = "OTel"
      last_name  = "Ingester"
    },
    {
      name       = "provisioner"
      email      = "provisioner@${var.headscale_subdomain}.${var.headscale_magic_domain}"
      first_name = "Dashboards"
      last_name  = "Provisioner"
    },
  ]

  vault_tailnet_fqdn = "vault.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  vault_tailnet_url  = "https://${local.vault_tailnet_fqdn}:8201"
}

# Seed KV paths so CSI mounts can resolve them before bootstrap populates real
# values. Ignore data changes so the Job's writes aren't reverted on next apply.
resource "vault_kv_secret_v2" "openobserve_service_account" {
  for_each = { for sa in local.openobserve_service_accounts : sa.name => sa }

  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "openobserve/service-accounts/${each.key}"
  data_json = jsonencode({
    email     = each.value.email
    password  = ""
    basic_b64 = ""
  })

  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "kubernetes_service_account" "openobserve_bootstrap" {
  metadata {
    name      = "openobserve-bootstrap"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = true
}

# Pre-create state Secret + Role for the Tailscale sidecar. The sidecar
# persists its node state in this k8s Secret so the same tailnet identity
# survives pod restarts; pre-creation lets the Role drop the namespace-wide
# `create` grant.
resource "kubernetes_secret" "openobserve_bootstrap_tailscale_state" {
  metadata {
    name      = "openobserve-bootstrap-tailscale-state"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "openobserve_bootstrap_tailscale" {
  metadata {
    name      = "openobserve-bootstrap-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["openobserve-bootstrap-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "openobserve_bootstrap_tailscale" {
  metadata {
    name      = "openobserve-bootstrap-tailscale"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.openobserve_bootstrap_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.openobserve_bootstrap.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# Reusable pre-auth key under the shared pod_provisioner tailnet user. Used by
# any in-cluster Job that needs privileged outbound tailnet access (currently
# just this bootstrap, but generalized for reuse — see ACL group:vault-clients).
resource "headscale_pre_auth_key" "pod_provisioner" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.pod_provisioner_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "pod_provisioner_tailscale_auth" {
  metadata {
    name      = "pod-provisioner-tailscale-auth"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.pod_provisioner.key
  }
}

resource "vault_policy" "openobserve_bootstrap" {
  name = "openobserve-bootstrap-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/service-accounts/*" {
  capabilities = ["create", "read", "update"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "openobserve_bootstrap" {
  backend                          = "kubernetes"
  role_name                        = "openobserve-bootstrap"
  bound_service_account_names      = ["openobserve-bootstrap"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.openobserve_bootstrap.name]
  token_ttl                        = 3600
}

resource "kubernetes_manifest" "openobserve_bootstrap_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-openobserve-bootstrap"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "openobserve-bootstrap-root"
          type       = "Opaque"
          data = [
            { objectName = "basic_b64", key = "ROOT_BASIC_B64" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "openobserve-bootstrap"
        objects = yamlencode([
          {
            objectName = "basic_b64"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/config"
            secretKey  = "basic_b64"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.openobserve_bootstrap,
    vault_kv_secret_v2.openobserve_config,
    vault_policy.openobserve_bootstrap,
  ]
}

resource "kubernetes_config_map" "openobserve_bootstrap_script" {
  metadata {
    name      = "openobserve-bootstrap-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "bootstrap-accounts.py" = file("${path.module}/../data/openobserve/bootstrap-accounts.py")
  }
}

locals {
  openobserve_bootstrap_script_hash = substr(sha256(
    file("${path.module}/../data/openobserve/bootstrap-accounts.py")
  ), 0, 8)
  openobserve_bootstrap_job_name = "openobserve-bootstrap-${local.openobserve_bootstrap_script_hash}"
}

resource "kubernetes_manifest" "openobserve_bootstrap_job" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.openobserve_bootstrap_job_name
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      backoffLimit = 3
      # No ttlSecondsAfterFinished: Job name is content-keyed by sha256 of
      # bootstrap-accounts.py. Letting completed Jobs stick around means TF
      # re-applies are no-ops; cleanup happens automatically on script change
      # (new name → new Job → old one orphaned, prune by hand if it ever
      # accumulates beyond 1-2 entries).
      template = {
        metadata = {
          labels = {
            app = "openobserve-bootstrap"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.openobserve_bootstrap.metadata[0].name

          # K8s 1.29+ sidecar pattern: initContainer with restartPolicy=Always
          # runs alongside the main container for the Job's lifetime. Second
          # init-container gates the main container on tailnet DNS resolving
          # the Vault FQDN, so we never start the bootstrap script before
          # Tailscale is up.
          initContainers = [
            {
              name          = "tailscale"
              image         = var.image_tailscale
              restartPolicy = "Always"
              env = [
                { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                { name = "TS_KUBE_SECRET", value = "openobserve-bootstrap-tailscale-state" },
                { name = "TS_USERSPACE", value = "false" },
                {
                  name = "TS_AUTHKEY"
                  valueFrom = {
                    secretKeyRef = {
                      name = kubernetes_secret.pod_provisioner_tailscale_auth.metadata[0].name
                      key  = "TS_AUTHKEY"
                    }
                  }
                },
                { name = "TS_HOSTNAME", value = "openobserve-bootstrap" },
                { name = "TS_EXTRA_ARGS", value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}" },
              ]
              securityContext = {
                capabilities = {
                  add = ["NET_ADMIN"]
                }
              }
              volumeMounts = [
                { name = "dev-net-tun", mountPath = "/dev/net/tun" },
                { name = "tailscale-state", mountPath = "/var/lib/tailscale" },
              ]
            },
            {
              name    = "wait-for-tailscale"
              image   = var.image_busybox
              command = [
                "sh", "-c",
                "until nslookup ${local.vault_tailnet_fqdn}; do echo 'waiting for tailscale dns'; sleep 2; done",
              ]
            },
          ]

          containers = [
            {
              name    = "bootstrap"
              image   = var.image_python
              command = ["python3", "/scripts/bootstrap-accounts.py"]
              env = [
                { name = "VAULT_ADDR", value = local.vault_tailnet_url },
                { name = "VAULT_ROLE", value = "openobserve-bootstrap" },
                { name = "VAULT_MOUNT", value = data.terraform_remote_state.vault_conf.outputs.kv_mount_path },
                { name = "OO_URL", value = "http://openobserve.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:5080" },
                { name = "OO_ORG", value = var.openobserve_org },
                {
                  name = "ROOT_BASIC_B64"
                  valueFrom = {
                    secretKeyRef = {
                      name = "openobserve-bootstrap-root"
                      key  = "ROOT_BASIC_B64"
                    }
                  }
                },
                { name = "ACCOUNTS_JSON", value = jsonencode(local.openobserve_service_accounts) },
              ]
              volumeMounts = [
                { name = "script", mountPath = "/scripts", readOnly = true },
                { name = "secrets-store", mountPath = "/mnt/secrets", readOnly = true },
              ]
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { cpu = "500m", memory = "256Mi" }
              }
            },
          ]

          volumes = [
            {
              name = "script"
              configMap = {
                name        = kubernetes_config_map.openobserve_bootstrap_script.metadata[0].name
                defaultMode = 493 # 0755
              }
            },
            {
              name = "secrets-store"
              csi = {
                driver   = "secrets-store.csi.k8s.io"
                readOnly = true
                volumeAttributes = {
                  secretProviderClass = "vault-openobserve-bootstrap"
                }
              }
            },
            {
              name = "dev-net-tun"
              hostPath = {
                path = "/dev/net/tun"
                type = "CharDevice"
              }
            },
            {
              name     = "tailscale-state"
              emptyDir = {}
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.template.metadata.labels",
    "spec.selector",
  ]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_deployment.openobserve,
    kubernetes_manifest.openobserve_bootstrap_secret_provider,
    kubernetes_config_map.openobserve_bootstrap_script,
    kubernetes_role_binding.openobserve_bootstrap_tailscale,
    kubernetes_secret.pod_provisioner_tailscale_auth,
    vault_kv_secret_v2.openobserve_service_account,
  ]
}
