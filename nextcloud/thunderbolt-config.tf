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

  # Static shell script — no template interpolation. The script reads the
  # PowerSync + Keycloak DB passwords from /mnt/secrets/* (Vault CSI) at
  # runtime and feeds them to psql via -v variables, so the ConfigMap
  # contains zero credential material.
  data = {
    "01-powersync.sh" = file("${path.module}/../data/thunderbolt/postgres-init.sh")
  }
}

resource "kubernetes_config_map" "thunderbolt_powersync_config" {
  metadata {
    name      = "thunderbolt-powersync-config"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  # Static YAML — no template interpolation. PowerSync resolves
  # !env POWERSYNC_DATABASE_URI and !env POWERSYNC_JWT_KEY_B64 at startup
  # from env vars sourced from the Vault-CSI-synced thunderbolt-secrets
  # k8s Secret. No credential material lands in the ConfigMap.
  data = {
    "config.yaml" = file("${path.module}/../data/thunderbolt/powersync-config.yaml")
  }
}

resource "kubernetes_config_map" "thunderbolt_keycloak_realm" {
  metadata {
    name      = "thunderbolt-keycloak-realm"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }

  # Static placeholder JSON — no template interpolation. The render-realm
  # init container substitutes ${OIDC_CLIENT_SECRET}, ${SEED_USER_PASSWORD},
  # ${ADMIN_EMAIL}, and ${PUBLIC_URL} at startup from env vars sourced via
  # Vault CSI. Keeps the realm credentials out of the ConfigMap (and thus
  # out of Velero backup tarballs in S3).
  data = {
    "thunderbolt-realm.json" = file("${path.module}/../data/thunderbolt/keycloak-realm.json")
  }
}

resource "kubernetes_config_map" "thunderbolt_keycloak_render_script" {
  metadata {
    name      = "thunderbolt-keycloak-render-script"
    namespace = kubernetes_namespace.thunderbolt.metadata[0].name
  }
  data = {
    "render-realm.sh" = file("${path.module}/../data/thunderbolt/render-realm.sh")
  }
}
