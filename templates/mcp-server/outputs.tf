output "deployment_name" {
  description = "Name of the Deployment created by this module."
  value       = kubernetes_deployment.this.metadata[0].name
}

output "service_name" {
  description = "Name of the Service created by this module. Other resources (e.g. mcp-shared nginx upstreams) reference this."
  value       = kubernetes_service.this.metadata[0].name
}

output "service_cluster_ip" {
  description = "Cluster IP of the Service. Useful for callers that want to wire host_aliases against this server."
  value       = kubernetes_service.this.spec[0].cluster_ip
}
