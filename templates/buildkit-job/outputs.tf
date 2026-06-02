output "image_ref" {
  description = "Passthrough of the input image_ref so callers can reference module.<name>.image_ref instead of the local."
  value       = var.image_ref
}

output "job_name" {
  description = "Name of the BuildKit Job, including the content-hash suffix used to trigger rebuilds."
  value       = local.job_name
}
