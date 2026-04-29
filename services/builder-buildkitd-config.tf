# Shared `buildkitd.toml` for every BuildKit Job in the `builder` namespace.
# Mounted at /home/user/.config/buildkit/buildkitd.toml (the rootless image's
# default config search path) by templates/buildkit-job, so every Dockerfile
# `FROM` line auto-routes through the in-cluster pull-through caches.
#
# BuildKit does not honor containerd's /etc/rancher/k3s/registries.yaml — it
# has its own registry pipeline. Without these mirror entries, base images on
# `FROM` lines are pulled direct from upstream, bypassing the proxies.
# Shared inputs threaded into every templates/buildkit-job module call.
# Build once, pass as `shared = local.buildkit_job_shared` from each
# *-jobs.tf so call-sites stay one-screen-readable.
locals {
  buildkit_job_shared = {
    builder_namespace                  = kubernetes_namespace.builder.metadata[0].name
    builder_service_account            = kubernetes_service_account.builder.metadata[0].name
    builder_registry_pull_secret       = kubernetes_secret.builder_registry_pull_secret.metadata[0].name
    builder_buildkitd_config_configmap = kubernetes_config_map.builder_buildkitd_config.metadata[0].name
    # Each Job pod uses host_aliases to pin every registry FQDN to the
    # corresponding in-cluster Service ClusterIP. The buildkitd.toml
    # mirrors below still reference the FQDN form (BuildKit's resolver
    # validates against the cert SAN, not the hostname-as-IP), so the
    # FQDN must resolve to a TLS-terminating endpoint that presents the
    # FQDN cert — that's the nginx sidecar in each registry pod.
    registry_fqdn                = local.thunderbolt_registry
    registry_cluster_ip          = kubernetes_service.registry.spec[0].cluster_ip
    registry_dockerio_fqdn       = "${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    registry_dockerio_cluster_ip = kubernetes_service.registry_dockerio.spec[0].cluster_ip
    registry_ghcrio_fqdn         = "${var.registry_ghcrio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
    registry_ghcrio_cluster_ip   = kubernetes_service.registry_ghcrio.spec[0].cluster_ip
    # Pinned to avoid silent SHA drift on `:rootless`/`:latest`. Bump
    # deliberately when upgrading; remember to bump pod_spec_sentinel in
    # templates/buildkit-job/main.tf so existing Jobs recreate.
    image_buildkit = "moby/buildkit:v0.29.0-rootless"
    # Diagnostic flag — flip to true (and bump the pod_spec_sentinel) when
    # investigating a build wedge to capture buildkitd resolver internals.
    # Currently ON: chasing a non-deterministic wedge where step #2
    # `[load metadata]` or step #7 `importing cache manifest` stalls for
    # minutes despite the registry serving the request immediately.
    buildkit_debug = true
  }
}

resource "kubernetes_config_map" "builder_buildkitd_config" {
  metadata {
    name      = "buildkitd-config"
    namespace = kubernetes_namespace.builder.metadata[0].name
  }

  data = {
    "buildkitd.toml" = <<-EOT
      # pprof endpoint for live goroutine inspection on wedged builds.
      # Reach via `kubectl exec <pod> -c buildkit -- wget -qO -
      # http://127.0.0.1:6060/debug/pprof/goroutine?debug=2`. Loopback only
      # (no exposure outside the pod). buildctl-daemonless.sh swallows
      # buildkitd's stderr so --debug logs are invisible — pprof is the
      # only reliable way to see what the resolver is stuck on.
      [grpc]
        debugAddress = "127.0.0.1:6060"

      [registry."docker.io"]
        mirrors = ["${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]

      # docker.io resolves to registry-1.docker.io under the hood. BuildKit's
      # containerd-resolver dials the canonical hostname directly during
      # multi-arch manifest resolution despite the docker.io mirror entry
      # above — this redirects that path through the same in-cluster proxy.
      # Without it the resolver hangs ~900s on each build (Go containerd-
      # resolver default RequestTimeout) before falling back to mirror data.
      [registry."registry-1.docker.io"]
        mirrors = ["${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]

      [registry."ghcr.io"]
        mirrors = ["${var.registry_ghcrio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]

      [registry."${var.registry_dockerio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        http = false
        insecure = false

      [registry."${var.registry_ghcrio_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"]
        http = false
        insecure = false
    EOT
  }
}
