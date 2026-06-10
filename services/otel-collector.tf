resource "kubernetes_daemonset" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
    labels    = { app = "otel-collector" }
  }

  spec {
    selector {
      match_labels = { app = "otel-collector" }
    }

    template {
      metadata {
        labels = { app = "otel-collector" }
        annotations = {
          "otel-collector-config-hash"          = sha1(kubernetes_config_map.otel_collector_config.data["config.yaml"])
          "secret.reloader.stakater.com/reload" = "otel-openobserve-auth"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.otel_collector.metadata[0].name
        host_network         = false

        image_pull_secrets {
          name = kubernetes_secret.otel_registry_pull_secret.metadata[0].name
        }

        # Root is required to read /var/log/pods/*/*/*.log on K3s (root:root
        # 0640 by default, no group that a non-root user could join). Standard
        # approach used by Fluent Bit, Vector, Promtail, etc. Keep
        # supplementalGroups=190 (systemd-journal) for defense-in-depth.
        security_context {
          run_as_user          = 0
          run_as_group         = 0
          supplemental_groups  = [190]
        }

        toleration {
          operator = "Exists"
        }

        container {
          name = "otel-collector"
          # Custom image built by the BuildKit job in this file (alpine +
          # systemd + upstream binary). Lets the journald receiver work.
          image = var.image_otel_collector != "" ? var.image_otel_collector : "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}/otel-collector:latest"
          image_pull_policy = "Always"

          args = [
            "--config=/etc/otelcol/config.yaml",
          ]

          env {
            name = "K8S_NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "OO_AUTH"
            value_from {
              secret_key_ref {
                name     = "otel-openobserve-auth"
                key      = "OO_AUTH"
                optional = true
              }
            }
          }

          port {
            container_port = 13133
            name           = "health"
          }

          volume_mount {
            name       = "otel-collector-config"
            mount_path = "/etc/otelcol"
          }
          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
          volume_mount {
            name              = "var-log-pods"
            mount_path        = "/var/log/pods"
            read_only         = true
            mount_propagation = "HostToContainer"
          }
          volume_mount {
            name              = "var-log-containers"
            mount_path        = "/var/log/containers"
            read_only         = true
            mount_propagation = "HostToContainer"
          }
          volume_mount {
            name       = "var-log-journal"
            mount_path = "/var/log/journal"
            read_only  = true
          }
          volume_mount {
            name       = "etc-machine-id"
            mount_path = "/etc/machine-id"
            read_only  = true
          }

          resources {
            # Bumped from 128Mi/256Mi: the delphi DaemonSet pod (control-plane
            # node = far more pods → the filelog receiver tracks far more
            # /var/log/pods files) climbed steadily into the 256Mi limit and
            # OOMKilled (137) on a loop; artemis idled flat at ~245Mi, i.e. right
            # at the old ceiling with no headroom. 512Mi gives the busy node room;
            # request raised to 256Mi to match real steady-state usage.
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 13133
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 13133
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "otel-collector-config"
          config_map {
            name = kubernetes_config_map.otel_collector_config.metadata[0].name
          }
        }
        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.otel_collector_secret_provider.manifest.metadata.name
            }
          }
        }
        volume {
          name = "var-log-pods"
          host_path { path = "/var/log/pods" }
        }
        volume {
          name = "var-log-containers"
          host_path { path = "/var/log/containers" }
        }
        volume {
          name = "var-log-journal"
          host_path { path = "/var/log/journal" }
        }
        volume {
          name = "etc-machine-id"
          host_path { path = "/etc/machine-id" }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.otel_collector_secret_provider,
    kubernetes_deployment.openobserve,
    kubernetes_manifest.openobserve_bootstrap_job,
  ]
}

resource "kubernetes_namespace" "otel_collector" {
  metadata {
    name = "otel-collector"
  }
}

# =============================================================================
# Service account, RBAC, registry pull secret, Vault wiring (formerly
# otel-collector-secrets.tf)
# =============================================================================

resource "kubernetes_service_account" "otel_collector" {
  metadata {
    name      = "otel-collector"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }
  automount_service_account_token = true
}

# The otel-collector DaemonSet pulls from the in-cluster registry. Registry
# creds live in Vault (written by services/registry-secrets.tf). We read them
# here and synthesize a dockerconfigjson Secret for the DaemonSet to use as
# its imagePullSecret — no cross-deployment TF state read required.
data "vault_kv_secret_v2" "registry_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "registry/config"
}

locals {
  registry_fqdn              = "${var.registry_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  registry_internal_password = jsondecode(data.vault_kv_secret_v2.registry_config.data["users"])["internal"]
}

resource "kubernetes_secret" "otel_registry_pull_secret" {
  metadata {
    name      = "registry-pull-secret"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.registry_fqdn}" = {
          username = "internal"
          password = local.registry_internal_password
          auth     = base64encode("internal:${local.registry_internal_password}")
        }
      }
    })
  }
}

# k8sattributes processor needs to read pod/namespace/node metadata
resource "kubernetes_cluster_role" "otel_collector" {
  metadata { name = "otel-collector" }

  rule {
    api_groups = [""]
    resources  = ["pods", "namespaces", "nodes", "nodes/proxy"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets", "deployments", "daemonsets", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "otel_collector" {
  metadata { name = "otel-collector" }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.otel_collector.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.otel_collector.metadata[0].name
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }
}

resource "vault_policy" "otel_collector" {
  name = "otel-collector-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/service-accounts/ingester" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "otel_collector" {
  backend                          = "kubernetes"
  role_name                        = "otel-collector"
  bound_service_account_names      = ["otel-collector"]
  bound_service_account_namespaces = ["otel-collector"]
  token_policies                   = [vault_policy.otel_collector.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "otel_collector_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-otel-collector"
      namespace = kubernetes_namespace.otel_collector.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "otel-openobserve-auth"
          type       = "Opaque"
          data = [
            { objectName = "basic_b64", key = "OO_AUTH" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "otel-collector"
        objects = yamlencode([
          {
            objectName = "basic_b64"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/openobserve/service-accounts/ingester"
            secretKey  = "basic_b64"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.otel_collector,
    vault_kubernetes_auth_backend_role.otel_collector,
    vault_kv_secret_v2.openobserve_service_account,
    vault_policy.otel_collector,
  ]
}

# =============================================================================
# Collector config (formerly otel-collector-config.tf)
# =============================================================================

resource "kubernetes_config_map" "otel_collector_config" {
  metadata {
    name      = "otel-collector-config"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }

  data = {
    "config.yaml" = templatefile("${path.module}/../data/otel/collector-config.yaml.tpl", {
      # `namespace` here is the OpenObserve namespace, not otel-collector's.
      # The template renders it into the OTLP exporter URL
      # `http://openobserve.${namespace}.svc.cluster.local:5080/...`.
      namespace       = kubernetes_namespace.openobserve.metadata[0].name
      openobserve_org = var.openobserve_org
    })
  }
}

# =============================================================================
# BuildKit image build (formerly otel-collector-jobs.tf)
#
# OpenTelemetry Collector (contrib) image with `journalctl` available.
# Consumed by the OTel DaemonSet above. Uses the shared buildkit-job module.
# =============================================================================

locals {
  otel_collector_image = "${local.thunderbolt_registry}/otel-collector:latest"
}

module "otel_collector_build" {
  source = "./../templates/buildkit-job"

  name      = "otel-collector"
  image_ref = local.otel_collector_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/otel-collector/Dockerfile")
  }

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

# =============================================================================
# NetworkPolicies for the `otel-collector` namespace (formerly
# otel-collector-network.tf)
#
# DaemonSet on the K3s node. Reads pod logs from /var/log/pods (host
# volume) and the systemd journal (host volume) — neither traverses the
# pod network. Only data-plane traffic is OTLP ingest to OpenObserve.
#
# Cross-namespace flows this file owns:
#   - egress otel-collector → openobserve (openobserve ns) :5080 (OTLP)
# =============================================================================

module "otel_collector_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.otel_collector.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  # kubelet metadata enrichment uses the in-cluster K8s API.
  allow_kube_api_egress = true
}

# Cross-ns egress: otel-collector → openobserve :5080 (OTLP/HTTP).
# Mirror ingress lives in services/monitoring-network.tf as
# openobserve-from-otel-collector.
resource "kubernetes_network_policy" "otel_collector_to_openobserve" {
  metadata {
    name      = "otel-collector-to-openobserve"
    namespace = kubernetes_namespace.otel_collector.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { app = "otel-collector" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.openobserve.metadata[0].name
          }
        }
        pod_selector {
          match_labels = { app = "openobserve" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5080"
      }
    }
  }
}
