output "public_ip" {
  value = aws_eip.ollama.public_ip
}

output "instance_id" {
  value = aws_instance.ollama.id
}
