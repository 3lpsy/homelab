resource "helm_release" "secrets_store_csi_driver" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

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

  set {
    name  = "csi.daemonSet.providersDir"
    value = "/etc/kubernetes/secrets-store-csi-providers"
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
