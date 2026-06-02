resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  # Driver image tag pinned. v1.5.6 = base + Go-stdlib refresh on top of
  # 1.5.5. Stop at 1.5.6; 1.6.0 rewrites the rotation architecture (CSI
  # RequiresRepublish) and requires removing rotation/tokenrequest RBAC.
  set {
    name  = "linux.image.tag"
    value = "v1.5.6"
  }

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  set {
    name  = "enableSecretRotation"
    value = "true"
  }

  set {
    name  = "rotationPollInterval"
    value = "2m"
  }

  # Reduce reconciler log volume — driver still logs warnings/errors.
  set {
    name  = "logVerbosity"
    value = "0"
  }
}

resource "helm_release" "vault_csi_provider" {
  name             = "vault-csi"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  namespace        = "vault-csi"
  create_namespace = true

  set {
    name  = "server.enabled"
    value = "false"
  }

  set {
    name  = "injector.enabled"
    value = "false"
  }

  set {
    name  = "csi.enabled"
    value = "true"
  }

  # Provider image tag pinned. 1.7.1 is dep/base bump on 1.7.0 (alpine 3.23.3
  # base, gRPC + k8s client lib refresh). No behavior change.
  set {
    name  = "csi.image.tag"
    value = "1.7.1"
  }

  set {
    name  = "csi.daemonSet.providersDir"
    value = "/etc/kubernetes/secrets-store-csi-providers"
  }

  # Tolerate ALL taints so the provider DaemonSet runs on every node — same as
  # the secrets-store driver (chart default). Without this, artemis's
  # gpu=true:NoSchedule taint keeps the provider off the node, and any
  # Vault-secret-consuming pod scheduled there (otel-collector, and migrated
  # litellm/thunderbolt/etc.) hangs in ContainerCreating: the node-local driver
  # has no provider socket to call. The provider reaches Vault over the network
  # (vault ClusterIP → vault-0 on delphi), so it does NOT need to be co-located
  # with Vault — it needs to be co-located with the secret CONSUMERS.
  set {
    name  = "csi.pod.tolerations[0].operator"
    value = "Exists"
  }

  # Resource bounds for the vault-csi-provider DaemonSet pods. Idle ~10m CPU /
  # ~30Mi RSS; spikes briefly per CSI mount. Limits cap a runaway provider
  # from starving the node. The pod has two containers (vault-csi-provider +
  # vault-agent sidecar) — both need explicit resources set independently.
  set {
    name  = "csi.resources.requests.cpu"
    value = "20m"
  }
  set {
    name  = "csi.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "csi.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "csi.resources.limits.memory"
    value = "256Mi"
  }
  set {
    name  = "csi.agent.resources.requests.cpu"
    value = "20m"
  }
  set {
    name  = "csi.agent.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "csi.agent.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "csi.agent.resources.limits.memory"
    value = "128Mi"
  }

  depends_on = [
    helm_release.secrets_store_csi_driver,
    kubernetes_namespace.vault
  ]
}
