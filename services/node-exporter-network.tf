# NetworkPolicies for the `node-exporter` namespace.
#
# DaemonSet on host network (hostNetwork: true), exposes :9100. Prometheus
# scrapes it via the node IP — that traffic is governed by an ipBlock
# allow in services/prometheus-network.tf:`prometheus_scrape_host_targets`,
# not by a pod-level netpol here, because hostNetwork pods bypass the CNI
# ingress chain and source/destination IPs are the node's, not pod IPs.
#
# So this namespace only needs the default-deny baseline. node-exporter
# itself does not initiate any cluster-internal connections.

module "node_exporter_netpol_baseline" {
  source = "./../templates/netpol-baseline"

  namespace             = kubernetes_namespace.node_exporter.metadata[0].name
  pod_cidr              = var.k8s_pod_cidr
  service_cidr          = var.k8s_service_cidr
  allow_internet_egress = false
  allow_kube_api_egress = false
}
