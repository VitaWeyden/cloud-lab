# ── Violet-board: database ──────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "violetboard_db" {
  # k3d's default StorageClass ("local-path") uses WaitForFirstConsumer
  # binding - the PVC only becomes Bound once a Pod actually mounts it. If
  # Terraform waited for Bound here, it would deadlock (no Pod exists yet).
  wait_until_bound = false

  metadata {
    name      = "violetboard-db-pvc"
    namespace = "violetboard"
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_deployment_v1" "violetboard_db" {
  metadata {
    name      = "violetboard-db"
    namespace = "violetboard"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "violetboard-db"
      }
    }

    template {
      metadata {
        labels = {
          app = "violetboard-db"
        }
      }

      spec {
        container {
          name  = "violetboard-db"
          image = "postgres:15-alpine"

          port {
            container_port = 5432
          }

          env {
            name  = "POSTGRES_DB"
            value = "violetboard"
          }

          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }

          env {
            name = "POSTGRES_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.violetboard.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }

          volume_mount {
            name       = "pgdata"
            mount_path = "/var/lib/postgresql/data"
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }

            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }

            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        volume {
          name = "pgdata"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.violetboard_db.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.violetboard]
}

resource "kubernetes_service_v1" "violetboard_db" {
  metadata {
    name      = "violetboard-db"
    namespace = "violetboard"
  }

  spec {
    selector = {
      app = "violetboard-db"
    }

    port {
      port        = 5432
      target_port = 5432
    }
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Violet-board: app (PHP-FPM) ─────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "violetboard_seeded" {
  wait_until_bound = false

  metadata {
    name      = "violetboard-seeded-pvc"
    namespace = "violetboard"
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Mi"
      }
    }
  }

  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_deployment_v1" "violetboard_app" {
  metadata {
    name      = "violetboard-app"
    namespace = "violetboard"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "violetboard-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "violetboard-app"
        }
      }

      spec {
        init_container {
          name    = "wait-for-db"
          image   = "postgres:15-alpine"
          command = ["sh", "-c", "until pg_isready -h violetboard-db -U postgres; do echo waiting for db; sleep 2; done"]
        }

        container {
          name              = "violetboard-app"
          image             = "ghcr.io/vitaweyden/violet-board-app:latest"
          image_pull_policy = "Always"

          port {
            container_port = 9000
          }

          env {
            name  = "APP_ENV"
            value = "production"
          }

          env {
            name  = "APP_URL"
            value = "http://localhost:8110"
          }

          env {
            name  = "DB_CONNECTION"
            value = "pgsql"
          }

          env {
            name  = "DB_HOST"
            value = "violetboard-db"
          }

          env {
            name  = "DB_PORT"
            value = "5432"
          }

          env {
            name  = "DB_DATABASE"
            value = "violetboard"
          }

          env {
            name  = "DB_USERNAME"
            value = "postgres"
          }

          env {
            name = "DB_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.violetboard.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }

          env {
            name = "APP_KEY"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.violetboard.metadata[0].name
                key  = "APP_KEY"
              }
            }
          }

          volume_mount {
            name       = "seed-marker"
            mount_path = "/var/www/.seed-marker"
          }
        }

        volume {
          name = "seed-marker"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.violetboard_seeded.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.violetboard,
    kubernetes_deployment_v1.violetboard_db,
  ]
}

resource "kubernetes_service_v1" "violetboard_app" {
  metadata {
    name      = "app"
    namespace = "violetboard"
  }

  spec {
    selector = {
      app = "violetboard-app"
    }

    port {
      port        = 9000
      target_port = 9000
    }
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Violet-board: web (Nginx) ────────────────────────────────────────────

resource "kubernetes_deployment_v1" "violetboard_web" {
  metadata {
    name      = "violetboard-web"
    namespace = "violetboard"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "violetboard-web"
      }
    }

    template {
      metadata {
        labels = {
          app = "violetboard-web"
        }
      }

      spec {
        container {
          name              = "violetboard-web"
          image             = "ghcr.io/vitaweyden/violet-board-web:latest"
          image_pull_policy = "Always"

          port {
            container_port = 80
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_service_v1" "violetboard_web" {
  metadata {
    name      = "violetboard-web"
    namespace = "violetboard"
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "violetboard-web"
    }

    port {
      port        = 8110
      target_port = 80
    }
  }

  depends_on = [kubernetes_namespace.this]
}