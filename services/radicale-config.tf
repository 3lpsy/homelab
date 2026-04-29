resource "kubernetes_config_map" "radicale_config" {
  metadata {
    name      = "radicale-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "config" = <<-EOT
      [server]
      hosts = 0.0.0.0:5232
      max_connections = 5
      max_content_length = 100000000
      timeout = 30

      [auth]
      type = http_x_remote_user
      htpasswd_filename = /etc/radicale/users
      htpasswd_encryption = md5
      delay = 1

      [storage]
      filesystem_folder = /var/lib/radicale/collections

      [rights]
      type = from_file
      file = /etc/radicale/rights

      [logging]
      level = warning

      [web]
      type = none
    EOT

    "rights" = <<-EOT
      [root]
      user: .+
      collection:
      permissions: R

      [principal]
      user: .+
      collection: {user}
      permissions: RW

      [calendars]
      user: .+
      collection: {user}/[^/]+
      permissions: rw
    EOT
  }
}

resource "kubernetes_config_map" "radicale_nginx_config" {
  metadata {
    name      = "radicale-nginx-config"
    namespace = kubernetes_namespace.radicale.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/radicale.nginx.conf.tpl", {
      server_domain = "${var.radicale_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
