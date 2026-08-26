output "vm_external_ip" {
  description = "Public IP address of the VM"
  value       = google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "How to SSH into the VM manually if needed"
  value       = "ssh -i ${local_file.ssh_private_key.filename} ${var.ssh_username}@${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}"
}

output "grafana_password" {
  description = "Login password for the Grafana admin user"
  value       = random_password.grafana.result
  sensitive   = true
}

output "urls" {
  description = "Where to reach each service once everything is up"
  value = {
    violetboard = "http://${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}:8110"
    echoo       = "http://${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}:8111"
    grafana     = "http://${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}:3010"
    prometheus  = "http://${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}:9099"
  }
}