# pub key contents
variable "ssh_pub_key" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}
variable "ssh_user" {
  type = string
}

variable "tailnet_auth_key" {
  type = string
  sensitive = true
}
variable "headscale_server_domain" {
  type = string
}
variable "node_name" {
  type = string
}
variable "ec2_user" {
  type    = string
}
variable "ami" {
  type    = string
}
variable "availability_zone" {
  type = string
  default = "us-east-1a"
}

variable "gateway_id" {
  type = string
}

variable "vpc_id" {
  type    = string
}
variable "subnet_cidr" {
  type = string
  default =  "10.0.1.0/24"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}
