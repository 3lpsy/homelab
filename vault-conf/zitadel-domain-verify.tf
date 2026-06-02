# AWS creds used by the in-cluster Zitadel domain-verify Job (services/zitadel-org-domain.tf).
#
# Source of truth is homelab/zitadel-domain-verify-iam.tf — that deployment
# owns the IAM user, access key, and Route53 policy. We just copy the
# materialized creds into Vault KV so the Job can pull them via CSI without
# the operator ever holding them.
#
# The Zitadel admin PAT used by the Job lives at secret/zitadel/tf-provider-pat,
# already populated by zitadel-pat-sync.tf — reused here, no second PAT minted.

resource "vault_kv_secret_v2" "zitadel_domain_verify" {
  mount = vault_mount.kv.path
  name  = "zitadel/domain-verify"

  data_json = jsonencode({
    aws_access_key_id     = data.terraform_remote_state.homelab.outputs.zitadel_domain_verify_aws_access_key_id
    aws_secret_access_key = data.terraform_remote_state.homelab.outputs.zitadel_domain_verify_aws_secret_access_key
  })
}
