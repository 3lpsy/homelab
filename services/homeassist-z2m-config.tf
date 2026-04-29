resource "kubernetes_config_map" "homeassist_z2m_config" {
  metadata {
    name      = "homeassist-z2m-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    # Seed configuration.yaml. The seed-z2m-config init container copies this
    # to /app/data/configuration.yaml on first boot only — subsequent edits
    # made via the Z2M frontend (pairings, group assignments, friendly names)
    # live on the PVC and are not overwritten.
    #
    # serial.port is included only when var.homeassist_z2m_usb_device_path is
    # set. While empty, Z2M will start, find no coordinator, and crash-loop the
    # main container — that's the visible signal you still need to plug in
    # the dongle and set the variable.
    "configuration.yaml" = <<-EOT
      homeassistant:
        enabled: true

      permit_join: false

      mqtt:
        base_topic: zigbee2mqtt
        server: mqtt://mosquitto.homeassist.svc.cluster.local:1883
        user: z2m
        password: '!secret mqtt_password'

      %{ if var.homeassist_z2m_usb_device_path != "" ~}
      serial:
        port: /dev/zigbee
        adapter: ember
      %{ endif ~}

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
