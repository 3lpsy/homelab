# NetworkPolicies for the `frigate` namespace.
#
# Single-pod namespace (frigate + nginx + tailscale sidecars in one pod).
# No cross-namespace traffic today. Camera ingress is RTSP/ONVIF over the
# LAN, which doesn't traverse the cluster network.

module "frigate_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.frigate.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
}
