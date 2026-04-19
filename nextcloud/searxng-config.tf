locals {
  searxng_fqdn = "${var.searxng_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
}

resource "kubernetes_config_map" "searxng_config" {
  metadata {
    name      = "searxng-config"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }

  # Seeded by Terraform, mutated continuously by searxng-ranker (reorders
  # outgoing.proxies and adds per-engine proxies based on live probe data).
  # Without this, every `terraform plan` would show drift as TF tried to
  # revert the ranker's writes.
  lifecycle {
    ignore_changes = [data]
  }

  data = {
    "settings.yml" = templatefile("${path.module}/../data/searxng/settings.yml.tpl", {
      searxng_fqdn  = local.searxng_fqdn
      exitnode_keys = sort(keys(local.exitnode_names))
    })
  }
}

resource "kubernetes_config_map" "searxng_nginx_config" {
  metadata {
    name      = "searxng-nginx-config"
    namespace = kubernetes_namespace.searxng.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/searxng.nginx.conf.tpl", {
      server_domain = local.searxng_fqdn
    })
  }
}
