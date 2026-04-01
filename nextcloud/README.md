# Nextcloud Deployment

Terraform deployment for application services running on K3s. Despite the name, this covers more than just Nextcloud.

## Services

| Service | Namespace | Exposed via | Purpose |
|---------|-----------|-------------|---------|
| Nextcloud | nextcloud | Tailscale | File sync |
| Collabora | nextcloud | Tailscale | Document editing (Nextcloud plugin) |
| Immich | nextcloud | Tailscale | Photo/video management |
| Immich ML | nextcloud | Internal only | Machine learning for Immich (search, faces) |
| PostgreSQL | nextcloud | Internal only | Nextcloud database |
| Immich PostgreSQL | nextcloud | Internal only | Immich database (custom image with vector extensions) |
| Redis | nextcloud | Internal only | Nextcloud cache |
| Immich Redis | nextcloud | Internal only | Immich cache (Valkey) |
| PiHole | pihole | Tailscale | DNS ad-blocking |
| Registry | registry | Tailscale | Docker image registry |
| Radicale | radicale | Tailscale | CalDAV/CardDAV server |

## Namespaces

- **nextcloud** - Nextcloud, Collabora, Immich, and their backing databases/caches. Shares a single service account and Vault role.
- **pihole** - PiHole only. Own service account and Vault role.
- **registry** - Docker Registry only. Own service account and Vault role.
- **radicale** - Radicale only. Own service account and Vault role.

## Service Communication

```
nextcloud ──→ postgres (DB)
          ──→ redis (cache)
          ←──→ collabora (host_aliases for mutual HTTPS, via collabora-internal ClusterIP)

immich ──→ immich-postgres (DB)
       ──→ immich-redis (cache)
       ──→ immich-machine-learning (ML inference, port 3003)

pihole, registry, radicale: standalone, no inter-service dependencies
```

All externally-exposed services follow the same pod pattern: main app container + nginx sidecar (TLS termination) + tailscale sidecar (mesh network access). Secrets are injected from Vault via the CSI secrets store driver.

## File Organization

Each service is split across files by concern:

- `<service>.tf` - Deployment and internal Service
- `<service>-secrets.tf` - Namespace, RBAC, Tailscale auth, TLS certs, Vault secrets, SecretProviderClass
- `<service>-config.tf` - ConfigMaps (nginx config, app config)
- `<service>-pvc.tf` - PersistentVolumeClaims

Supporting files: `postgres.tf`, `redis.tf` (backing stores), `jobs.tf` (post-deploy config jobs).

Nginx configs live in `../data/nginx/<service>.nginx.conf.tpl`. The wait-for-secrets init container script is at `../data/scripts/wait-for-secrets.sh.tpl`.

## Gotchas

**PVCs have `prevent_destroy`**. You must remove the lifecycle block before you can `terraform destroy` any PVC. This is intentional - nextcloud, immich, radicale, and registry data should never be accidentally deleted.

**Registry htpasswd uses `bcrypt()`** with `ignore_changes = [data_json]` on the Vault secret. Terraform won't update the htpasswd on normal applies because bcrypt produces different hashes each run. To update registry users, taint the resource: `terraform taint 'vault_kv_secret_v2.registry_htpasswd'`.

**Jobs use `timestamp()` in names** with `ignore_changes = [metadata[0].name]`. This means each `terraform apply` creates a new job with a new name. Old completed jobs accumulate in the cluster - clean them up periodically with `kubectl delete jobs -n nextcloud --field-selector status.successful=1`.

**Nextcloud image comes from the local registry** (`registry.<domain>/nextcloud:latest`). The image must exist in the registry before deploying. The `registry_pull_secret` in the nextcloud namespace handles auth.

**Collabora and Nextcloud need to talk over HTTPS internally**. The `collabora-internal` ClusterIP service exists specifically so Nextcloud can resolve Collabora's FQDN to an in-cluster IP via `host_aliases`. Don't remove it.

**Radicale auth is generated at pod startup** by an init container that runs `pip install passlib` and creates an htpasswd file. This means radicale startup is slower than other services and requires internet access for pip.

**PiHole's tailscale sidecar has extra capabilities** (`NET_BIND_SERVICE`, `NET_RAW`, `SYS_NICE`, `CHOWN`) beyond the standard `NET_ADMIN` used by other services. This is required for DNS port binding.

## Deployment Order

This deployment depends on three prior deployments (via `terraform_remote_state`):

1. `homelab` - Headscale FQDN, ACME account key, tailnet user map
2. `vault` - Vault deployment
3. `vault-conf` - Vault KV mount path, Kubernetes auth backend
