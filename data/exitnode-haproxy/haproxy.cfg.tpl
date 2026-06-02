global
  log stdout format raw local0
  maxconn 4096
  daemon

defaults
  mode    tcp
  log     global
  option  tcplog
  timeout connect 5s
  timeout client  5m
  timeout server  5m

# TCP pass-through. The downstream tinyproxy at each exit-node speaks
# HTTP/CONNECT; HAProxy doesn't need to parse the inner protocol — it just
# pipes bytes between the client and a randomly-selected exit pod.
frontend exits_in
  bind *:8888
  default_backend exits

# Tailnet-facing TLS-terminating forward-proxy frontend. Clients set
# HTTPS_PROXY=https://exitnode-haproxy.<tailnet-fqdn>:443 — TLS is decrypted
# here, then the inner HTTP CONNECT/GET is piped to a random exit pod.
# Combined PEM is assembled by the cert-init container at pod start.
frontend exits_in_tls
  bind *:443 ssl crt /etc/haproxy/certs/combined.pem
  default_backend exits

backend exits
  # Per-TCP-connection randomization. Subsequent connections roll a fresh
  # selection — sufficient for rate-limit dodging on services like docker.io.
  balance random
  option tcp-check

%{ for name in exitnode_names ~}
  server ${name} exitnode-${name}-proxy.${exitnode_ns}.svc.cluster.local:8888 check inter 30s rise 2 fall 3
%{ endfor ~}

# Optional /healthz on a separate port for k8s probes.
frontend health
  bind *:8889
  mode http
  monitor-uri /healthz
