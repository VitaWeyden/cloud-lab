resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/gcp-ssh-key.pem"
  file_permission = "0600"
}

resource "google_compute_instance" "k3s" {
  name         = "cloud-lab"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30 # GB
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    ssh-keys = "${var.ssh_username}:${tls_private_key.ssh.public_key_openssh}"
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    touch /tmp/k3s-ready
  EOT
}