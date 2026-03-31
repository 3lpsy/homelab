

variable "headscale_server_domain" {
  type = string
}
variable "headscale_key_path" {
  type = string
}
variable "api_key" {
  type      = string
  sensitive = true
}
variable "tailnet_users" {
  description = "Map of role keys to headscale usernames"
  type        = map(string)
}
