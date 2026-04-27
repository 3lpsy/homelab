# Security

Posture scanning for the K3s cluster. Local, FOSS-only, runs from any
admin host with kubeconfig access. Reports land in `security/reports/`
(gitignored). Accepted-risk exceptions live in
`security/exceptions/` (committed, public).

## Tooling

[Kubescape](https://kubescape.io/) — CLI-only, Apache 2.0, CNCF. Runs
NSA, MITRE, and CIS framework checks against the cluster. Policy
bundles fetched once from GitHub on first run; no telemetry when
`--submit=false`.

[Trivy](https://trivy.dev/) — Apache 2.0, Aqua Security. Scans the
live cluster for image vulnerabilities, manifest misconfigurations,
embedded secrets in ConfigMaps/manifests, and risky RBAC. Used to
catch what Kubescape's framework checks don't (e.g. an embedded
credential in a freshly-added ConfigMap, or a CVE in a sidecar image).

Both run via Podman so nothing has to be installed on the admin host.

## Scan workflow

Run from this directory:

```bash
cd security/
./kubescape.sh   # framework posture
./trivy.sh       # vulns + misconfigs + secret detection + RBAC
```

Both scripts share the same shape: flatten `$KUBECONFIG` to a tempfile,
run the scanner via Podman with the kubeconfig mounted RO and
`security/reports/` mounted RW, derive a Markdown summary from the
JSON output via `jq`. Output filenames are namespaced per tool so they
don't collide.

### Kubescape outputs (`security/reports/`)

- `report.json` — machine-readable, full detail
- `report.html` — browseable, drill-down per control
- `report.md` — diff-friendly summary table sorted by severity

`./kubescape.sh` runs Kubescape twice (JSON + HTML — the CLI only emits
one format per run), then derives the Markdown.

### Trivy outputs (`security/reports/`)

- `trivy-report.json` — machine-readable, full detail
- `trivy-report.md` — severity counts, top-20 resources by total
  findings, and a dedicated **Secrets detected** table (this is the
  primary signal for "did a credential leak into a ConfigMap?")

Only one scanner pass per run — Trivy can take 10+ min with `vuln`
enabled, so we don't pay that twice. The Markdown summary is derived
from the JSON; if you want a table view, `cat trivy-report.json | jq`
or run `trivy convert --format table trivy-report.json` ad-hoc.

`./trivy.sh` defaults to `--scanners=vuln,misconfig,secret,rbac`,
`--severity=HIGH,CRITICAL`, and `--timeout=2h`. Override per-run via
env:

```bash
TRIVY_SCANNERS=secret,misconfig,rbac ./trivy.sh   # skip image vuln pulls (seconds)
TRIVY_SEVERITY=MEDIUM,HIGH,CRITICAL ./trivy.sh
TRIVY_TIMEOUT=4h ./trivy.sh                       # if 2h still isn't enough
```

A full scan with `vuln` enabled pulls every cluster image and inspects
its layers — expect 10–30 min on first run depending on image count
and registry latency. Subsequent runs reuse `.trivy-cache/`. For
fast "did a credential leak into a ConfigMap?" feedback, drop `vuln`
from the scanner set; the remaining scanners need only the k8s API.

Trivy's vuln database (~500 MB) is cached in `security/.trivy-cache/`
(gitignored). First run pulls it; subsequent runs use the cache.

### Common requirements

Both scripts need `kubectl`, `jq`, `podman` on the admin host, and a
host `$KUBECONFIG` env var pointing at a kubeconfig with cluster
access.

Both run their scanner with a `--userns=keep-id*` Podman flag (Kubescape
maps to its image's nonroot UID 65532; Trivy uses `keep-id` directly
since the image runs as root) and `-e KUBECONFIG=/kc/config` (the
mount target inside the container). Neither uses `--network=host` or
`--add-host` — rootless Podman's default network already routes
through the host's tailscale-aware resolver.

## Exceptions

`security/exceptions/kubescape-exceptions.json` holds findings that
have been triaged and accepted as required by upstream design or
infra constraint. Format is Kubescape's `postureExceptionPolicy`.
Each entry **must** include rationale in this file (below) so the
exception isn't blindly extended later.

YAML is **not supported** by Kubescape's exception parser — only
JSON. The scanner skips an unparseable file with a warning rather
than failing.

### Accepted exceptions

| Control | Resource | Severity | Rationale |
|---------|----------|----------|-----------|
| **C-0057** Privileged container | `nextcloud/Deployment/collabora` | High | Collabora's kit jail (per-document chroot + namespace isolation) requires `SYS_CHROOT`, `SYS_ADMIN`, `FOWNER`, `CHOWN` per [upstream docs](https://sdk.collaboraonline.com/docs/installation/CODE_Docker_image.html). `SYS_ADMIN` triggers C-0057. The cap set is the documented minimum; removing `SYS_ADMIN` forces Collabora into no-jail mode (worse isolation). Pod is tailnet-only — no internet exposure. |
| **C-0012** Apps credentials in configuration files | All `Deployment` and `StatefulSet` cluster-wide | High | Every pod runs a Tailscale sidecar with the env var `TS_KUBE_SECRET` (the *name* of the k8s Secret holding the auth key). The C-0012 rule's `sensitiveKeyNames` list matches on the env-var NAME containing "secret", flagging every pod owner. Real secrets in this repo are always Vault-backed and consumed via `valueFrom.secretKeyRef`, which the rule correctly skips. Trade-off: a future workload with a *real* hardcoded secret env var would also be silenced — mitigated by repo convention (Vault → CSI → secretKeyRef). Includes Vault itself (StatefulSet). |
| **C-0012** Apps credentials in configuration files | All ConfigMaps in `builder` namespace | High | The `builder` namespace holds BuildKit `*-build-context` ConfigMaps that ship Python source code into the build Job. The source legitimately references words like `secret`, `key`, `token`, `jwt`, `bearer` in variable names, docstrings, and env-var references. None contain literal secret values. |
| **C-0012** Apps credentials in configuration files | `vault/ConfigMap/vault-config` | High | The Vault HCL config has `tls_key_file = "/vault/tls/tls.key"` — the parameter NAME contains "key", VALUE is a file path. No secret material in the ConfigMap. |
| **C-0012** Apps credentials in configuration files | `thunderbolt/ConfigMap/thunderbolt-powersync-config` | High | PowerSync `config.yaml` has `client_auth.jwks.keys[0].k: !env PS_JWT_KEY_B64` — actual JWT signing key comes from env (Vault-backed via CSI). Field NAMES like `keys`, `k`, `client_auth`, `audience` trigger the regex; values are env-ref placeholders. |
| **C-0187** Wildcard in Roles/ClusterRoles | `ClusterRoleBinding/cluster-admin` | High | Built-in Kubernetes binding (`system:masters` Group → `cluster-admin` ClusterRole). Auto-created by every K8s control plane; required for kubelet, controller-manager, and the bootstrap admin kubeconfig. Removing it would brick the cluster. |
| **C-0262** Anonymous access enabled | `ClusterRoleBinding/system:public-info-viewer` | High | Built-in Kubernetes binding granting unauthenticated users read on `/version`, `/api`, `/apis`, `/healthz`, `/livez`, `/readyz`, `/openid/v1/jwks`. K8s creates it on every cluster. API server binds to the tailnet IP only (`100.64.0.4:6443`), so anonymous reachability is gated at L4 by tailnet ACLs — no internet exposure. |
| **C-0270 / C-0271** CPU + memory limits not set | `kube-system/Deployment/{coredns, local-path-provisioner, metrics-server}` | High | K3s ships these as bundled HelmCharts under `/var/lib/rancher/k3s/server/manifests/`. Modifying the chart values requires either a `HelmChartConfig` overlay or replacing the bundled manifest — both heavy for a personal homelab. Workloads are well-known and resource usage is bounded in practice. |
| **C-0048 / C-0045** HostPath mount (incl. writable) | Per-resource list (24 Deployments + Vault StatefulSet + 4 DaemonSets + tls-rotator CronJob), see `c-0048-c-0045-hostpath-stable-resources` in the JSON | High | Each listed workload has a documented architectural reason for hostPath: (a) Tailscale sidecar mounts `/dev/net/tun` for kernel-mode WG — required by the per-service tailnet identity boundary, userspace mode rejected for perf; (b) `node-exporter` reads `/proc`+`/sys`+`/`; (c) `otel-collector` reads `/var/log/{pods,containers,journal}` + `/etc/machine-id`; (d) Frigate `/dev/dri` and HomeAssist Z2M Zigbee USB are hardware passthrough; (e) CSI driver DaemonSets need `/var/lib/kubelet/pods` for mount propagation; (f) every PVC backed by `local-path` storage class translates to a hostPath at runtime; (g) tls-rotator CronJob runs the Tailscale init for in-cluster Vault writeback. New workloads must be added explicitly. |
| **C-0048 / C-0045** HostPath mount — ephemeral builder/bootstrap | `kind=Job, namespace=builder`; `kind=Pod, namespace=builder`; `kind=Job, namespace=monitoring` | High | BuildKit image-build Jobs and their worker Pods have hash-suffixed names that rotate per rebuild — per-name entries would rot. All Jobs in `builder/` follow the same kernel-mode tailscale-init + BuildKit-store pattern. The `monitoring` namespace Job exception covers `openobserve-bootstrap-*` (also hash-suffixed). |
| **C-0046** Insecure capabilities (`NET_ADMIN`) | Per-resource list (10 exit-node Deployments + 21 tailscale-sidecar workloads), see `c-0046-net-admin-tailscale-and-wireguard` | High | Kernel-mode Tailscale sidecar requires `NET_ADMIN` to set up the tunnel interface. WireGuard exit-nodes need it for `wg-quick`. Userspace Tailscale and userspace WireGuard rejected (perf + reliability). |
| **C-0057** Privileged container | 10 exit-node Deployments + `kube-system/DaemonSet/csi-secrets-store-secrets-store-csi-driver`, see `c-0057-exit-node-wireguard-and-csi-driver` | High | Exit-node WireGuard container needs `privileged: true` for `wg-quick up` (kernel iface creation, sysctls, ip route add). Caps replacement + sysctl init container is feasible but mid-effort and risk-prone for perf-critical workload. CSI driver is Helm-installed; chart default sets privileged for CSI mount propagation. |
| **C-0038** hostPID/hostIPC | `monitoring/DaemonSet/node-exporter` | High | Required for `/proc/[pid]/*` per-process metrics from the host process tree. Without `hostPID`, node-exporter only sees the (empty) container PID namespace. Standard upstream config. |
| **C-0041** hostNetwork | `monitoring/DaemonSet/node-exporter` | High | Pod IP = node IP makes Prom scrapes hit the host's network stack directly. Also needed for accurate netstat/sockstat collectors. Standard upstream config. |
| **C-0015** List Kubernetes secrets | `ClusterRole/reloader` | High | [Stakater Reloader](https://github.com/stakater/Reloader) watches all Secrets and ConfigMaps cluster-wide; on change it rolls Deployments that mount them via annotation. `list`+`watch` on Secrets is its core feature. |
| **C-0015** List Kubernetes secrets | `ClusterRole/kube-state-metrics` | High | kube-state-metrics exports object metadata as Prom metrics (count, labels, age). It reads Secret metadata only — never `.data`. The `--collectors=secrets` flag is not enabled. |
| **C-0015** List Kubernetes secrets | `ClusterRole/{secretprovidersyncing-role, secretproviderrotation-role}` | High | Installed by the `secrets-store-csi-driver` Helm chart with `syncSecret.enabled=true` and `enableSecretRotation=true` (both required for our Vault → CSI → K8s Secret flow). The driver needs `create`+`list`+`watch` to project mounted secrets back as Kubernetes Secrets and detect external deletion. |
| **C-0015** List Kubernetes secrets | Per-namespace Tailscale Roles (`<svc>-tailscale` × 20), see `c-0015-tailscale-per-namespace-roles` | High | Each Role grants `get/update/patch` on `secrets` **scoped via `resourceNames`** to that service's own state Secret(s) only — cannot read any other Secret. Kubescape's C-0015 rule fires regardless of `resourceNames` scoping, so the scanner can't see the actual tightness. The k8s Secret state backend is Tailscale's recommended pattern; PVC-backed state is non-standard. |
| **C-0015** List Kubernetes secrets | Built-in Kubernetes controllers (`bootstrap-signer`, `token-cleaner`, `generic-garbage-collector`, `namespace-controller`, `resourcequota-controller`, `kube-controller-manager`, `cluster-admin`) | High | Auto-created by K8s itself; required by the control plane. Modifying breaks the cluster. |
| **C-0015** List Kubernetes secrets | `vault-csi/Role/vault-csi-csi-provider-role` | High | Helm chart's RBAC for the Vault CSI provider — reads SecretProviderClass objects + auth tokens to mount Vault secrets into consumer namespaces. Chart-installed; modifying means forking. |
| **C-0030 / C-0260** Ingress/Egress blocked + Missing network policy | 4 `kube-system` workloads (coredns, local-path-provisioner, metrics-server, csi-secrets-store-secrets-store-csi-driver) | Medium | k3s ships these without NetworkPolicies because tight netpols for the control plane are subtle: CoreDNS needs cluster-wide ingress (DNS); metrics-server scrapes kubelet on the host; local-path-provisioner needs kubelet API; CSI driver needs host pod-dir access. Adding netpols here is high-risk for a marginal compliance win. |
| **C-0054** Cluster internal networking | `kube-system` namespace | Medium | Same rationale as C-0030/C-0260 above. The other three system namespaces (`default`, `kube-public`, `kube-node-lease`) get a deny-all NetworkPolicy via `nextcloud/system-namespaces-netpol.tf`. |
| **C-0037** CoreDNS poisoning | Built-in controllers (`system:controller:generic-garbage-collector`, `system:controller:root-ca-cert-publisher`, `cluster-admin`) | Medium | Kubescape flags subjects that can mutate ConfigMaps in `kube-system` (which would let them edit CoreDNS config). All three are built-in K8s controllers/roles required by the control plane. Modifying breaks the cluster. |
| **C-0044** Container hostPort | `monitoring/DaemonSet/node-exporter` | Medium | node-exporter binds 9100 on the node so Prom can scrape it via `<node-ip>:9100`. Standard upstream pattern, paired with `hostNetwork: true` (already exempt under C-0041). |
| **C-0053** Access container service account | All `ServiceAccount`s in `kube-system` | Medium | K8s control-plane SAs (`system:controller:*`, `coredns`, `kube-controller-manager`, `metrics-server`, etc.) — all auto-created by K8s and required by the cluster. Bulk waiver via `namespace=kube-system` because we don't manage any of them. |
| **C-0053** Access container service account | Per-resource list of user-owned ServiceAccounts (27 SAs across `builder`, `exitnode`, `frigate`, `homeassist`, `litellm`, `mcp`, `monitoring`, `nextcloud`, `pihole`, `radicale`, `registry`, `searxng`, `thunderbolt`, `tls-rotator`, `vault`, `vault-csi`) | Medium | Each SA has RBAC bindings for a documented reason: Tailscale state-Secret access, K8s observability (mcp-k8s, kube-state-metrics, reloader, otel-collector), CSI provider, Vault token review, etc. The control fires on the SA → Role binding chain regardless of whether pods automount the token. We've already set `automount_service_account_token = false` on all user-owned SAs, so the actual attack surface is reduced; the scanner can't see that. |

### Adding a new exception

1. Confirm via upstream docs / code that the finding is genuinely
   required, not just inconvenient to fix.
2. Append a new policy object to
   `security/exceptions/kubescape-exceptions.json`. The policy
   matches on resource attributes (namespace + kind + name) and
   one or more control IDs.
3. Add a row to the table above with rationale + upstream citation.
4. Re-scan; the listed control should drop the exempted resource
   from its failure count.

### Removing an exception

If upstream changes (e.g. Collabora switches to bwrap/seccomp and no
longer needs `SYS_ADMIN`), delete the policy object and the table row,
then re-scan to confirm.

## Trivy exceptions

`security/exceptions/.trivyignore` is a newline-separated list of rule
IDs (CVE-*, AVD-*, secret-rule names) that Trivy should suppress.
Same triage rule as Kubescape: only add an entry after confirming the
finding is genuinely required or a verified false positive. Document
the rationale in this file.

### Accepted Trivy exceptions

| Rule ID | Resource | Severity | Rationale |
|---------|----------|----------|-----------|
| _(none yet)_ | | | |

## Reports directory

`security/reports/` is gitignored. Treat reports as snapshots — they
contain resource names and may include cluster details that don't
need to be public. Re-run scans rather than relying on stale files.

## Out of scope (for now)

- **kube-bench** (CIS host-level checks) — not yet wired up.
- **gitleaks** on this repo — not yet wired up.
- **Falco** runtime threat detection — different category, not
  considered here.
