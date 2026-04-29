# Surfaced for downstream deployments (e.g. backup/) that need the cluster's
# canonical cluster label.
output "cluster_name" {
  value = var.node_host_name
}
