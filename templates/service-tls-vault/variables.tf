variable "service_name" {
  description = "Logical service name. Drives default Vault path (<service_name>/config, /tls), default k8s Secret names (<service_name>-secrets, <service_name>-tls), default SPC name (vault-<service_name>), default Vault policy + role names."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the SPC is created in and that the Vault role binds to."
  type        = string
}

variable "service_account_name" {
  description = "ServiceAccount the Vault Kubernetes auth role authorizes."
  type        = string
}

# ---- ACME / TLS ------------------------------------------------------------

variable "acme_account_key_pem" {
  description = "ACME account key PEM, typically data.terraform_remote_state.homelab.outputs.acme_account_key_pem."
  type        = string
  sensitive   = true
}

variable "tls_domain" {
  description = "Fully-qualified TLS common name (e.g. grafana.hs.<magic>)."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "aws_access_key" {
  type      = string
  sensitive = true
}

variable "aws_secret_key" {
  type      = string
  sensitive = true
}

variable "recursive_nameservers" {
  type = list(string)
}

# ---- Vault -----------------------------------------------------------------

variable "vault_kv_mount" {
  description = "Vault KV v2 mount path, typically data.terraform_remote_state.vault_conf.outputs.kv_mount_path."
  type        = string
}

variable "vault_kv_path" {
  description = "KV path prefix. Defaults to var.service_name. Resulting Vault paths: <prefix>/config and <prefix>/tls."
  type        = string
  default     = null
}

variable "vault_address" {
  description = "vaultAddress passed to the SecretProviderClass parameters block. Defaults to the in-cluster Service URL."
  type        = string
  default     = "http://vault.vault.svc.cluster.local:8200"
}

variable "config_secrets" {
  description = "Map of secret-key => value. Stored at <vault_kv_path>/config; surfaces in the <service_name>-secrets k8s Secret with one CSI object per key. Empty map skips the config Vault write and omits the <svc>-secrets secretObject (TLS-only services like jellyfin)."
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "token_ttl" {
  description = "Vault Kubernetes auth role token_ttl in seconds."
  type        = number
  default     = 86400
}

# ---- Naming overrides (rarely used) ----------------------------------------

variable "config_secret_name" {
  description = "Override for the k8s Secret holding config values. Default: <service_name>-secrets."
  type        = string
  default     = null
}

variable "tls_secret_name" {
  description = "Override for the k8s Secret holding the TLS cert. Default: <service_name>-tls."
  type        = string
  default     = null
}

variable "spc_name" {
  description = "Override for the SecretProviderClass name. Default: vault-<service_name>."
  type        = string
  default     = null
}

variable "policy_name" {
  description = "Override for the Vault policy name. Default: <service_name>-policy."
  type        = string
  default     = null
}

variable "role_name" {
  description = "Override for the Vault Kubernetes auth role + SPC roleName. Default: <service_name>."
  type        = string
  default     = null
}

variable "manage_vault_auth" {
  description = "Create the Vault policy + Kubernetes auth role inside the module. Set to false when multiple service-tls-vault calls share an externally-managed policy/role (e.g. registry-dockerio + registry-ghcrio sharing `registry-proxy`). When false, role_name must be set to the externally-managed role's name."
  type        = bool
  default     = true
}

variable "extra_config_keys" {
  description = "Additional CSI key→Vault-path mappings injected as keys into the same <svc>-secrets k8s Secret managed by config_secrets. Use when a sibling service in the namespace owns the Vault path (e.g. homeassist's SPC pulls ha_password from homeassist/mosquitto). Values must be readable by this module's roleName policy — for shared-policy patterns set manage_vault_auth=false and ensure the externally-managed policy grants read on each entry's vault_path."
  type = list(object({
    object_name = string
    vault_path  = string
    vault_key   = string
  }))
  default = []
}

variable "extra_secret_objects" {
  description = "Additional secretObjects appended to the SPC. Each becomes a synced k8s Secret. Vault paths must be readable by the SPC roleName's policy. Use for htpasswd, cross-service certs, or any secret outside the standard <vault_kv_path>/{config,tls} pattern."
  type = list(object({
    secret_name = string
    type        = optional(string, "Opaque")
    items = list(object({
      object_name = string
      k8s_key     = string
      vault_path  = string
      vault_key   = string
    }))
  }))
  default = []
}
