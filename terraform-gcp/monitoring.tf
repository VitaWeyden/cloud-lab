# ── Prometheus ────────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = "monitoring"
  }
  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 15s
        evaluation_interval: 15s

      scrape_configs:
        - job_name: prometheus
          static_configs:
            - targets: ['localhost:9090']

        - job_name: node-exporter
          static_configs:
            - targets: ['node-exporter:9100']

        - job_name: kube-state-metrics
          static_configs:
            - targets: ['kube-state-metrics:8080']
    EOT
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus_data" {
  wait_until_bound = false

  metadata {
    name      = "prometheus-data-pvc"
    namespace = "monitoring"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_deployment_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = "monitoring"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "prometheus"
      }
    }
    template {
      metadata {
        labels = {
          app = "prometheus"
        }
      }
      spec {
        container {
          name  = "prometheus"
          image = "prom/prometheus:latest"
          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=7d",
          ]

          port {
            container_port = 9090
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/prometheus"
          }
          volume_mount {
            name       = "data"
            mount_path = "/prometheus"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.prometheus_config.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.prometheus_data.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_config_map_v1.prometheus_config]
}

resource "kubernetes_service_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = "monitoring"
  }
  spec {
    type = "LoadBalancer" # k3s's built-in ServiceLB + network.tf firewall rule
    selector = {
      app = "prometheus"
    }
    port {
      port        = 9099
      target_port = 9090
    }
  }
  depends_on = [kubernetes_namespace.this]
}

# ── kube-state-metrics (needs RBAC to read cluster objects) ────────────────

resource "kubernetes_service_account_v1" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = "monitoring"
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_cluster_role_v1" "kube_state_metrics" {
  metadata {
    name = "kube-state-metrics"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "pods", "services", "endpoints", "persistentvolumeclaims", "namespaces"]
    verbs      = ["list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "kube_state_metrics" {
  metadata {
    name = "kube-state-metrics"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kube_state_metrics.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kube_state_metrics.metadata[0].name
    namespace = "monitoring"
  }
}

resource "kubernetes_deployment_v1" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = "monitoring"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "kube-state-metrics"
      }
    }
    template {
      metadata {
        labels = {
          app = "kube-state-metrics"
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.kube_state_metrics.metadata[0].name

        container {
          name  = "kube-state-metrics"
          image = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0"

          port {
            name           = "http-metrics"
            container_port = 8080
          }
          port {
            name           = "telemetry"
            container_port = 8081
          }
        }
      }
    }
  }
  depends_on = [kubernetes_cluster_role_binding_v1.kube_state_metrics]
}

resource "kubernetes_service_v1" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = "monitoring"
  }
  spec {
    selector = {
      app = "kube-state-metrics"
    }
    port {
      name        = "http-metrics"
      port        = 8080
      target_port = 8080
    }
    port {
      name        = "telemetry"
      port        = 8081
      target_port = 8081
    }
  }
  depends_on = [kubernetes_namespace.this]
}

# ── Node Exporter (host machine metrics) ────────────────────────────────

resource "kubernetes_deployment_v1" "node_exporter" {
  metadata {
    name      = "node-exporter"
    namespace = "monitoring"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "node-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "node-exporter"
        }
      }
      spec {
        container {
          name  = "node-exporter"
          image = "prom/node-exporter:latest"
          args = [
            "--path.procfs=/host/proc",
            "--path.sysfs=/host/sys",
            "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)",
          ]

          port {
            container_port = 9100
          }

          volume_mount {
            name       = "proc"
            mount_path = "/host/proc"
            read_only  = true
          }
          volume_mount {
            name       = "sys"
            mount_path = "/host/sys"
            read_only  = true
          }
        }

        volume {
          name = "proc"
          host_path {
            path = "/proc"
          }
        }
        volume {
          name = "sys"
          host_path {
            path = "/sys"
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_service_v1" "node_exporter" {
  metadata {
    name      = "node-exporter"
    namespace = "monitoring"
  }
  spec {
    selector = {
      app = "node-exporter"
    }
    port {
      port        = 9100
      target_port = 9100
    }
  }
  depends_on = [kubernetes_namespace.this]
}

# ── Grafana ───────────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "grafana_datasource" {
  metadata {
    name      = "grafana-datasource"
    namespace = "monitoring"
  }
  data = {
    "datasource.yml" = <<-EOT
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus:9099
          isDefault: true
          editable: false
    EOT
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_config_map_v1" "grafana_dashboard_provider" {
  metadata {
    name      = "grafana-dashboard-provider"
    namespace = "monitoring"
  }
  data = {
    "dashboards.yml" = <<-EOT
      apiVersion: 1
      providers:
        - name: default
          type: file
          disableDeletion: false
          updateIntervalSeconds: 30
          options:
            path: /var/lib/grafana/dashboards
    EOT
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = "monitoring"
  }
  data = {
    "node-exporter.json" = file("${path.module}/../kubernetes/monitoring/dashboards/node-exporter.json")
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_persistent_volume_claim_v1" "grafana_data" {
  wait_until_bound = false

  metadata {
    name      = "grafana-data-pvc"
    namespace = "monitoring"
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

resource "kubernetes_deployment_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = "monitoring"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "grafana"
      }
    }
    template {
      metadata {
        labels = {
          app = "grafana"
        }
      }
      spec {
        container {
          name  = "grafana"
          image = "grafana/grafana:latest"

          port {
            container_port = 3000
          }

          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana.metadata[0].name
                key  = "GRAFANA_PASSWORD"
              }
            }
          }
          env {
            name  = "GF_USERS_ALLOW_SIGN_UP"
            value = "false"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/grafana"
          }
          volume_mount {
            name       = "datasource"
            mount_path = "/etc/grafana/provisioning/datasources"
          }
          volume_mount {
            name       = "dashboard-provider"
            mount_path = "/etc/grafana/provisioning/dashboards"
          }
          volume_mount {
            name       = "dashboards"
            mount_path = "/var/lib/grafana/dashboards"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.grafana_data.metadata[0].name
          }
        }
        volume {
          name = "datasource"
          config_map {
            name = kubernetes_config_map_v1.grafana_datasource.metadata[0].name
          }
        }
        volume {
          name = "dashboard-provider"
          config_map {
            name = kubernetes_config_map_v1.grafana_dashboard_provider.metadata[0].name
          }
        }
        volume {
          name = "dashboards"
          config_map {
            name = kubernetes_config_map_v1.grafana_dashboards.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_secret.grafana,
    kubernetes_config_map_v1.grafana_datasource,
    kubernetes_config_map_v1.grafana_dashboard_provider,
    kubernetes_config_map_v1.grafana_dashboards,
  ]
}

resource "kubernetes_service_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = "monitoring"
  }
  spec {
    type = "LoadBalancer" # k3s's built-in ServiceLB + network.tf firewall rule
    selector = {
      app = "grafana"
    }
    port {
      port        = 3010
      target_port = 3000
    }
  }
  depends_on = [kubernetes_namespace.this]
}