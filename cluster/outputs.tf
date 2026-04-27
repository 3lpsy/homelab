# Surfaced for downstream deployments (e.g. backup/) that need the cluster's
# canonical name, e.g. for the Velero S3 prefix `cluster-${cluster_name}/velero/`.
output "cluster_name" {
  value = var.node_host_name
}
