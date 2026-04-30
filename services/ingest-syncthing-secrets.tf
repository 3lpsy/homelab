resource "kubernetes_service_account" "ingest_syncthing" {
  metadata {
    name      = "syncthing"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_secret" "ingest_syncthing_tailscale_state" {
  metadata {
    name      = "syncthing-tailscale-state"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  type = "Opaque"

  lifecycle {
    ignore_changes = [data, type]
  }
}

resource "kubernetes_role" "ingest_syncthing_tailscale" {
  metadata {
    name      = "syncthing-tailscale"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["syncthing-tailscale-state"]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding" "ingest_syncthing_tailscale" {
  metadata {
    name      = "syncthing-tailscale"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ingest_syncthing_tailscale.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.ingest_syncthing.metadata[0].name
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
}

resource "random_password" "ingest_syncthing_gui" {
  length  = 32
  special = false
}

# Stable Syncthing identity. The Device ID is derived from the cert, so
# generating both here (and persisting in TF state) keeps the cluster's
# identity stable across pod restarts. Without this, the pod's emptyDir
# reset on every restart, syncthing regenerated a fresh cert, and the
# laptop saw a "device wants to connect" prompt every time.
#
# Rotation: `terraform apply -replace=tls_private_key.ingest_syncthing_device`
# changes the Device ID and the laptop will need to re-trust it.
#
# Syncthing accepts ECDSA P-384 (its current default) — RSA also works but
# produces a longer Device ID and slower handshakes.
resource "tls_private_key" "ingest_syncthing_device" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ingest_syncthing_device" {
  private_key_pem = tls_private_key.ingest_syncthing_device.private_key_pem

  subject {
    common_name = "syncthing"
  }

  # Syncthing's own generator uses 20 years; match for parity.
  validity_period_hours = 20 * 365 * 24
  early_renewal_hours   = 0
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

resource "headscale_pre_auth_key" "ingest_syncthing_server" {
  user           = data.terraform_remote_state.homelab.outputs.tailnet_user_map.syncthing_server_user
  reusable       = true
  time_to_expire = "3y"
}

resource "kubernetes_secret" "ingest_syncthing_tailscale_auth" {
  metadata {
    name      = "syncthing-tailscale-auth"
    namespace = kubernetes_namespace.ingest.metadata[0].name
  }
  type = "Opaque"
  data = {
    TS_AUTHKEY = headscale_pre_auth_key.ingest_syncthing_server.key
  }
}

module "ingest-syncthing-tls" {
  source                = "./../templates/infra-tls"
  account_key_pem       = data.terraform_remote_state.homelab.outputs.acme_account_key_pem
  server_domain         = "${var.ingest_syncthing_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
  aws_region            = var.aws_region
  aws_access_key        = var.aws_access_key
  aws_secret_key        = var.aws_secret_key
  recursive_nameservers = var.recursive_nameservers

  providers = { acme = acme }
}

resource "vault_kv_secret_v2" "ingest_syncthing_config" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "syncthing/config"
  data_json = jsonencode({
    gui_password = random_password.ingest_syncthing_gui.result
    device_cert  = tls_self_signed_cert.ingest_syncthing_device.cert_pem
    device_key   = tls_private_key.ingest_syncthing_device.private_key_pem
  })
}

resource "vault_kv_secret_v2" "ingest_syncthing_tls" {
  mount = data.terraform_remote_state.vault_conf.outputs.kv_mount_path
  name  = "syncthing/tls"
  data_json = jsonencode({
    fullchain_pem = module.ingest-syncthing-tls.fullchain_pem
    privkey_pem   = module.ingest-syncthing-tls.privkey_pem
  })

  # tls-rotator owns rotation post-bootstrap.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "ingest_syncthing" {
  name = "syncthing-policy"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/*" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "ingest_syncthing" {
  backend                          = "kubernetes"
  role_name                        = "syncthing"
  bound_service_account_names      = ["syncthing"]
  bound_service_account_namespaces = ["ingest"]
  token_policies                   = [vault_policy.ingest_syncthing.name]
  token_ttl                        = 86400
}

resource "kubernetes_manifest" "ingest_syncthing_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-syncthing"
      namespace = kubernetes_namespace.ingest.metadata[0].name
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "syncthing-secrets"
          type       = "Opaque"
          data = [
            { objectName = "gui_password", key = "gui_password" },
            { objectName = "device_cert", key = "device_cert" },
            { objectName = "device_key", key = "device_key" },
          ]
        },
        {
          secretName = "syncthing-tls"
          type       = "kubernetes.io/tls"
          data = [
            { objectName = "tls_crt", key = "tls.crt" },
            { objectName = "tls_key", key = "tls.key" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = "syncthing"
        objects = yamlencode([
          {
            objectName = "gui_password"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/config"
            secretKey  = "gui_password"
          },
          {
            objectName = "device_cert"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/config"
            secretKey  = "device_cert"
          },
          {
            objectName = "device_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/config"
            secretKey  = "device_key"
          },
          {
            objectName = "tls_crt"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/tls"
            secretKey  = "fullchain_pem"
          },
          {
            objectName = "tls_key"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/syncthing/tls"
            secretKey  = "privkey_pem"
          },
        ])
      }
    }
  }

  depends_on = [
    kubernetes_namespace.ingest,
    vault_kubernetes_auth_backend_role.ingest_syncthing,
    vault_kv_secret_v2.ingest_syncthing_config,
    vault_kv_secret_v2.ingest_syncthing_tls,
    vault_policy.ingest_syncthing,
  ]
}
