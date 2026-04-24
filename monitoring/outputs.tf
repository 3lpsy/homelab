output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "ntfy_grafana_password" {
  value     = random_password.ntfy_user_passwords["grafana"].result
  sensitive = true
}

output "ntfy_prometheus_password" {
  value     = random_password.ntfy_user_passwords["prometheus"].result
  sensitive = true
}

output "openobserve_root_email" {
  value = local.openobserve_root_email
}

output "openobserve_root_password" {
  value     = random_password.openobserve_root.result
  sensitive = true
}
