# monitoring/outputs.tf
output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "ntfy_grafana_password" {
  value     = random_password.ntfy_user_passwords["grafana"].result
  sensitive = true
}
