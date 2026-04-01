resource "kubernetes_config_map" "ntfy_server_config" {
  metadata {
    name      = "ntfy-server-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
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
      "auth-users" = [
        for user, role in var.ntfy_users :
        "${user}:${bcrypt(random_password.ntfy_user_passwords[user].result)}:${role}"
      ]
      "auth-access" = [
        for user, role in var.ntfy_users :
        "${user}:*:rw" if role == "user"
      ]
    })
  }

  lifecycle {
    ignore_changes = [data]
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