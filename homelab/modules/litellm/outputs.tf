output "public_ip" {
  value = aws_instance.litellm.public_ip
}

output "instance_id" {
  value = aws_instance.litellm.id
}

output "master_key" {
  value     = "sk-${random_password.litellm_master_key.result}"
  sensitive = true
}
