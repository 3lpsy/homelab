
# HaRP Deployment with Docker-in-Docker
resource "kubernetes_deployment" "harp" {
  metadata {
    name      = "appapi-harp"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    # replicas = 1

    selector {
      match_labels = {
        app = "appapi-harp"
      }
    }

    template {
      metadata {
        labels = {
          app = "appapi-harp"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.nextcloud.metadata[0].name
        init_container {
          name  = "wait-for-secrets"
          image = "busybox:latest"

          command = [
            "sh",
            "-c",
            <<-EOT
                  echo 'Waiting for secrets to sync from Vault...'
                  TIMEOUT=300
                  ELAPSED=0
                  until [ -f /mnt/secrets/harp_shared_key ]; do
                    if [ $ELAPSED -ge $TIMEOUT ]; then
                      echo "Timeout waiting for secrets after $${TIMEOUT}s"
                      exit 1
                    fi
                    echo "Still waiting... ($${ELAPSED}s)"
                    sleep 5
                    ELAPSED=$((ELAPSED + 5))
                  done
                  echo 'Secrets synced successfully!'
                  ls -la /mnt/secrets/
                EOT
          ]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }
        }

        # Docker-in-Docker sidecar
        container {
          name  = "dind"
          image = "docker:dind"

          security_context {
            privileged = true
          }

          startup_probe {
            exec {
              command = ["sh", "-c", "test -S /var/run/docker.sock"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
            failure_threshold     = 60
          }



          readiness_probe {
            exec {
              command = ["docker", "info"]
            }
            initial_delay_seconds = 5
            period_seconds        = 2
          }


          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }

          volume_mount {
            name       = "docker-graph-storage"
            mount_path = "/var/lib/docker"
          }

          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }
        }

        # HaRP container
        container {
          name  = "harp"
          image = "ghcr.io/nextcloud/nextcloud-appapi-harp:release"
          command = [
            "sh",
            "-c",
            <<-EOT
                echo 'Waiting for Docker socket...'
                TIMEOUT=120
                ELAPSED=0
                until [ -S /var/run/docker.sock ]; do
                  if [ $ELAPSED -ge $TIMEOUT ]; then
                    echo "Timeout waiting for Docker socket after $${TIMEOUT}s"
                    exit 1
                  fi
                  echo "Still waiting for socket... ($${ELAPSED}s)"
                  sleep 2
                  ELAPSED=$((ELAPSED + 2))
                done
                echo 'Docker socket found!'
                ls -la /var/run/docker.sock
                echo 'Starting HaRP with original entrypoint...'
                exec /usr/local/bin/start.sh
              EOT
          ]
          env {
            name = "HP_SHARED_KEY"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "harp_shared_key"
              }
            }
          }

          env {
            name  = "HP_LOG_LEVEL"
            value = "debug" # Changed from info
          }

          # ADD THIS
          env {
            name  = "HP_VERBOSE_START"
            value = "1"
          }

          env {
            name  = "NC_INSTANCE_URL"
            value = "https://${var.nextcloud_domain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
          }


          port {
            container_port = 8780
            name           = "http"
          }

          port {
            container_port = 8782
            name           = "frp"
          }

          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }



          liveness_probe {
            tcp_socket {
              port = 8780
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            tcp_socket {
              port = 8780
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }

        volume {
          name = "docker-graph-storage"
          empty_dir {}
        }

        volume {
          name = "docker-socket"
          empty_dir {}
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = kubernetes_manifest.nextcloud_secret_provider.manifest.metadata.name
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.nextcloud_secret_provider
  ]
}

# HaRP Service
resource "kubernetes_service" "harp" {
  metadata {
    name      = "appapi-harp"
    namespace = kubernetes_namespace.nextcloud.metadata[0].name
  }

  spec {
    selector = {
      app = "appapi-harp"
    }

    port {
      name        = "http"
      port        = 8780
      target_port = 8780
    }

    port {
      name        = "frp"
      port        = 8782
      target_port = 8782
    }
  }
}
