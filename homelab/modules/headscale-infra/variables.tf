# pub key contents
variable "ssh_pub_key" {
  type = string
}
variable "ec2_user" {
  type    = string
  default = "ubuntu" # or ec2-user
}
variable "ami" {
  type    = string
  default = "ami-0557a15b87f6559cf"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

# for backups
variable "backup_bucket_name" {
  type = string
}
