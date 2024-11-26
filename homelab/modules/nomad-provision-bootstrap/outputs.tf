output "bootstrap_token" {
  value = random_uuid.nomad_acl_token.result
}
