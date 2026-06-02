terraform {
  required_providers {
    # TODO(identity): kubernetes 2.38.0 + Terraform 1.12+ resource-identity
    # guard throws "Unexpected Identity Change" on state rows whose stored
    # identity is null (written by a failed/refresh-skipped apply — e.g. the
    # frigate delete+reapply churn). Current stopgap is manual `state rm` +
    # `import <ns>/<name>` to backfill the identity per affected resource.
    # Real fix is FORWARD, not a provider downgrade: bump the Terraform CLI
    # (and provider) to a release where core backfills null->populated
    # identity gracefully instead of erroring, then drop the rm/import dance.
    # Tracking: hashicorp/terraform-provider-aws#44330 (null-identity write).
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = "~> 0.5.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.0"
    }
  }
}
