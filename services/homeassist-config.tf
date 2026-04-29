resource "kubernetes_config_map" "homeassist_config" {
  metadata {
    name      = "homeassist-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # Seed configuration.yaml. The seed-config init container copies this
    # to /config/configuration.yaml on first boot only — subsequent edits
    # via the HA UI / file editor live on the PVC and are not overwritten.
    "configuration.yaml" = <<-EOT
      default_config:

      homeassistant:
        time_zone: ${var.homeassist_time_zone}

      http:
        use_x_forwarded_for: true
        trusted_proxies:
          - 127.0.0.1
          - ::1

      logger:
        default: info

      automation: !include automations.yaml
      script: !include scripts.yaml
      scene: !include scenes.yaml
    EOT
  }
}

resource "kubernetes_config_map" "homeassist_nginx_config" {
  metadata {
    name      = "homeassist-nginx-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/homeassist.nginx.conf.tpl", {
      server_domain = "${var.homeassist_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
