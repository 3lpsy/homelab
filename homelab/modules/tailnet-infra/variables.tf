
# pub key contents
variable "headscale_server_domain" {
  type = string
}

variable "api_key" {
  type      = string
  sensitive = true
}

variable "personal_username" {
  type = string
}
variable "mobile_user" {
  type = string
}

variable "nomad_server_username" {
  type = string
}
