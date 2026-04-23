# Mirror of upstream containers/kubernetes-mcp-server pinned for reproducibility.
# Re-tagged into the in-cluster registry so pulls don't depend on ghcr.io reachability.
# Bumping the upstream version: change the tag below; the Dockerfile-hash trigger
# in mcp-k8s-jobs.tf will rebuild.
FROM ghcr.io/containers/kubernetes-mcp-server:v0.0.60

LABEL homelab.mirror="containers/kubernetes-mcp-server"
LABEL homelab.upstream-version="v0.0.60"

# Upstream entrypoint is /app/kubernetes-mcp-server; CMD overridden in the
# Deployment to point --config at the mounted ConfigMap.
