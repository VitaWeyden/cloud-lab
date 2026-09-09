# ── Automatic redeployment (GCP layer only) ────────────────────────────────
#
# Compose, Kubernetes (local k3d), and local Terraform all require a manual
# `docker compose pull` / `kubectl rollout restart` after a new image is
# pushed to GHCR - see the root README's "CI/CD pipeline" section.
#
# This GCP deployment is the one place where that becomes fully automatic.
# We use Keel (https://keel.sh), a small Kubernetes-native operator that
# polls a registry on a schedule and rolls a Deployment when a newer
# version tag appears. It needs no changes to the application repos' own
# GitHub Actions workflows beyond pushing a real version tag - GHCR is
# simply polled from here.
#
# Only the 4 application Deployments (violetboard-app, violetboard-web,
# echoo-backend, echoo-frontend) are annotated for this - see the
# `keel.sh/policy` annotations added to their `kubernetes_deployment_v1`
# resources in violetboard.tf and echoo.tf. The two Postgres Deployments are
# pinned to `postgres:15-alpine`, so they're intentionally left out.

resource "kubernetes_namespace" "keel" {
  metadata {
    name = "keel"
  }
}

resource "kubernetes_service_account_v1" "keel" {
  metadata {
    name      = "keel"
    namespace = kubernetes_namespace.keel.metadata[0].name
  }
}

# Keel needs to read and patch Deployments across every namespace it watches
# (violetboard, echoo), so this is a ClusterRole rather than a per-namespace
# Role.
resource "kubernetes_cluster_role_v1" "keel" {
  metadata {
    name = "keel"
  }

  rule {
    api_groups = ["apps", "extensions"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }

  # Keel's informers watch these workload types by default regardless of
  # whether the cluster actually has any - without read access here, it
  # logs constant "forbidden" errors trying to list them. This project only
  # has Deployments (see the rule above for the actual update permissions),
  # so these are read-only. See TROUBLESHOOTING.md #11.
  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods", "events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "keel" {
  metadata {
    name = "keel"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.keel.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.keel.metadata[0].name
    namespace = kubernetes_namespace.keel.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "keel" {
  metadata {
    name      = "keel"
    namespace = kubernetes_namespace.keel.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "keel"
      }
    }
    template {
      metadata {
        labels = {
          app = "keel"
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.keel.metadata[0].name

        container {
          name  = "keel"
          image = "keelhq/keel:latest"

          env {
            # Enables the registry-polling trigger. We're not exposing a
            # public webhook endpoint for GHCR/Docker Hub push events, so
            # polling is the simpler, self-contained option here.
            name  = "POLL"
            value = "true"
          }
          env {
            name  = "HELM_PROVIDER"
            value = "false"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_cluster_role_binding_v1.keel]
}