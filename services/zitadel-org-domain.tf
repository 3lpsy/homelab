# Shorten the Zitadel org's primary domain to var.headscale_magic_domain.
#
# Why: with the default policy (zitadel-policies.tf, user_login_must_be_domain
# + validate_org_domains), Zitadel constructs each user's loginname as
# <username>@<org-primary-domain>. With only the auto-generated org domain
# present, that's e.g. jim@homelab.<instance-domain> — long and ugly.
# Adding the headscale magic domain (e.g. hs.magic) as a verified org
# domain and flipping primary lets new users sign in as jim@hs.magic.
#
# Why a Job: the Zitadel TF provider's zitadel_domain resource only adds
# the unverified entry. Domain verification (challenge generation, DNS
# write, ValidateOrgDomain trigger) is not exposed as TF resources. We run
# a one-shot in-cluster Job that wraps those API calls plus a Route53 TXT
# upsert. Keeps the dance reproducible and out of the operator's local env.
#
# Cleanup follow-up: the comment in zitadel-policies.tf:48-53 says this is
# "currently manual" — after first apply, update that comment to point at
# this Job.

locals {
  # Org primary domain. Single source of truth — also feeds the loginname
  # examples in any future docs.
  zitadel_org_short_domain = var.headscale_magic_domain

  # Sentinel mixed into the Job name hash so unrelated pod-spec changes
  # still produce a fresh Job name. Job spec.template is immutable in K8s,
  # so reusing the same name on a template change errors out.
  zitadel_domain_verify_pod_spec_sentinel = "v1,host-aliases-zitadel,csi-vault"

  zitadel_domain_verify_script_hash = substr(sha256(join("\n", [
    file("${path.module}/../data/scripts/zitadel-domain-verify.py"),
    local.zitadel_domain_verify_pod_spec_sentinel,
    local.zitadel_org_short_domain,
  ])), 0, 8)

  zitadel_domain_verify_job_name = "zitadel-domain-verify-${local.zitadel_domain_verify_script_hash}"
}

# Step 1: register the domain on the org. Zitadel creates the unverified
# entry; the Job below flips both is_verified and is_primary server-side
# (the verify-then-primary sequence can't both happen in TF because the
# Zitadel TF provider has no zitadel_domain_validation resource and trying
# to set is_primary on an unverified domain fails).
#
# is_primary is intentionally left as the resource default (false) here —
# the Job mutates it server-side post-verification. ignore_changes prevents
# every subsequent `terraform plan` from showing drift.
resource "zitadel_domain" "short" {
  org_id = data.zitadel_organizations.homelab.ids[0]
  name   = local.zitadel_org_short_domain

  lifecycle {
    ignore_changes = [is_primary]
  }
}

resource "kubernetes_service_account" "zitadel_domain_verify" {
  metadata {
    name      = "zitadel-domain-verify"
    namespace = "oidc"
  }
  automount_service_account_token = true
}

resource "vault_policy" "zitadel_domain_verify" {
  name = "zitadel-domain-verify"

  policy = <<EOT
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/zitadel/tf-provider-pat" {
  capabilities = ["read"]
}
path "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/zitadel/domain-verify" {
  capabilities = ["read"]
}
EOT
}

resource "vault_kubernetes_auth_backend_role" "zitadel_domain_verify" {
  backend                          = "kubernetes"
  role_name                        = "zitadel-domain-verify"
  bound_service_account_names      = [kubernetes_service_account.zitadel_domain_verify.metadata[0].name]
  bound_service_account_namespaces = [kubernetes_service_account.zitadel_domain_verify.metadata[0].namespace]
  token_policies                   = [vault_policy.zitadel_domain_verify.name]
  token_ttl                        = 600
  token_max_ttl                    = 1800
}

# CSI mount + synced k8s Secret so the Job can env_from instead of file
# reads. Mirrors the openobserve-bootstrap pattern.
resource "kubernetes_manifest" "zitadel_domain_verify_secret_provider" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "vault-zitadel-domain-verify"
      namespace = kubernetes_service_account.zitadel_domain_verify.metadata[0].namespace
    }
    spec = {
      provider = "vault"
      secretObjects = [
        {
          secretName = "zitadel-domain-verify"
          type       = "Opaque"
          data = [
            { objectName = "PAT", key = "PAT" },
            { objectName = "AWS_ACCESS_KEY_ID", key = "AWS_ACCESS_KEY_ID" },
            { objectName = "AWS_SECRET_ACCESS_KEY", key = "AWS_SECRET_ACCESS_KEY" },
          ]
        },
      ]
      parameters = {
        vaultAddress = "http://vault.vault.svc.cluster.local:8200"
        roleName     = vault_kubernetes_auth_backend_role.zitadel_domain_verify.role_name
        objects = yamlencode([
          {
            objectName = "PAT"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/zitadel/tf-provider-pat"
            secretKey  = "pat"
          },
          {
            objectName = "AWS_ACCESS_KEY_ID"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/zitadel/domain-verify"
            secretKey  = "aws_access_key_id"
          },
          {
            objectName = "AWS_SECRET_ACCESS_KEY"
            secretPath = "${data.terraform_remote_state.vault_conf.outputs.kv_mount_path}/data/zitadel/domain-verify"
            secretKey  = "aws_secret_access_key"
          },
        ])
      }
    }
  }

  depends_on = [
    vault_kubernetes_auth_backend_role.zitadel_domain_verify,
    vault_policy.zitadel_domain_verify,
  ]
}

resource "kubernetes_config_map" "zitadel_domain_verify_script" {
  metadata {
    name      = "zitadel-domain-verify-script"
    namespace = kubernetes_service_account.zitadel_domain_verify.metadata[0].namespace
  }
  data = {
    "zitadel-domain-verify.py" = file("${path.module}/../data/scripts/zitadel-domain-verify.py")
  }
}

# Step 2: drive the verification end-to-end. Idempotent — re-runs hit the
# early-exit branch when the domain is already verified.
resource "kubernetes_manifest" "zitadel_domain_verify_job" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = local.zitadel_domain_verify_job_name
      namespace = kubernetes_service_account.zitadel_domain_verify.metadata[0].namespace
    }
    spec = {
      backoffLimit = 2
      # No ttlSecondsAfterFinished: name is content-keyed by script hash;
      # finished Jobs stick around so re-applies are no-ops. Old Jobs are
      # orphaned on script change — prune by hand if they accumulate.
      template = {
        metadata = {
          labels = { app = "zitadel-domain-verify" }
        }
        spec = {
          restartPolicy      = "Never"
          serviceAccountName = kubernetes_service_account.zitadel_domain_verify.metadata[0].name

          # Pin oidc.<tailnet> to the in-cluster Zitadel ClusterIP so the
          # script can validate against the LE cert without going through
          # a Tailscale egress sidecar.
          hostAliases = [
            {
              ip = data.terraform_remote_state.vault_conf.outputs.zitadel_cluster_ip
              hostnames = [
                "${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}",
              ]
            },
          ]

          containers = [
            {
              name  = "verify"
              image = var.image_python
              command = ["sh", "-c",
                # Pinned versions — keeps Job behavior stable across pip-index churn.
                "pip install --quiet --no-cache-dir requests==2.32.3 boto3==1.35.99 dnspython==2.7.0 && exec python /scripts/zitadel-domain-verify.py"
              ]
              env = [
                {
                  name  = "ZITADEL_API"
                  value = "https://${data.terraform_remote_state.vault_conf.outputs.zitadel_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
                },
                { name = "DOMAIN", value = local.zitadel_org_short_domain },
                { name = "ROUTE53_ZONE_ID", value = data.terraform_remote_state.homelab.outputs.zitadel_domain_verify_zone_id },
                { name = "AWS_DEFAULT_REGION", value = var.aws_region },
                # Secrets sourced from the synced k8s Secret (Vault CSI).
                {
                  name = "PAT"
                  valueFrom = {
                    secretKeyRef = { name = "zitadel-domain-verify", key = "PAT" }
                  }
                },
                {
                  name = "AWS_ACCESS_KEY_ID"
                  valueFrom = {
                    secretKeyRef = { name = "zitadel-domain-verify", key = "AWS_ACCESS_KEY_ID" }
                  }
                },
                {
                  name = "AWS_SECRET_ACCESS_KEY"
                  valueFrom = {
                    secretKeyRef = { name = "zitadel-domain-verify", key = "AWS_SECRET_ACCESS_KEY" }
                  }
                },
              ]
              volumeMounts = [
                { name = "script", mountPath = "/scripts", readOnly = true },
                { name = "secrets-store", mountPath = "/mnt/secrets", readOnly = true },
              ]
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { cpu = "500m", memory = "256Mi" }
              }
            },
          ]

          volumes = [
            {
              name = "script"
              configMap = {
                name        = kubernetes_config_map.zitadel_domain_verify_script.metadata[0].name
                defaultMode = 493 # 0755
              }
            },
            {
              name = "secrets-store"
              csi = {
                driver   = "secrets-store.csi.k8s.io"
                readOnly = true
                volumeAttributes = {
                  secretProviderClass = "vault-zitadel-domain-verify"
                }
              }
            },
          ]
        }
      }
    }
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.template.metadata.labels",
    "spec.selector",
  ]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    zitadel_domain.short,
    kubernetes_manifest.zitadel_domain_verify_secret_provider,
    kubernetes_config_map.zitadel_domain_verify_script,
    # Baseline must exist before the Job pod starts, so its egress
    # rules (intra-ns to zitadel, kube-dns, internet to Route53 + NS)
    # are in force from the first packet. Skips the race where Job
    # starts under no-policy and gets locked out mid-flight when the
    # baseline lands.
    module.oidc_netpol_baseline,
  ]
}

# Primary-flip is owned by the Job (calls SetPrimaryOrgDomain after the
# domain becomes verified). No second TF resource — a duplicate
# zitadel_domain with same (org_id, name) collides on the upstream
# AddOrgDomain call.
