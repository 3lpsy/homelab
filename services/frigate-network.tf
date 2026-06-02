# Cross-namespace allow for Frigate -> Mosquitto MQTT (1883). Frigate
# publishes detection events; Home Assistant's Frigate integration
# subscribes from inside the homeassist namespace.

resource "kubernetes_network_policy" "frigate_to_mosquitto" {
  metadata {
    name      = "frigate-to-mosquitto"
    namespace = kubernetes_namespace.frigate.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "frigate" } }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.homeassist.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "homeassist-mosquitto" } }
      }
      ports {
        protocol = "TCP"
        port     = "1883"
      }
    }
  }
}

resource "kubernetes_network_policy" "mosquitto_from_frigate" {
  metadata {
    name      = "mosquitto-from-frigate"
    namespace = kubernetes_namespace.homeassist.metadata[0].name
  }

  spec {
    pod_selector { match_labels = { app = "homeassist-mosquitto" } }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace.frigate.metadata[0].name
          }
        }
        pod_selector { match_labels = { app = "frigate" } }
      }
      ports {
        protocol = "TCP"
        port     = "1883"
      }
    }
  }
}
