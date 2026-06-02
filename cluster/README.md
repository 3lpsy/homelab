# Cluster

Provisions the K3s node: joins it to the Headscale tailnet, deploys TLS certs, installs dependencies, and installs K3s with wireguard-native flannel.

Extracted from the homelab deployment. Module directories were renamed from `nomad-*` to `node-*` but internal variable/resource names are unchanged.

## Modules

| Module instance | Source | Purpose |
|---|---|---|
| `tailnet-provision-node` | local | Install Tailscale, join tailnet, trust tailscale0 in firewalld |
| `node-infra-tls` | template `infra-tls` | ACME cert for node's magic domain name |
| `node-provision-tls` | template `provision-tls` | SCP certs to node |
| `node-provision-dep` | local | dnf: git, nginx, neovim, wget, yq |
| `cluster-provision` | local (`node-provision-server`) | K3s install, firewalld ports, systemd-resolved, registry mirror, scoped DNS |

## Dependency flow

Initial connection to the node uses its LAN IP (`node_server_ip`). After `tailnet-provision-node` joins the mesh, all subsequent modules connect via the Tailscale hostname.

```
tailnet-provision-node  (LAN IP)
  └─ node-infra-tls  (ACME cert)
       ├─ node-provision-tls  (deploy certs via Tailscale hostname)
       └─ node-provision-dep  (install packages)
            └─ cluster-provision  (install K3s)
```

## State migration

This deployment was extracted from homelab. Resources need to be moved from the homelab state to the cluster state before applying.

### 1. Update .env

Add cluster variables to `.env`. The nomad variables map to:

```
nomad_server_ip  → node_server_ip
nomad_ssh_user   → node_ssh_user
nomad_host_name  → node_host_name
```

### 2. Create the cluster state directory and initialize

```bash
mkdir -p $HOME/Playground/private/envs/homelab/cluster
./terraform.sh cluster init
```

### 3. Move resources from homelab to cluster state

Do this BEFORE applying either deployment. The old module names map to new names:

```
module.tailnet-provision-nomad  → module.tailnet-provision-node
module.nomad-infra-tls          → module.node-infra-tls
module.nomad-provision-tls      → module.node-provision-tls
module.nomad-provision-dep      → module.node-provision-dep
module.nomad-provision-server   → module.cluster-provision
```

Run these moves (adjust state file paths to match your layout):

```bash
HOMELAB_STATE="$HOME/Playground/private/envs/homelab/homelab/terraform.tfstate"
CLUSTER_STATE="$HOME/Playground/private/envs/homelab/cluster/terraform.tfstate"

terraform state mv -state="$HOMELAB_STATE" -state-out="$CLUSTER_STATE" \
  'module.tailnet-provision-nomad' 'module.tailnet-provision-node'

terraform state mv -state="$HOMELAB_STATE" -state-out="$CLUSTER_STATE" \
  'module.nomad-infra-tls' 'module.node-infra-tls'

terraform state mv -state="$HOMELAB_STATE" -state-out="$CLUSTER_STATE" \
  'module.nomad-provision-tls' 'module.node-provision-tls'

terraform state mv -state="$HOMELAB_STATE" -state-out="$CLUSTER_STATE" \
  'module.nomad-provision-dep' 'module.node-provision-dep'

terraform state mv -state="$HOMELAB_STATE" -state-out="$CLUSTER_STATE" \
  'module.nomad-provision-server' 'module.cluster-provision'
```

### 4. Verify

```bash
./terraform.sh homelab plan    # Should show only the new node_preauth_key output
./terraform.sh cluster plan    # Should show no changes
```

### 5. Apply homelab

```bash
./terraform.sh homelab apply   # Registers the new output
```

## Gotchas

- **Node is Fedora** -- uses dnf, firewalld, systemd-resolved. Not Ubuntu.
- **Nomad naming in modules** -- internal variable/resource names still reference "nomad" (e.g. `nomad_hostname`, `nomad_host_name`). Renaming these would require state surgery on individual resources within modules. Planned for later.
- **Headscale provider** -- the cluster deployment needs `headscale_api_key` for the device data source in tailnet-provision-node.
