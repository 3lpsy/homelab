module "mcp_searxng_build" {
  source = "./../templates/buildkit-job"

  name      = "mcp-searxng"
  image_ref = local.mcp_searxng_image

  context_files = {}
  context_dirs  = local.mcp_rs_files
  build_args    = { BIN = "mcp-searxng", CRATES_REGISTRY = local.mcp_rs_crates_registry }
  cache_ref     = local.mcp_rs_cache_ref

  shared = local.buildkit_job_shared

  depends_on = [
    kubernetes_secret.builder_registry_pull_secret,
    kubernetes_config_map.builder_buildkitd_config,
  ]
}

module "mcp_searxng" {
  source = "../templates/mcp-server"

  name                         = "mcp-searxng"
  namespace                    = kubernetes_namespace.mcp.metadata[0].name
  image                        = local.mcp_searxng_image
  build_job_name               = module.mcp_searxng_build.job_name
  service_account_name         = kubernetes_service_account.mcp.metadata[0].name
  image_pull_secret_name       = kubernetes_secret.mcp_registry_pull_secret.metadata[0].name
  shared_secret_provider_class = kubernetes_manifest.mcp_shared_secret_provider.manifest.metadata.name
  log_level                    = var.mcp_searxng_log_level
  image_busybox                = var.image_busybox

  # Pin searxng.<hs>.<magic> to the searxng Service ClusterIP so the
  # backend can dial the FQDN (MCP_SEARXNG_URL) and keep using the
  # FQDN-valid TLS cert nginx serves at :443 — no tailnet round-trip.
  host_aliases = [
    {
      ip        = kubernetes_service.searxng.spec[0].cluster_ip
      hostnames = ["${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
    },
  ]

  extra_env = [
    {
      name  = "MCP_SEARXNG_URL"
      value = "https://${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    },
  ]
}

# Cross-ns egress: mcp-searxng → searxng:443. The mcp ns netpol-baseline
# default-denies cluster-internal egress (allow_internet_egress excludes
# pod+service CIDRs), so without this rule the host_aliases-pinned hop
# to the searxng ClusterIP is blocked. Mirror ingress is
# `searxng_from_mcp_searxng` in services/searxng.tf.
resource "kubernetes_network_policy" "mcp_searxng_to_searxng" {
  metadata {
    name      = "mcp-searxng-to-searxng"
    namespace = kubernetes_namespace.mcp.metadata[0].name
  }
  spec {
    pod_selector { match_labels = { app = "mcp-searxng" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.searxng.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "searxng" } }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
