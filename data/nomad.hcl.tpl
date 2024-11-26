log_level = "INFO"
datacenter = "dc1"
region     = "global"
name       = "${nomad_host_name}"

# Use the IP address of the Tailscale interface
bind_addr = "{{ GetInterfaceIP \"tailscale0\" }}"
data_dir  = "/opt/nomad/data"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

advertise {
  # Advertise addresses using the Tailscale interface IP
  http = "{{ GetInterfaceIP \"tailscale0\" }}:4646"
  rpc  = "{{ GetInterfaceIP \"tailscale0\" }}:4647"
  serf = "{{ GetInterfaceIP \"tailscale0\" }}:4648"
}

addresses {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

acl {
  enabled = true
}
