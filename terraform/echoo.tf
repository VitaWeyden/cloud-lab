# ── Echoo: database ───────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "echoo_db" {
  # k3d's default StorageClass ("local-path") uses WaitForFirstConsumer
  # binding - the PVC only becomes Bound once a Pod actually mounts it. If
  # Terraform waited for Bound here, it would deadlock (no Pod exists yet).
  wait_until_bound = false

  metadata {
    name      = "echoo-db-pvc"
    namespace = "echoo"
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

resource "kubernetes_deployment_v1" "echoo_db" {
  metadata {
    name      = "echoo-db"
    namespace = "echoo"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "echoo-db"
      }
    }

    template {
      metadata {
        labels = {
          app = "echoo-db"
        }
      }

      spec {
        container {
          name  = "echoo-db"
          image = "postgres:15-alpine"

          port {
            container_port = 5432
          }

          env {
            name  = "POSTGRES_DB"
            value = "ECHOO"
          }

          env {
            name  = "POSTGRES_USER"
            value = "postgres"
          }

          env {
            name = "POSTGRES_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.echoo.metadata[0].name
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
            claim_name = kubernetes_persistent_volume_claim_v1.echoo_db.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret.echoo]
}

resource "kubernetes_service_v1" "echoo_db" {
  metadata {
    name      = "echoo-db"
    namespace = "echoo"
  }

  spec {
    selector = {
      app = "echoo-db"
    }

    port {
      port        = 5432
      target_port = 5432
    }
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Echoo: backend (AdonisJS) ───────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "echoo_seeded" {
  wait_until_bound = false

  metadata {
    name      = "echoo-seeded-pvc"
    namespace = "echoo"
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

resource "kubernetes_deployment_v1" "echoo_backend" {
  metadata {
    name      = "echoo-backend"
    namespace = "echoo"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "echoo-backend"
      }
    }

    template {
      metadata {
        labels = {
          app = "echoo-backend"
        }
      }

      spec {
        init_container {
          name    = "wait-for-db"
          image   = "postgres:15-alpine"
          command = ["sh", "-c", "until pg_isready -h echoo-db -U postgres; do echo waiting for db; sleep 2; done"]
        }

        container {
          name              = "echoo-backend"
          image             = "ghcr.io/vitaweyden/echoo-backend:latest"
          image_pull_policy = "Always"

          port {
            container_port = 3333
          }

          env {
            name  = "HOST"
            value = "0.0.0.0"
          }

          env {
            name  = "PORT"
            value = "3333"
          }

          env {
            name  = "NODE_ENV"
            value = "production"
          }

          env {
            name  = "LOG_LEVEL"
            value = "info"
          }

          env {
            name  = "DB_HOST"
            value = "echoo-db"
          }

          env {
            name  = "DB_PORT"
            value = "5432"
          }

          env {
            name  = "DB_USER"
            value = "postgres"
          }

          env {
            name  = "DB_DATABASE"
            value = "ECHOO"
          }

          env {
            name = "DB_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.echoo.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }

          env {
            name = "APP_KEY"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.echoo.metadata[0].name
                key  = "APP_KEY"
              }
            }
          }

          volume_mount {
            name       = "seed-marker"
            mount_path = "/app/.seed-marker"
          }
        }

        volume {
          name = "seed-marker"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.echoo_seeded.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.echoo,
    kubernetes_deployment_v1.echoo_db,
  ]
}

resource "kubernetes_service_v1" "echoo_backend" {
  metadata {
    name      = "echoo-backend"
    namespace = "echoo"
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "echoo-backend"
    }

    port {
      port        = 3344
      target_port = 3333
    }
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Echoo: frontend (Quasar PWA) ────────────────────────────────────────

resource "kubernetes_deployment_v1" "echoo_frontend" {
  metadata {
    name      = "echoo-frontend"
    namespace = "echoo"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "echoo-frontend"
      }
    }

    template {
      metadata {
        labels = {
          app = "echoo-frontend"
        }
      }

      spec {
        container {
          name              = "echoo-frontend"
          image             = "ghcr.io/vitaweyden/echoo-frontend:latest"
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

resource "kubernetes_service_v1" "echoo_frontend" {
  metadata {
    name      = "echoo-frontend"
    namespace = "echoo"
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "echoo-frontend"
    }

    port {
      port        = 8111
      target_port = 80
    }
  }

  depends_on = [kubernetes_namespace.this]
}