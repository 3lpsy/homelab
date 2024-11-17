# Output Public IP of the EC2 Instance
output "public_ip" {
  value = aws_eip.main.public_ip
}
output "ssh_user" {
  value = var.ec2_user
}
