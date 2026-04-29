# Join node to the tailnet (initial connection uses LAN IP)
module "tailnet-provision-node" {
  source                  = "./modules/tailnet-provision-node"
  server_ip               = var.node_server_ip
  ssh_user                = var.node_ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  nomad_hostname          = var.node_host_name
  headscale_server_domain = data.terraform_remote_state.homelab.outputs.headscale_server_fqdn
  tailnet_auth_key        = data.terraform_remote_state.homelab.outputs.node_preauth_key
  # delphi advertises the K8s pod CIDR so external tailnet clients (e.g.
  # laptop with --accept-routes) can reach pod IPs via delphi's flannel
  # gateway without kubectl port-forward. Auto-approved by the
  # autoApprovers.routes entry in the Headscale ACL policy.
  #
  # End-to-end pod-IP reachability also requires kube-router to forward
  # tailnet ingress to the destination pod — by default it doesn't,
  # because NetworkPolicy default-deny treats tailnet traffic as
  # "external" and drops it at the FORWARD chain. Reaching a specific
  # pod-IP via this route requires a NetworkPolicy permitting tailnet
  # (100.64.0.0/10) ingress to that pod's namespace.
  advertise_routes        = var.k8s_pod_cidr

  providers = {
    headscale = headscale
  }
}

# After tailnet join, all subsequent connections use the Tailscale hostname
module "node-infra-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.node_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  depends_on = [module.tailnet-provision-node]
  providers = {
    acme = acme
  }
}

module "node-provision-tls" {
  source            = "./../templates/provision-tls"
  server_ip         = "${var.node_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  ssh_user          = var.node_ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = module.node-infra-tls.certificate_domain
  tls_privkey_pem   = module.node-infra-tls.privkey_pem
  tls_fullchain_pem = module.node-infra-tls.fullchain_pem
  depends_on        = [module.node-infra-tls]
}

module "node-provision-dep" {
  source       = "./modules/node-provision-dep"
  server_ip    = module.node-infra-tls.certificate_domain
  ssh_user     = var.node_ssh_user
  ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
  depends_on   = [module.tailnet-provision-node, module.node-infra-tls]
}

module "cluster-provision" {
  source                    = "./modules/node-provision-server"
  host                      = module.node-infra-tls.certificate_domain
  ssh_user                  = var.node_ssh_user
  ssh_priv_key              = trimspace(file(var.ssh_priv_key_path))
  nomad_host_name           = var.node_host_name
  headscale_magic_subdomain = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  registry_domain           = data.terraform_remote_state.homelab.outputs.tailnet_user_name_map["registry_server_user"]
  # Hostname is decoupled from headscale username — `registry_proxy_server_user`
  # remains "registry-proxy" so additional mirrors (registry-quayio, etc.) can
  # share the same headscale identity / ACL group while taking distinct
  # TS_HOSTNAMEs. This literal must match var.registry_dockerio_domain in the
  # nextcloud deployment.
  registry_dockerio_domain  = "registry-dockerio"
  registry_ghcrio_domain    = "registry-ghcrio"
  depends_on                = [module.node-provision-dep]
}

# All-in-one backup of delphi: host config + PVC contents.
#
# - /etc, /root: host config that's not Terraform-managed (SSH host keys,
#   ad-hoc admin scripts, anything ssh-edited).
# - /var/lib/rancher/k3s/storage: every PVC's actual bytes. The local-path
#   provisioner stores each PVC under pvc-<uuid>_<namespace>_<pvc-name>/ in
#   that directory; kopia walks them as plain files and encrypts client-side.
#
# Cluster API state (Deployments, Services, ConfigMaps, CRDs, RBAC, ...) is
# *not* backed up here. It's reproduced from this Terraform repo on
# `terraform apply` — git is the authoritative source, more reliable than a
# stale point-in-time snapshot.
#
# Excludes below cover both gitignore-style noise (caches, build artifacts)
# and per-PVC opt-outs for volumes whose data is regenerable. Local-path's
# directory naming is `pvc-<uuid>_<namespace>_<pvc-name>`, so we glob by
# namespace+name and accept any UUID.
module "delphi-provision-kopia" {
  source                = "./../templates/provision-kopia"
  server_ip             = module.node-infra-tls.certificate_domain
  ssh_user              = var.node_ssh_user
  ssh_priv_key          = trimspace(file(var.ssh_priv_key_path))
  bucket_name           = data.terraform_remote_state.homelab.outputs.backup_bucket_name
  bucket_region         = data.terraform_remote_state.homelab.outputs.backup_bucket_region
  prefix                = data.terraform_remote_state.homelab.outputs.backup_prefixes["delphi"]
  aws_access_key_id     = data.terraform_remote_state.homelab.outputs.backup_iam_keys["delphi"].access_key_id
  aws_secret_access_key = data.terraform_remote_state.homelab.outputs.backup_iam_keys["delphi"].secret_access_key
  repo_password         = data.terraform_remote_state.homelab.outputs.backup_repo_passwords["delphi"]
  backup_paths          = ["/etc", "/root", "/var/lib/rancher/k3s/storage"]
  exclude_globs = [
    # Generic noise.
    "**/.cache",
    "**/node_modules",
    "**/.venv",
    "**/__pycache__",

    # Per-PVC opt-outs for regenerable / high-churn volumes. Match
    # pvc-<uuid>_<namespace>_<pvc-name>.
    "pvc-*_registry_registry-data",                       # image layers; rebuild via BuildKit
    "pvc-*_registry-proxy_registry-proxy-data",           # combined docker.io + ghcr.io pull-through cache
    "pvc-*_monitoring_prometheus-data",                   # TSDB; regenerated as scrapes resume
    "pvc-*_monitoring_openobserve-data",                  # logs; ingested fresh
    "pvc-*_monitoring_grafana-data",                      # dashboards from monitoring-conf
    "pvc-*_frigate_frigate-recordings",                   # camera recordings
    "pvc-*_frigate_frigate-config",                       # events DB references excluded recordings
    "pvc-*_pihole_pihole-data",                           # settings via FTLCONF env; query log + gravity DB rebuild
  ]
  on_calendar = "daily"
  depends_on  = [module.cluster-provision]
}
