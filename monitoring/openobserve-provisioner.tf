# One-shot Job that provisions OpenObserve dashboards, alerts, alert
# destinations/templates from JSON artifacts under data/openobserve/.
# Idempotent — re-runs on each artifact change.
#
# Saved views are intentionally NOT provisioned here: OO's savedview POST
# body is an opaque base64-encoded blob produced by the UI, not a shape we
# can safely hand-author. Use the OpenObserve UI to save searches.

locals {
  oo_provisioner_dashboard_files = fileset("${path.module}/../data/openobserve/dashboards", "*.json")
  oo_provisioner_alert_files     = fileset("${path.module}/../data/openobserve/alerts", "*.json")
  oo_provisioner_template_files  = fileset("${path.module}/../data/openobserve/alerts/templates", "*.json")

  oo_ntfy_internal_url = "http://ntfy.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:8080/${var.ntfy_alert_topic}"
  # try() so this local evaluates during import/plan runs before the
  # ntfy_user_passwords["openobserve"] instance has been created.
  oo_ntfy_basic_b64 = try(
    base64encode("openobserve:${random_password.ntfy_user_passwords["openobserve"].result}"),
    ""
  )

  oo_provisioner_destinations = {
    "ntfy.json" = templatefile("${path.module}/../data/openobserve/alerts/destinations/ntfy.json.tpl", {
      ntfy_url        = local.oo_ntfy_internal_url
      ntfy_basic_b64  = local.oo_ntfy_basic_b64
      ntfy_priority   = "default"
    })
  }

  oo_provisioner_input_hash = substr(sha256(join("", concat(
    [file("${path.module}/../data/openobserve/provisioner.py")],
    [for f in local.oo_provisioner_dashboard_files : file("${path.module}/../data/openobserve/dashboards/${f}")],
    [for f in local.oo_provisioner_alert_files : file("${path.module}/../data/openobserve/alerts/${f}")],
    [for f in local.oo_provisioner_template_files : file("${path.module}/../data/openobserve/alerts/templates/${f}")],
    values(local.oo_provisioner_destinations),
  ))), 0, 8)
  oo_provisioner_job_name = "openobserve-provisioner-${local.oo_provisioner_input_hash}"
}

resource "kubernetes_config_map" "openobserve_provisioner_script" {
  metadata {
    name      = "openobserve-provisioner-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "provisioner.py" = file("${path.module}/../data/openobserve/provisioner.py")
  }
}

resource "kubernetes_config_map" "openobserve_provisioner_dashboards" {
  metadata {
    name      = "openobserve-provisioner-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    for f in local.oo_provisioner_dashboard_files :
    f => file("${path.module}/../data/openobserve/dashboards/${f}")
  }
}

resource "kubernetes_config_map" "openobserve_provisioner_alerts" {
  metadata {
    name      = "openobserve-provisioner-alerts"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    for f in local.oo_provisioner_alert_files :
    f => file("${path.module}/../data/openobserve/alerts/${f}")
  }
}

resource "kubernetes_config_map" "openobserve_provisioner_templates" {
  metadata {
    name      = "openobserve-provisioner-templates"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    for f in local.oo_provisioner_template_files :
    f => file("${path.module}/../data/openobserve/alerts/templates/${f}")
  }
}

resource "kubernetes_config_map" "openobserve_provisioner_destinations" {
  metadata {
    name      = "openobserve-provisioner-destinations"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = local.oo_provisioner_destinations
}

resource "kubernetes_service_account" "openobserve_provisioner" {
  metadata {
    name      = "openobserve-provisioner"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  automount_service_account_token = true
}

resource "vault_policy" "openobserve_provisioner" {
  name = "openobserve-provisioner-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/service-accounts/provisioner" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "openobserve_provisioner" {
  backend                          = "kubernetes"
  role_name                        = "openobserve-provisioner"
  bound_service_account_names      = ["openobserve-provisioner"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.openobserve_provisioner.name]
  token_ttl                        = 3600
}

resource "kubernetes_manifest" "openobserve_provisioner_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-openobserve-provisioner"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "openobserve-provisioner-auth"
          type       = "Opaque"
          data = [
            { objectName = "basic_b64", key = "OO_AUTH" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "openobserve-provisioner"
        objects = yamlencode([
          {
            objectName = "basic_b64"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/service-accounts/provisioner"
            secretKey  = "basic_b64"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    vault_kubernetes_auth_backend_role.openobserve_provisioner,
    vault_kv_secret_v2.openobserve_service_account,
    vault_policy.openobserve_provisioner,
  ]
}

resource "kubernetes_manifest" "openobserve_provisioner_job" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.oo_provisioner_job_name
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      backoffLimit            = 3
      ttlSecondsAfterFinished = 3600
      template = {
        metadata = {
          labels = {
            app = "openobserve-provisioner"
          }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.openobserve_provisioner.metadata[0].name

          containers = [
            {
              name    = "provisioner"
              image   = var.image_python
              command = ["python3", "/scripts/provisioner.py"]
              env = [
                { name = "OO_URL", value = "http://openobserve.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:5080" },
                { name = "OO_ORG", value = var.openobserve_org },
                { name = "CONFIG_DIR", value = "/config" },
                {
                  name = "OO_AUTH"
                  valueFrom = {
                    secretKeyRef = {
                      name = "openobserve-provisioner-auth"
                      key  = "OO_AUTH"
                    }
                  }
                },
              ]
              volumeMounts = [
                { name = "script", mountPath = "/scripts", readOnly = true },
                { name = "dashboards", mountPath = "/config/dashboards", readOnly = true },
                { name = "alerts", mountPath = "/config/alerts", readOnly = true },
                { name = "templates", mountPath = "/config/templates", readOnly = true },
                { name = "destinations", mountPath = "/config/destinations", readOnly = true },
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
                name        = kubernetes_config_map.openobserve_provisioner_script.metadata[0].name
                defaultMode = 493 # 0755
              }
            },
            { name = "dashboards", configMap = { name = kubernetes_config_map.openobserve_provisioner_dashboards.metadata[0].name } },
            { name = "alerts", configMap = { name = kubernetes_config_map.openobserve_provisioner_alerts.metadata[0].name } },
            { name = "templates", configMap = { name = kubernetes_config_map.openobserve_provisioner_templates.metadata[0].name } },
            { name = "destinations", configMap = { name = kubernetes_config_map.openobserve_provisioner_destinations.metadata[0].name } },
            {
              name = "secrets-store"
              csi = {
                driver   = "secrets-store.csi.k8s.io"
                readOnly = true
                volumeAttributes = {
                  secretProviderClass = "vault-openobserve-provisioner"
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
    kubernetes_manifest.openobserve_bootstrap_job,
    kubernetes_manifest.openobserve_provisioner_secret_provider,
    kubernetes_config_map.openobserve_provisioner_script,
    kubernetes_config_map.openobserve_provisioner_dashboards,
    kubernetes_config_map.openobserve_provisioner_alerts,
    kubernetes_config_map.openobserve_provisioner_templates,
    kubernetes_config_map.openobserve_provisioner_destinations,
  ]
}
