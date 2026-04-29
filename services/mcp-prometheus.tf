module "mcp_prometheus_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-prometheus"
  image_ref = local.mcp_prometheus_image

  context_files = {
    "Dockerfile" = file("${path.module}/../data/images/mcp-prometheus/Dockerfile")
    "server.py"  = file("${path.module}/../data/images/mcp-prometheus/server.py")
  }
  context_dirs = local.mcp_common_files

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_prometheus" {
  source = "../templates/mcp-server"

  name                         = "mcp-prometheus"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_prometheus_image
  build_job_name               = module.mcp_prometheus_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_prometheus_log_level
  image_busybox                = var.image_busybox

  extra_env = [
    { name = "PROMETHEUS_URL", value = var.mcp_prometheus_url },
  ]
}

# Cross-namespace egress for mcp-prometheus → Prometheus in monitoring ns.
#
# mcp-prometheus is configured via `var.mcp_prometheus_url` to reach
# `http://prometheus.monitoring.svc.cluster.local:9090` directly (in-cluster
# DNS, no Tailscale hop). This allow is load-bearing today, not deferred.

resource "kubernetes_network_policy" "mcp_prometheus_to_monitoring" {
  metadata {
    name      = "mcp-prometheus-to-monitoring"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "mcp-prometheus"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9090"
      }
    }
  }
}
