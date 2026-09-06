provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

provider "kubernetes" {
  config_path = "${path.module}/kubeconfig-gcp.yaml"
}