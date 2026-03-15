# Output Public IP of the EC2 Instance
output "public_ip" {
  value = aws_eip.main.public_ip
}
output "ssh_user" {
  value = var.ec2_user
}
output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_id" {
  value = aws_subnet.main.id
}
output "gateway_id" {
  value = aws_internet_gateway.main.id
}
output "backup_bucket_name" {
  value = aws_s3_bucket.main.bucket
}
