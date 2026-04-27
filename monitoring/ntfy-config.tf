resource "kubernetes_config_map" "ntfy_server_config" {
  metadata {
    name      = "ntfy-server-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  # auth-users / auth-access are NOT rendered here. They previously embedded
  # bcrypt hashes + the full user/role enumeration, which would land in
  # plaintext in Velero backup tarballs. Users are now seeded into the
  # SQLite auth-file (on PVC) by the seed-users init container at startup,
  # using passwords mounted via Vault CSI.
  data = {
    "server.yml" = yamlencode({
      "base-url"            = "https://${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
      "listen-http"         = ":8080"
      "cache-file"          = "/var/cache/ntfy/cache.db"
      "cache-duration"      = "24h"
      "auth-file"           = "/var/lib/ntfy/user.db"
      "auth-default-access" = "deny-all"
      "behind-proxy"        = true
      "upstream-base-url"   = "https://ntfy.sh"
      "enable-signup"       = false
      "enable-login"        = true
      "log-level"           = "info"
      "log-format"          = "json"
    })
  }
}

resource "kubernetes_config_map" "ntfy_seed_script" {
  metadata {
    name      = "ntfy-seed-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "seed-users.sh" = templatefile("${path.module}/../data/ntfy/seed-users.sh.tpl", {
      users = var.ntfy_users
    })
  }
}

resource "kubernetes_config_map" "ntfy_nginx_config" {
  metadata {
    name      = "ntfy-nginx-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/ntfy.nginx.conf.tpl", {
      server_domain = "${var.ntfy_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}