# Generates an SSH keypair so Terraform (not you, by hand) can log into the
# VM later to fetch the k3s kubeconfig. Same "let Terraform generate it"
# philosophy as the DB passwords in terraform/secrets.tf.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Saved locally so the fetch_kubeconfig provisioner (kubeconfig.tf) can use
# it to SSH in. This file never needs to be committed - it's covered by
# terraform/.gitignore's *.tfstate-adjacent rules; add a matching
# .gitignore here too (see the note in the folder listing below).
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
    access_config {} # empty block = give it an ephemeral public IP
  }

  metadata = {
    ssh-keys = "${var.ssh_username}:${tls_private_key.ssh.public_key_openssh}"
  }

  # Runs automatically on first boot (Google-provided cloud-init mechanism).
  # This is what actually installs k3s - Terraform doesn't SSH in to do
  # this part, the VM does it itself as it starts up.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e

    # The minimal Debian 12 cloud image doesn't reliably have curl available
    # yet at this very early boot stage - without this, the script below
    # fails immediately with "command not found" (exit 127), and k3s never
    # gets installed. See TROUBLESHOOTING.md #12.
    apt-get update -y
    apt-get install -y curl

    # k3s only puts its own in-cluster addresses (10.x internal IP,
    # 127.0.0.1, the cluster service IP) into its auto-generated TLS
    # certificate - it has no way to know its own public IP on its own.
    # Without this, connecting to the API server from outside the VM (which
    # is exactly what kubeconfig.tf does, and what Terraform's kubernetes
    # provider needs to do next) fails TLS verification. Ask the VM's own
    # metadata server for its public IP and add it as an extra SAN.
    # See TROUBLESHOOTING.md #13.
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip")

    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --tls-san $EXTERNAL_IP" sh -s - --write-kubeconfig-mode 644

    # Marker file so we know from the outside (via SSH) that this finished -
    # the VM being "RUNNING" only means it booted, not that k3s is ready yet.
    touch /tmp/k3s-ready
  EOT
}