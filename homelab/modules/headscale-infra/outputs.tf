# Output Public IP of the EC2 Instance
output "public_ip" {
  value = aws_eip.main.public_ip
}
output "ssh_user" {
  value = var.ec2_user
}

output "backup_bucket_name" {
  value = aws_s3_bucket.main.bucket
}
