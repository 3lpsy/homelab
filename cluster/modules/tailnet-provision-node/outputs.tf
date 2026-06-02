output "tailscale_ip" {
  value = data.headscale_device.nomad_server.addresses.0
}
