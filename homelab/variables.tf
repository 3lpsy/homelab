variable "aws_region" {
  type      = string
  default   = "us-east-1"
  sensitive = true

}

variable "aws_access_key" {
  type      = string
  sensitive = true

}

variable "aws_secret_key" {
  type      = string
  sensitive = true

}

variable "headscale_server_domain" {
  type = string
}

variable "headscale_magic_domain" {
  type = string
}
variable "headscale_subdomain" {
  type    = string
  default = "hs"
}
variable "registration_email_address" {
  type = string
}

variable "ssh_priv_key_path" {
  type    = string
  default = "../ssh.pem"
}

variable "ssh_pub_key_path" {
  type    = string
  default = "../ssh.pem.pub"
}
