resource "kubernetes_config_map" "thunderbolt_nginx_config" {
  metadata {
    name      = "thunderbolt-nginx-config"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  data = {
    "nginx.conf" = templatefile("${path.module}/../data/nginx/thunderbolt.nginx.conf.tpl", {
      server_domain = local.thunderbolt_fqdn
    })
  }
}

resource "kubernetes_config_map" "thunderbolt_postgres_init" {
  metadata {
    name      = "thunderbolt-postgres-init"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  data = {
    "01-powersync.sql" = templatefile("${path.module}/../data/thunderbolt/postgres-init.sql.tpl", {
      powersync_role_password = random_password.thunderbolt_powersync_role.result
      keycloak_db_password    = random_password.thunderbolt_keycloak_db.result
    })
  }
}

resource "kubernetes_config_map" "thunderbolt_powersync_config" {
  metadata {
    name      = "thunderbolt-powersync-config"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  data = {
    "config.yaml" = templatefile("${path.module}/../data/thunderbolt/powersync-config.yaml.tpl", {
      powersync_role_password  = random_password.thunderbolt_powersync_role.result
      powersync_jwt_secret_b64 = base64encode(random_password.thunderbolt_powersync_jwt_secret.result)
      powersync_jwt_kid        = "thunderbolt-powersync"
    })
  }
}

resource "kubernetes_config_map" "thunderbolt_keycloak_realm" {
  metadata {
    name      = "thunderbolt-keycloak-realm"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  data = {
    "thunderbolt-realm.json" = templatefile("${path.module}/../data/thunderbolt/keycloak-realm.json.tpl", {
      oidc_client_secret = random_password.thunderbolt_oidc_client_secret.result
      admin_email        = local.thunderbolt_admin_email
      seed_user_password = random_password.thunderbolt_seed_user.result
      public_url         = local.thunderbolt_public_url
    })
  }
}
