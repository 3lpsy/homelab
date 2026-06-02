variable "account_key_pem" {
  type = string
}
variable "server_domain" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_access_key" {
  type = string
}

variable "aws_secret_key" {
  type = string
}
variable "recursive_nameservers" {
  type = list(string)
}
