resource "kubernetes_config_map" "homeassist_z2m_config" {
  metadata {
    name      = "homeassist-z2m-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # First-boot seed; user-owned thereafter (Z2M frontend writes devices /
    # groups / friendly-names here). All TF-managed `mqtt.*` and `serial.*`
    # values come in via `ZIGBEE2MQTT_CONFIG_*` env vars on the main
    # container — Z2M overrides any matching key in configuration.yaml with
    # the env value at runtime, never persisting the override to disk. This
    # sidesteps Z2M's schema migrations rewriting `!include` / `!secret`
    # references (issues #27077, #21803, #27696). `version: 5` matches Z2M's
    # current settings schema so migrations are a no-op on first load.
    "configuration.yaml" = <<-EOT
      version: 5

      homeassistant:
        enabled: true

      frontend:
        enabled: true
        host: 127.0.0.1
        port: 8080

      advanced:
        log_level: info
        log_output:
          - console
        cache_state: true
        cache_state_persistent: true

      availability:
        enabled: true
        active:
          timeout: 10
        passive:
          timeout: 1500
    EOT
  }
}

resource "kubernetes_config_map" "homeassist_z2m_nginx_config" {
  metadata {
    name      = "homeassist-z2m-nginx-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/homeassist-z2m.nginx.conf.tpl", {
      server_domain = "${var.homeassist_z2m_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    })
  }
}
