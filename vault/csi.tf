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

  depends_on = [
    helm_release.secrets_store_csi_driver,
    kubernetes_namespace.vault
  ]
}
