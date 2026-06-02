# Look up the bootstrap-created "homelab" org. The zitadel_org / _orgs
# pair targets the legacy /admin/v1 endpoints and 404s on this server;
# the v2-native zitadel_organizations data source hits /v2/organizations
# and supports `is_default = true` so we don't even need to filter by
# name (only one org exists).
data "zitadel_organizations" "homelab" {
  is_default = true
}

# No shared zitadel_project here. Per memory feedback_zitadel_one_project_per_service
# each service onboarded to Zitadel SSO declares its own zitadel_project.<svc> in
# its own services/<svc>.tf file. The org is the only org-level handle that lives
# here.
