variable "project_id" {
  description = "Your GCP project ID (from the Cloud Console, e.g. cloud-lab-123456)"
  type        = string
}

variable "region" {
  description = "GCP region to deploy into"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone to deploy into (must be inside the chosen region)"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "VM size. e2-medium = 2 vCPU / 4GB RAM, a reasonable fit for this stack within the free trial credit."
  type        = string
  default     = "e2-medium"
}

variable "ssh_username" {
  description = "Linux username Terraform will create on the VM for SSH access"
  type        = string
  default     = "clouduser"
}