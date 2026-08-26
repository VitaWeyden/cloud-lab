resource "google_compute_firewall" "allow_ssh" {
  name    = "cloud-lab-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_k3s_api" {
  name    = "cloud-lab-allow-k3s-api"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "allow_app_ports" {
  name    = "cloud-lab-allow-app-ports"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["8110", "8111", "3344", "3010", "9099"]
  }

  source_ranges = ["0.0.0.0/0"]
}