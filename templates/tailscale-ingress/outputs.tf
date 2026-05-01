output "auth_secret_name" {
  description = "Name of the k8s Secret carrying TS_AUTHKEY. Mount this in the tailscale sidecar's env."
  value       = kubernetes_secret.tailscale_auth.metadata[0].name
}

output "state_secret_name" {
  description = "Name of the k8s Secret tailscaled writes its node state to. Pass to TS_KUBE_SECRET in the tailscale sidecar."
  value       = kubernetes_secret.tailscale_state.metadata[0].name
}
