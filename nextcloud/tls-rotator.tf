# tls-rotator CronJob: daily renewal of every entry in local.rotated_certs.
#
# Rotation flow per run:
#   1. Vault login via this pod's SA token.
#   2. Read tls-rotator/aws (long-lived IAM key) and tls-rotator/acme-account
#      (account_key_pem + email) from Vault.
#   3. AssumeRole into the route53-scoped IAM role -> temporary STS creds.
#   4. For each cert: read current PEM from Vault. If >RENEW_THRESHOLD_DAYS
#      remain, skip. Else stage to lego dir and `lego renew`. Write new PEM
#      back to Vault. Reloader (monitoring deployment) sees the synced K8s
#      secret change and rolls the consuming Deployment.
#
# Vault writes go over Tailscale to vault's external FQDN on 8201 because
# Vault's NetworkPolicy only admits the vault-csi namespace on 8200.
#
# CronJob fires daily on `var.tls_rotator_schedule`. Trigger an out-of-band
# run with `kubectl create job --from=cronjob/tls-rotator -n tls-rotator <name>`.

locals {
  # Single source of truth: the 16 service certs the worker rotates.
  # Adding a service = add one entry here AND add `ignore_changes = [data_json]`
  # to the existing vault_kv_secret_v2.<svc>_tls resource.
  # `vault_path` matches the `name` of the existing vault_kv_secret_v2.<svc>_tls
  # resource exactly — those are the live KV paths the workloads consume.
  rotated_certs = [
    # nextcloud deployment certs
    { name = "nextcloud", domain = "${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "nextcloud/tls" },
    { name = "collabora", domain = "${var.collabora_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "nextcloud/collabora-tls" },
    { name = "immich", domain = "${var.immich_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "nextcloud/immich-tls" },
    { name = "registry", domain = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "registry/tls" },
    { name = "radicale", domain = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "radicale/tls" },
    { name = "frigate", domain = "${var.frigate_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "frigate/tls" },
    { name = "thunderbolt", domain = local.thunderbolt_fqdn, vault_path = "thunderbolt/tls" },
    { name = "mcp-shared", domain = local.mcp_shared_fqdn, vault_path = "mcp/mcp-shared/tls" },
    { name = "homeassist", domain = "${var.homeassist_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "homeassist/tls" },
    { name = "homeassist-z2m", domain = "${var.homeassist_z2m_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "homeassist/z2m/tls" },
    { name = "pihole", domain = "${var.pihole_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "pihole/tls" },
    { name = "searxng", domain = "${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "searxng/tls" },
    { name = "litellm", domain = "${var.litellm_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "litellm/tls" },
    # monitoring deployment certs (vault paths exist post-monitoring-apply)
    { name = "grafana", domain = "${var.grafana_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "grafana/tls" },
    { name = "ntfy", domain = "${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "ntfy/tls" },
    { name = "openobserve", domain = "${var.openobserve_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}", vault_path = "openobserve/tls" },
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

              # Sidecar pattern (K8s 1.29+): tailscale runs alongside the
              # main container for the Job's lifetime; wait-for-tailscale
              # gates the rotator on tailnet DNS resolving the Vault FQDN.
              initContainers = [
                {
                  name          = "tailscale"
                  image         = var.image_tailscale
                  restartPolicy = "Always"
                  env = [
                    { name = "TS_STATE_DIR", value = "/var/lib/tailscale" },
                    { name = "TS_KUBE_SECRET", value = "tls-rotator-tailscale-state" },
                    { name = "TS_USERSPACE", value = "false" },
                    {
                      name = "TS_AUTHKEY"
                      valueFrom = {
                        secretKeyRef = {
                          name = kubernetes_secret.tls_rotator_tailscale_auth.metadata[0].name
                          key  = "TS_AUTHKEY"
                        }
                      }
                    },
                    { name = "TS_HOSTNAME", value = "tls-rotator" },
                    { name = "TS_EXTRA_ARGS", value = "--login-server=https://${data.terraform_remote_state.homelab.outputs.headscale_server_fqdn}" },
                  ]
                  securityContext = {
                    capabilities = { add = ["NET_ADMIN"] }
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
                    "until nslookup vault.${var.headscale_subdomain}.${var.headscale_magic_domain}; do echo 'waiting for tailscale dns'; sleep 2; done",
                  ]
                },
              ]

              containers = [
                {
                  name              = "rotate"
                  image             = local.tls_rotator_image
                  imagePullPolicy   = "Always"
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
                {
                  name = "dev-net-tun"
                  hostPath = {
                    path = "/dev/net/tun"
                    type = "CharDevice"
                  }
                },
                { name = "tailscale-state", emptyDir = {} },
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
    kubernetes_role_binding.tls_rotator_tailscale,
    kubernetes_secret.tls_rotator_tailscale_auth,
    kubernetes_secret.tls_rotator_registry_pull_secret,
    kubernetes_config_map.tls_rotator_certs,
    vault_kubernetes_auth_backend_role.tls_rotator,
    vault_kv_secret_v2.tls_rotator_aws,
    vault_kv_secret_v2.tls_rotator_acme_account,
    kubernetes_manifest.tls_rotator_build,
  ]
}
