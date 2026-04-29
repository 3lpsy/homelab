# NetworkPolicies for the `homeassist` namespace.
#
# Hosts: home-assistant, mosquitto MQTT broker, zigbee2mqtt. All
# cross-pod traffic is intra-namespace (HA → mosquitto:1883, z2m →
# mosquitto:1883). Z2M and HA both also expose UIs that are reached
# externally via Tailscale sidecars (NetPol-invisible).
#
# Frigate currently has MQTT disabled (`data/frigate/config.yml.tpl`
# `mqtt: enabled: false`); if that changes to true in the future, add a
# cross-ns ingress here for `frigate:1883`.

module "homeassist_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.homeassist.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
