# This is the trickiest part of this whole setup: the Kubernetes provider
# (providers.tf) needs a kubeconfig file that only exists *inside* the VM,
# at /etc/rancher/k3s/k3s.yaml, after k3s has finished installing. This
# resource SSHes in, waits for that to happen, then copies the file out
# and points it at the VM's public IP instead of 127.0.0.1 (the address
# only makes sense from inside the VM itself).
#
# NOTE: this assumes Windows + PowerShell + OpenSSH client (built into
# Windows 10/11 by default - `ssh -V` in PowerShell should show a version).
resource "null_resource" "fetch_kubeconfig" {
  depends_on = [google_compute_instance.k3s, local_file.ssh_private_key]

  triggers = {
    instance_ip = google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $key = "${local_file.ssh_private_key.filename}"
      $user = "${var.ssh_username}"
      $ip = "${google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip}"
      $sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", "-i", $key)

      Write-Host "Waiting for the VM to finish installing k3s (can take a few minutes)..."
      $ready = $false
      for ($i = 0; $i -lt 60; $i++) {
        ssh @sshOpts "$user@$ip" "test -f /tmp/k3s-ready" 2>$null
        if ($LASTEXITCODE -eq 0) {
          $ready = $true
          break
        }
        Start-Sleep -Seconds 10
      }

      if (-not $ready) {
        Write-Error "Timed out waiting for k3s to become ready on the VM."
        exit 1
      }

      Write-Host "k3s is ready, fetching kubeconfig..."
      scp @sshOpts "$user@$ip`:/etc/rancher/k3s/k3s.yaml" "${path.module}/kubeconfig-gcp.yaml"
      if ($LASTEXITCODE -ne 0) { exit 1 }

      (Get-Content "${path.module}/kubeconfig-gcp.yaml") -replace "127.0.0.1", $ip | Set-Content "${path.module}/kubeconfig-gcp.yaml"
      Write-Host "kubeconfig-gcp.yaml written and pointed at $ip"
    EOT
  }
}