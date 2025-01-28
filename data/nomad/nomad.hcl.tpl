log_level = "INFO"
datacenter = "dc1"
region     = "global"
name       = "${nomad_host_name}"

# Use the IP address of the Tailscale interface
# bind_addr = "{{ GetInterfaceIP \"tailscale0\" }}"
bind_addr = "127.0.0.1"
data_dir  = "/opt/nomad/data"
plugin_dir = "/opt/nomad/plugins"
server {
  enabled          = true
  bootstrap_expect = 1
}

plugin "nomad-driver-podman" {
  config {
    socket_path = "unix:///run/podman/podman.sock"
  }
}

advertise {
  # Advertise addresses using the Tailscale interface IP
  # http = "{{ GetInterfaceIP \"tailscale0\" }}:4646"
  http = "127.0.0.1:4646"
  rpc  = "127.0.0.1:4647"
  serf = "127.0.0.1:4648"
}

addresses {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

acl {
  enabled = true
}

client {
  enabled = true
  options {
    "driver.allowlist" = "podman"
  }
  %{ for v in host_volumes ~}
  host_volume "${v}" {
    path      = "/opt/volumes/${v}"
    read_only = false
  }
  %{ endfor ~}


}
