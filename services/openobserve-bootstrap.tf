# Bootstrap OpenObserve service accounts.
#
# One-shot Job that runs after the OpenObserve Deployment is Ready. Using root
# credentials (mounted via CSI) it creates dedicated service accounts for
# ingestion and provisioning, capturing each generated password and writing it
# back to Vault. Collectors + the dashboards/alerts provisioner Job consume
# those Vault paths instead of the root creds.
#
# The Job needs direct Vault access to write service-account creds back.
# Vault's NetworkPolicy only admits the vault-csi namespace on 8200, so
# writes go to vault's TLS listener on 8201 via the cluster network. The
# Job pod uses host_aliases to pin `vault.<hs>.<magic>` to the vault
# Service ClusterIP (sourced from the vault deployment's remote-state
# output) so SNI carries the FQDN and the existing TLS cert validates
# without going through a Tailscale sidecar.
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
    # Was vault_kv_secret_v2.openobserve_config (now lives inside the
    # openobserve_tls_vault module). Depend on the whole module so the
    # config write completes before this SPC reads from the same path.
    module.openobserve_tls_vault,
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
  # Sentinel mixed into the Job name hash so that pod-template changes
  # which don't touch bootstrap-accounts.py still produce a fresh Job
  # name. Job spec.template is immutable in K8s, so reusing the same
  # name on a template change errors with "field is immutable".
  openobserve_bootstrap_pod_spec_sentinel = "host-aliases=v1,no-tailscale"
  openobserve_bootstrap_script_hash = substr(sha256(join("\n", [
    file("${path.module}/../data/openobserve/bootstrap-accounts.py"),
    local.openobserve_bootstrap_pod_spec_sentinel,
  ])), 0, 8)
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

          hostAliases = [
            {
              ip        = data.terraform_remote_state.vault.outputs.vault_cluster_ip
              hostnames = [local.vault_tailnet_fqdn]
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
    vault_kv_secret_v2.openobserve_service_account,
  ]
}
