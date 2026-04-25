resource "kubernetes_config_map" "homeassist_mosquitto_config" {
  metadata {
    name      = "homeassist-mosquitto-config"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }
  data = {
    "mosquitto.conf" = <<-EOT
      persistence true
      persistence_location /mosquitto/data/
      log_dest stdout
      log_type error
      log_type warning
      log_type notice

      listener 1883
      protocol mqtt
      allow_anonymous false
      password_file /mosquitto/auth/passwd
    EOT
  }
}
