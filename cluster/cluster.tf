# Join node to the tailnet (initial connection uses LAN IP)
module "tailnet-provision-node" {
  source                  = "./modules/tailnet-provision-node"
  server_ip               = var.node_server_ip
  ssh_user                = var.node_ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  nomad_hostname          = var.node_host_name
  headscale_server_domain = data.terraform_remote_state.homelab.outputs.headscale_server_fqdn
  tailnet_auth_key        = data.terraform_remote_state.homelab.outputs.node_preauth_key
  # No subnet-route advertisement. delphi USED to advertise the K8s pod CIDR
  # (so a laptop with --accept-routes could hit pod IPs directly), but once a
  # second node joined, any node with --accept-routes installed that 10.42/16
  # route into tailscale's policy table (52, which beats `main`), hijacking ALL
  # pod traffic onto tailscale0 — where pod-sourced packets are dropped. That
  # broke cross-node pod↔pod + pod→apiserver on the agent (CSI driver CrashLoop,
  # "could not create RESTMapper"). The advertiser itself never installs its own
  # route, so delphi looked fine while artemis was broken. Intra-cluster pod
  # routing is flannel's job (flannel-wg), independent of this; node↔node and
  # laptop↔node use tailnet PEER IPs (no advertisement needed). Reaching raw pod
  # IPs from a laptop is the only thing lost — use the per-service tailscale
  # ingresses or kubectl instead. See docs/CLUSTER.md.
  advertise_routes        = ""

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

# Shared password for the read-only NUT "upsmon" user. Same value on both nodes:
# it's in delphi's upsd.users and the MONITOR line on both delphi and artemis.
# special=false keeps upsd.users / upsmon.conf parsing simple (no shell-special
# chars). Rotate with `terraform apply -replace='random_password.nut_monitor'`.
resource "random_password" "nut_monitor" {
  length  = 24
  special = false
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
  # services deployment.
  registry_dockerio_domain  = "registry-dockerio"
  registry_ghcrio_domain    = "registry-ghcrio"
  zigbee_dongle_serial      = var.zigbee_dongle_serial
  # delphi is the control-plane node + Coral host; no discrete AMD GPU.
  k3s_role                  = "server"
  enable_coral              = true
  enable_rocm               = false
  enable_lact               = false
  # No atlantic/AQC NIC on delphi.
  enable_atlantic_gso_fix   = false
  # Subuid pool for hostUsers:false pods (provisioned but currently unused).
  enable_user_namespaces    = true
  # NUT primary: delphi has the UPS on USB. Runs the driver + upsd + upsmon and
  # serves status to artemis over the LAN. Shutdown fires at ~3 min remaining
  # runtime (default nut_runtime_low) with a 10-min wall-clock backstop.
  nut_role                  = "primary"
  nut_monitor_password      = random_password.nut_monitor.result
  # Open upsd's 3493/tcp to artemis only (firewalld rich-rule, scoped to its LAN
  # IP). delphi default-denies, so without this the secondary can't reach upsd.
  nut_allow_sources         = [var.artemis_server_ip]
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
    "**/target",      # Rust/Cargo build output

    # Per-PVC opt-outs for regenerable / high-churn volumes. Match
    # pvc-<uuid>_<namespace>_<pvc-name>.
    "pvc-*_registry_registry-data",                       # image layers; rebuild via BuildKit
    "pvc-*_registry-proxy_registry-proxy-data",           # combined docker.io + ghcr.io pull-through cache
    "pvc-*_prometheus_prometheus-data",                   # TSDB; regenerated as scrapes resume
    "pvc-*_openobserve_openobserve-data",                 # logs; ingested fresh
    "pvc-*_grafana_grafana-data",                         # dashboards from services-conf
    "pvc-*_pihole_pihole-data",                           # settings via FTLCONF env; query log + gravity DB rebuild
  ]
  on_calendar = "daily"
  depends_on  = [module.cluster-provision]
}

# ════════════════════════════════════════════════════════════════════════════
# artemis — GPU agent node (2× Radeon AI PRO R9700). Worker-only: joins
# delphi's control plane as a K3s agent. See docs/CLUSTER.md.
#
# Reuses every delphi module: same tailnet identity (group:node-server, so
# acls_self covers agent→server traffic), same ACME/TLS flow, same node
# provisioning module — with enable_coral=false, enable_rocm=true,
# k3s_role="agent".
# ════════════════════════════════════════════════════════════════════════════

module "artemis-tailnet-provision-node" {
  source                  = "./modules/tailnet-provision-node"
  server_ip               = var.artemis_server_ip
  ssh_user                = var.node_ssh_user
  ssh_priv_key            = trimspace(file(var.ssh_priv_key_path))
  nomad_hostname          = var.artemis_host_name
  headscale_server_domain = data.terraform_remote_state.homelab.outputs.headscale_server_fqdn
  # Same multi-use preauth key as delphi (homelab nomad_server key, now
  # reusable). Both nodes land in group:node-server.
  tailnet_auth_key = data.terraform_remote_state.homelab.outputs.node_preauth_key
  # delphi stays the sole pod-CIDR subnet-router (it owns the kube-router
  # FORWARD-chain handling, cluster.tf:10). A second advertiser would be
  # redundant — artemis advertises nothing.
  advertise_routes = ""

  providers = {
    headscale = headscale
  }
}

module "artemis-infra-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.artemis_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  depends_on = [module.artemis-tailnet-provision-node]
  providers = {
    acme = acme
  }
}

module "artemis-provision-tls" {
  source            = "./../templates/provision-tls"
  server_ip         = "${var.artemis_host_name}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  ssh_user          = var.node_ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = module.artemis-infra-tls.certificate_domain
  tls_privkey_pem   = module.artemis-infra-tls.privkey_pem
  tls_fullchain_pem = module.artemis-infra-tls.fullchain_pem
  depends_on        = [module.artemis-infra-tls]
}

module "artemis-provision-dep" {
  source       = "./modules/node-provision-dep"
  server_ip    = module.artemis-infra-tls.certificate_domain
  ssh_user     = var.node_ssh_user
  ssh_priv_key = trimspace(file(var.ssh_priv_key_path))
  depends_on   = [module.artemis-tailnet-provision-node, module.artemis-infra-tls]
}

# Read delphi's K3s server node-token at apply time so artemis can join as an
# agent. Reuses the TF host's existing SSH access to delphi; the token only
# rotates on a server reinstall, so an apply-time read is stable. depends_on
# delphi's provision module so the token file exists before we read it.
# See data/scripts/read-k3s-token.py.
#
# Gated off when var.k3s_node_token is supplied — then the token comes from the
# var and a routine cluster plan/apply does NOT SSH delphi (decouples every
# plan from delphi being reachable). Only reads live when the var is empty.
data "external" "k3s_node_token" {
  count = var.k3s_node_token == "" ? 1 : 0

  program = ["python3", "${path.module}/../data/scripts/read-k3s-token.py"]

  query = {
    host         = module.node-infra-tls.certificate_domain # delphi fqdn
    ssh_user     = var.node_ssh_user
    ssh_key_path = var.ssh_priv_key_path
  }

  depends_on = [module.cluster-provision]
}

# Prefer the explicit var; otherwise fall back to the live SSH read above. The
# conditional's unchosen branch is not evaluated, so data.external[0] is never
# indexed when the var is set (and the data source has count 0).
locals {
  artemis_k3s_token = var.k3s_node_token != "" ? var.k3s_node_token : data.external.k3s_node_token[0].result.token
}

module "artemis-provision" {
  source                    = "./modules/node-provision-server"
  host                      = module.artemis-infra-tls.certificate_domain
  ssh_user                  = var.node_ssh_user
  ssh_priv_key              = trimspace(file(var.ssh_priv_key_path))
  nomad_host_name           = var.artemis_host_name
  headscale_magic_subdomain = "${var.headscale_subdomain}.${var.headscale_magic_domain}"
  registry_domain           = data.terraform_remote_state.homelab.outputs.tailnet_user_name_map["registry_server_user"]
  registry_dockerio_domain  = "registry-dockerio"
  registry_ghcrio_domain    = "registry-ghcrio"
  # No Zigbee dongle and no Coral on artemis; ROCm for the 2× R9700.
  zigbee_dongle_serial = ""
  enable_coral         = false
  enable_rocm          = true
  # LACT (lactd) for GPU telemetry → llama-swap Performance Monitor reads
  # /run/lactd.sock (mounted by services/llm.tf).
  enable_lact          = true
  # AQC113 10GbE (atlantic driver) — disable its broken UDP-GSO or all tailscale
  # off artemis is capped at ~9.5 Mbps. See node-provision-server/main.tf.
  enable_atlantic_gso_fix = true
  # Subuid pool for hostUsers:false pods (provisioned but currently unused).
  enable_user_namespaces = true
  # Agent join: delphi's fqdn is in its k3s serving cert (--tls-san), so the
  # https URL validates. node-token read above.
  k3s_role       = "agent"
  k3s_server_url = "https://${module.node-infra-tls.certificate_domain}:6443"
  k3s_token      = local.artemis_k3s_token
  # Deny-by-default: nothing schedules onto artemis without an explicit
  # gpu=true:NoSchedule toleration. Keeps every delphi workload off artemis's
  # empty local-path disk — no per-pod affinity needed on the existing stack.
  # Pods migrated here later add the matching toleration + nodeSelector/affinity.
  node_taints = ["gpu=true:NoSchedule"]
  # Positive counterpart to the taint: artemis-bound workloads select
  # node=artemis (+ the gpu toleration). Cleaner than the auto-assigned
  # kubernetes.io/hostname label, which is the full fqdn. Registration-only.
  node_labels = ["node=artemis"]

  # NUT secondary: no UPS of its own. upsmon monitors delphi's upsd over delphi's
  # LAN IP (var.node_server_ip), NOT the tailnet FQDN — so the shutdown signal
  # survives a tailscaled hiccup and depends only on the LAN switch (keep that on
  # the UPS too). Comms loss is NOCOMM-only, never a shutdown trigger.
  nut_role             = "secondary"
  nut_monitor_password = random_password.nut_monitor.result
  nut_primary_host     = var.node_server_ip

  depends_on = [module.artemis-provision-dep, data.external.k3s_node_token]
}

# Same all-in-one kopia backup as delphi (host config + any PVCs that migrate
# to artemis). Identical paths + excludes — local-path's namespace-prefixed
# pvc-<uuid>_<ns>_<name> dirs mean per-namespace excludes work on either node.
module "artemis-provision-kopia" {
  source                = "./../templates/provision-kopia"
  server_ip             = module.artemis-infra-tls.certificate_domain
  ssh_user              = var.node_ssh_user
  ssh_priv_key          = trimspace(file(var.ssh_priv_key_path))
  bucket_name           = data.terraform_remote_state.homelab.outputs.backup_bucket_name
  bucket_region         = data.terraform_remote_state.homelab.outputs.backup_bucket_region
  prefix                = data.terraform_remote_state.homelab.outputs.backup_prefixes["artemis"]
  aws_access_key_id     = data.terraform_remote_state.homelab.outputs.backup_iam_keys["artemis"].access_key_id
  aws_secret_access_key = data.terraform_remote_state.homelab.outputs.backup_iam_keys["artemis"].secret_access_key
  repo_password         = data.terraform_remote_state.homelab.outputs.backup_repo_passwords["artemis"]
  backup_paths          = ["/etc", "/root", "/var/lib/rancher/k3s/storage"]
  exclude_globs = [
    # Generic noise.
    "**/.cache",
    "**/node_modules",
    "**/.venv",
    "**/__pycache__",
    "**/target",      # Rust/Cargo build output

    # Per-PVC opt-outs for regenerable / high-churn volumes (harmless if the
    # PVC isn't present on this node). Match pvc-<uuid>_<namespace>_<pvc-name>.
    "pvc-*_registry_registry-data",
    "pvc-*_registry-proxy_registry-proxy-data",
    "pvc-*_prometheus_prometheus-data",
    "pvc-*_openobserve_openobserve-data",
    "pvc-*_grafana_grafana-data",
    "pvc-*_pihole_pihole-data",
  ]
  on_calendar = "daily"
  depends_on  = [module.artemis-provision]
}
