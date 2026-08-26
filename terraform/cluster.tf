variable "cluster_name" {
  description = "Name of the k3d cluster"
  type        = string
  default     = "cloud-lab"
}

resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      k3d cluster list ${var.cluster_name} *> $null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "Cluster '${var.cluster_name}' already exists, skipping"
      } else {
        k3d cluster create ${var.cluster_name} `
          --port 8110:8110@loadbalancer `
          --port 8111:8111@loadbalancer `
          --port 3344:3344@loadbalancer `
          --port 3010:3010@loadbalancer `
          --port 9099:9099@loadbalancer
        if ($LASTEXITCODE -ne 0) { exit 1 }
      }
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-Command"]
    command     = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}