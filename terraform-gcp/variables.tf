# No default on purpose - this is specific to your GCP account and must
# never be committed to git. Put it in a terraform.tfvars file instead
# (already covered by .gitignore's *.tfvars rule):
#
#   project_id = "cloud-lab-123456"
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

# Initial image tags Terraform deploys with. After this first apply, Keel
# takes over: it tracks new v0.0.X tags pushed by each app's own CI and
# updates the Deployments on its own - these defaults only matter for the
# very first bootstrap, not for staying up to date afterward. They must be
# real, already-published tags (not "latest" - see TROUBLESHOOTING.md #10
# for why Keel can't track a tag that never changes name).
variable "echoo_backend_tag" {
  description = "Initial echoo-backend image tag (e.g. v0.0.9)"
  type        = string
  default     = "v0.0.9"
}

variable "echoo_frontend_tag" {
  description = "Initial echoo-frontend image tag (e.g. v0.0.9)"
  type        = string
  default     = "v0.0.9"
}

variable "violetboard_app_tag" {
  description = "Initial violet-board-app image tag (e.g. v0.0.11)"
  type        = string
  default     = "v0.0.11"
}

variable "violetboard_web_tag" {
  description = "Initial violet-board-web image tag (e.g. v0.0.11)"
  type        = string
  default     = "v0.0.11"
}