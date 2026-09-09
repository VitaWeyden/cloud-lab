# Terraform – Google Cloud

> ✅ **Successfully deployed** to a real Google Cloud project. Two real bugs were hit and fixed along the way during that first run - a missing `curl` on first boot and a TLS certificate that didn't cover the VM's public IP - both are now fixed directly in `vm.tf`, so a fresh deployment shouldn't need the manual workarounds documented in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) #12 and #13. That said, a completely from-scratch run with the updated script hasn't been separately re-verified yet - if you hit either issue again, the troubleshooting entries have the manual fix too.

Unlike the other three approaches, this one is fully **independent** — it doesn't build on Compose, Kubernetes, or the local Terraform setup. It deploys the same two applications plus monitoring to a real Google Compute Engine VM running k3s. See the [root README](../README.md#how-the-four-approaches-relate-to-each-other) for how this relates to the rest of the project.

## Planned scope

- a Google Compute Engine VM running k3s;
- firewall rules (SSH, k3s API, application ports);
- the same application and monitoring resources as the local Terraform setup;
- persistent storage;
- **automatic application image updates** (see below — this is the one layer of the project where this is actually automatic, not manual);
- an optional static IP;
- cost-control safeguards.

## Prerequisites

- A Google Cloud project with billing enabled
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5.0 or newer
- [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated (`gcloud auth application-default login`)
- An SSH client (Terraform generates the keypair itself — see `vm.tf`)

## Configuration

Copy the example variables file and fill in your own project ID:

```bash
cd terraform-gcp
cp terraform.tfvars.example terraform.tfvars
```

```hcl
project_id = "your-gcp-project-id-here"
```

`terraform.tfvars` is git-ignored — never commit it.

## How it's meant to work

1. `terraform apply` creates the VM (`vm.tf`) and firewall rules (`network.tf`). The VM installs k3s itself via a startup script on first boot.
2. The Kubernetes provider (`providers.tf`) needs a kubeconfig file that only exists *inside* the VM once k3s has finished installing — so a `null_resource` (`kubeconfig.tf`) SSHes in, waits for a `/tmp/k3s-ready` marker file, then copies the kubeconfig out and rewrites its address from `127.0.0.1` to the VM's public IP.
3. Because of that chicken-and-egg dependency (same issue as the local Terraform setup, see [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)), the first apply likely needs to be staged in two steps:
   ```bash
   terraform apply -target=google_compute_instance.k3s -target=null_resource.fetch_kubeconfig
   terraform apply
   ```
4. Namespaces, Secrets, and application/monitoring resources (`namespaces.tf`, `secrets.tf`, `echoo.tf`, `violetboard.tf`, `monitoring.tf`) are then created the same way as in the local Terraform setup, just pointed at the GCP kubeconfig instead of the k3d one.

## Automatic redeployment

Unlike Compose, Kubernetes (local k3d), and local Terraform — where a new image pushed to GHCR needs a manual `docker compose pull` or `kubectl rollout restart` (see the root README's [CI/CD pipeline](../README.md#cicd-pipeline) section) — this layer redeploys automatically.

`auto-deploy.tf` installs [Keel](https://keel.sh), a small Kubernetes-native operator, into its own `keel` namespace. The four application Deployments (`violetboard-app`, `violetboard-web`, `echoo-backend`, `echoo-frontend`) are annotated with `keel.sh/policy: minor` and a poll trigger, so Keel checks GHCR every 3 minutes and rolls the Deployment when a newer version tag appears. The two Postgres Deployments are pinned to `postgres:15-alpine`, so they're intentionally left out of this.

**This relies on real version tags, not `:latest`.** Each app's own CI workflow pushes two tags per build: `latest` (still used by Compose/Kubernetes-local/Terraform-local, which pull it manually) and a monotonically increasing `v0.0.<build number>` (using GitHub Actions' own `github.run_number`). Keel's `minor` policy compares these version numbers directly - this is what actually makes automatic detection possible. Polling for changes to a tag whose *name* never changes (`:latest` always being called `latest`) doesn't work, no matter the Keel policy - see [TROUBLESHOOTING.md #10](../TROUBLESHOOTING.md#10-keel-never-triggers-an-update-when-every-build-is-tagged-latest) for the full story of how this was found.

The four `*_tag` Terraform variables (`echoo_backend_tag`, `echoo_frontend_tag`, `violetboard_app_tag`, `violetboard_web_tag`) only matter for the very first `terraform apply` - they bootstrap the Deployments onto a real version tag Keel can then track forward on its own. Check each image's current tag at its GHCR package page (linked in `terraform.tfvars.example`) if you ever need to re-bootstrap.

No changes to the application repos' own GitHub Actions workflows are needed *after* this initial setup — Keel polls GHCR directly, it doesn't need to be told a new image exists.

Check Keel's own logs if a rollout isn't happening as expected:

```bash
kubectl logs -n keel deployment/keel -f
```

For more detail (every registry call, not just state changes), temporarily enable debug logging:

```bash
kubectl set env deployment/keel -n keel DEBUG=true
```

## Outputs

```bash
terraform output urls               # service URLs, using the VM's public IP
terraform output ssh_command        # ready-to-use SSH command into the VM
terraform output grafana_password   # sensitive - hidden by default
```

## Notes

- All secrets (`gcp-ssh-key.pem`, `kubeconfig-gcp.yaml`, `*.tfstate`, `*.tfvars`) are covered by this folder's own `.gitignore` — never commit them.
- The current provisioners (`vm.tf`, `kubeconfig.tf`) assume Windows + PowerShell + the OpenSSH client built into Windows 10/11.
- The firewall rules in `network.tf` currently open SSH, the k3s API, and all application ports to `0.0.0.0/0` for simplicity. For anything long-lived, restrict `source_ranges` to your own IP instead.
- cAdvisor, which is intentionally skipped in local k3d, is planned for this deployment since a real Linux host is available here.

This mode is still under development and must be tested on a real Google Cloud project before it's considered complete — expect rough edges.