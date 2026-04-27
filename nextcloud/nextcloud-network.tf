# NetworkPolicies for the `nextcloud` namespace.
#
# The namespace hosts: nextcloud, collabora, immich (server + ML + postgres
# + redis), shared postgres, shared redis. The default-deny baseline below
# allows all of them to talk to each other freely (intra-ns), reach the
# K8s API (Tailscale sidecars manage their own state Secrets), and egress
# to the internet (Tailscale Headscale + DERP, ML model downloads, etc).
#
# No explicit cross-namespace allows are needed today because every
# external reach (nextcloud↔collabora WOPI loop, etc.) traverses the
# pods' Tailscale sidecars, which bypass NetworkPolicy at the CNI layer.
# Once the deferred CoreDNS rewrites collapse those paths to ClusterIP,
# add the corresponding cross-ns rules in `collabora-network.tf` and
# `immich-network.tf`.

module "nextcloud_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace    = kubernetes_namespace.nextcloud.metadata[0].name
  pod_cidr     = var.k8s_pod_cidr
  service_cidr = var.k8s_service_cidr
  # internet + K8s API egress on (defaults). Both required: Tailscale
  # sidecars need internet for Headscale/DERP and the K8s API for
  # TS_KUBE_SECRET state.
}
