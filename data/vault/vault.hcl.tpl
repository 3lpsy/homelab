ui = true

# Internal listener for in-cluster communication (no TLS)
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "127.0.0.1:9200"
  tls_disable     = 1
}

# External listener for Tailscale access (with TLS)
listener "tcp" {
  address         = "0.0.0.0:8201"
  cluster_address = "127.0.0.1:9201"
  tls_disable     = 0
  tls_cert_file   = "/vault/tls/tls.crt"
  tls_key_file    = "/vault/tls/tls.key"
}

storage "file" {
  path = "/vault/data"
}

disable_mlock = true
