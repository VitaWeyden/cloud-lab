# ── Violet-board ──────────────────────────────────────────────────────────
resource "random_password" "violetboard_db" {
  length  = 24
  special = false
}

resource "random_id" "violetboard_app_key" {
  byte_length = 32
}

resource "kubernetes_secret" "violetboard" {
  metadata {
    name      = "violetboard-secret"
    namespace = "violetboard"
  }

  data = {
    DB_PASSWORD = random_password.violetboard_db.result
    APP_KEY     = "base64:${random_id.violetboard_app_key.b64_std}"
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Echoo ─────────────────────────────────────────────────────────────────
resource "random_password" "echoo_db" {
  length  = 24
  special = false
}

resource "random_id" "echoo_app_key" {
  byte_length = 32
}

resource "kubernetes_secret" "echoo" {
  metadata {
    name      = "echoo-secret"
    namespace = "echoo"
  }

  data = {
    DB_PASSWORD = random_password.echoo_db.result
    APP_KEY     = random_id.echoo_app_key.b64_url
  }

  depends_on = [kubernetes_namespace.this]
}

# ── Monitoring (Grafana) ─────────────────────────────────────────────────
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "kubernetes_secret" "grafana" {
  metadata {
    name      = "grafana-secret"
    namespace = "monitoring"
  }

  data = {
    GRAFANA_PASSWORD = random_password.grafana.result
  }

  depends_on = [kubernetes_namespace.this]
}