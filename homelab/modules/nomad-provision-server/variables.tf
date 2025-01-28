
# pub key contents
variable "host" {
  type = string
}
variable "ssh_user" {
  type = string
}
variable "ssh_priv_key" {
  type = string
}
variable "nomad_host_name" {
  type = string
}
variable "host_volumes_dir" {
  type    = string
  default = "/opt/volumes"
}
variable "host_volumes" {
  type    = list(string)
  default = []
}
# variable "kernel_version" {
#   type    = string
#   default = "6.1"
#   # default = "6.13" lts
# }

# variable "firecracker_version" {
#   type    = string
#   default = "1.10.1"
#   # default = "6.13" lts
# }

# variable "kata_version" {
#   type    = string
#   default = "3.11.0"
# }
