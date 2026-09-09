# Troubleshooting & Lessons Learned

Real issues hit while building and testing this project, and what caused them. Kept here because they're useful DevOps/Kubernetes lessons on their own, not just bugs to forget about.

## 1. Kubernetes provider can't connect on a brand-new cluster

**Symptom:** `terraform apply` fails with `context "k3d-cloud-lab" does not exist`, even though the plan shows the cluster will be created.

**Cause:** Terraform configures all providers before running any resource, regardless of `depends_on`. The Kubernetes provider tries to read the kubeconfig context immediately - but that context only gets created by the `null_resource.k3d_cluster` provisioner, which hasn't run yet.

**Fix:** on a fully empty cluster, apply the cluster first, then everything else:
```bash
terraform apply -target=null_resource.k3d_cluster
terraform apply
```
Not needed once the cluster already exists.

## 2. `local-exec` provisioner fails on Windows with a bash-style script

**Symptom:** `'cluster' was unexpected at this time.`

**Cause:** `local-exec` runs via `cmd /C` on Windows by default. A script written in `sh` syntax (`if ...; then ... fi`) is meaningless to `cmd.exe`.

**Fix:** set `interpreter = ["PowerShell", "-Command"]` explicitly and write the script in PowerShell (`if ($LASTEXITCODE -eq 0) { ... } else { ... }`). Not portable to macOS/Linux as-is - would need an `sh` version there.

## 3. PersistentVolumeClaim creation hangs forever, then times out

**Symptom:** `kubernetes_persistent_volume_claim_v1` resources sit at "Still creating..." for 5+ minutes, then fail with `client rate limiter Wait returned an error: context deadline exceeded`.

**Cause:** k3d's default StorageClass (`local-path`) uses `WaitForFirstConsumer` binding - a PVC only becomes `Bound` once a Pod actually mounts it. The Terraform resource waits for `Bound` by default (`wait_until_bound = true`), but the Pod that would consume it hasn't been created yet in the apply order. Deadlock: Terraform waits for something that can only happen after Terraform stops waiting.

**Fix:** `wait_until_bound = false` on every PVC resource. `kubectl apply` never had this problem because it doesn't wait for binding at all.

## 4. Grafana shows "No data" after changing the Prometheus port

**Symptom:** all Grafana dashboards empty, no errors visible in the UI.

**Cause:** the Prometheus `Service`'s `port` field is used both for the external LoadBalancer port and for in-cluster DNS access. After changing it (at the time, to avoid a host-port clash with Docker Compose's own Prometheus - Compose no longer runs a monitoring stack, see the root README), the Grafana datasource ConfigMap still pointed at the old internal port (`http://prometheus:9090` instead of `:9099`).

**Fix:** update the datasource URL to match the current Service port, in both `kubernetes/monitoring/grafana.yaml` and `terraform/monitoring.tf`. Changing a ConfigMap doesn't restart the Pod that reads it - needs `kubectl rollout restart deployment/grafana -n monitoring` afterward.

## 5. Violet-board images broken - fixing `APP_URL` didn't help

**Symptom:** images 404, browser requests something like `http://localhost/img/placeholders/box-01-front.svg` (no port at all).

**Cause, two layers:**
- Violet-board's `ProductSeeder.php` calls Laravel's `asset()` helper **at seed time** and saves the resulting **absolute URL** into the database - not a relative path computed fresh per request.
- The first time the database was seeded in Kubernetes/Terraform mode, `APP_URL` wasn't set yet, so Laravel fell back to its own default (`http://localhost`, no port). That wrong URL got permanently written into the DB rows.

Setting `APP_URL` correctly afterward and restarting the app Pod does nothing for already-seeded data - the PVC keeps the Postgres data (and the wrong URLs) across restarts.

**Fix applied:** delete the DB and seed-marker PVCs and let the app re-seed with the now-correct `APP_URL`. **Better fix (not yet done):** store relative paths in the DB and call `asset()` only when rendering the view, so the URL is always correct regardless of host/port - this is an app-level fix, in the Violet-board repo, not this one.

## 6. Deleting a Terraform-managed PVC with `kubectl` causes a deadlock

**Symptom:** after `kubectl delete pvc ...` followed by `kubectl rollout restart`, the new Pod sits `Pending` forever with `FailedScheduling: persistentvolumeclaim "..." is being deleted. not found`, while the PVC itself is stuck in `Terminating`.

**Cause:** the *old* Pod (from before the restart) was still running and still mounting the PVC, which blocks the PVC's actual deletion (`pvc-protection` finalizer). The Deployment's rolling-update strategy creates the *new* Pod before killing the old one - but the new Pod can't start without the PVC, which can't finish deleting while the old Pod holds it. Neither side can proceed.

**Fix:** manually delete the old Pod (`kubectl delete pod <old-pod-name> -n <namespace>`) to release the PVC, which lets the `Terminating` PVC finish deleting and unblocks everything else.

**Lesson:** don't manage Terraform-owned resources (PVCs, Secrets, Deployments, ...) with direct `kubectl` commands - it desyncs Terraform's state from reality. Go through Terraform (edit the `.tf` file and `apply`, or `terraform destroy -target=...`) instead.

## 7. "Unexpected Identity Change" on `terraform plan`/`apply`

**Symptom:**
```
Error: Unexpected Identity Change: During the read operation, the Terraform Provider
unexpectedly returned a different identity then the previously stored one.
```

**Cause:** an earlier `apply` had partially failed (a Deployment's rollout timed out even though the Deployment itself was created successfully). Terraform's state ended up with an incomplete "identity" record for that resource. On the next refresh, the provider found the real, fully-populated identity in the cluster and flagged the mismatch instead of silently overwriting it.

**Fix:**
```bash
terraform state rm kubernetes_deployment_v1.<name>
terraform import kubernetes_deployment_v1.<name> <namespace>/<name>
```
This only touches Terraform's bookkeeping - the actual Deployment in the cluster is untouched.

## 8. Docker Compose: app container stuck `Restarting`, `password authentication failed`

**Symptom:** after running `compose/start.py`, `docker compose ps` shows an app container (e.g. `violetboard-app`) endlessly `Restarting`. `docker compose logs` shows a Laravel/AdonisJS migration failing with something like:
```
SQLSTATE[08006] ... FATAL: password authentication failed for user "postgres"
```

**Cause:** PostgreSQL only applies `POSTGRES_PASSWORD` the *first* time it initializes an empty data directory. If `violetboard.env`/`echoo.env` gets deleted and regenerated (e.g. by re-running `start.py` after removing the `.env` files, without also removing the Docker volumes), the script asks for and writes a brand-new password - but the `*-pgdata` volume from the earlier run still exists, still containing Postgres initialized with the *old* password. The app connects with the new one and fails.

**Fix:**
```bash
docker compose down -v --remove-orphans
python compose/start.py
```
`-v` drops the Postgres volumes so they get freshly initialized with the new password. `--remove-orphans` also cleans up any containers left over from a since-changed `docker-compose.yml` (for example, from before monitoring was removed from this file - see the root README).

**Now handled proactively:** `compose/start.py` checks for a matching Docker volume whenever an `.env` file needs to be (re)created, and asks:
1. **Keep it as is** - you still know the existing password, just type it in. Nothing is touched.
2. **Keep the data, but set a new password.** No need to know the old one: `docker compose exec` reaches the container's local unix socket, which the official Postgres image trusts without a password, so the script runs `ALTER USER postgres WITH PASSWORD ...` directly. Nothing is deleted.
3. **Start fresh.** Removes only the affected application's database container and its volume(s) (e.g. just `violetboard-db` and its `-pgdata`/`-seeded` volumes) - not the app container, and never the other application - then asks for a brand-new password. The app container is left alone: it either gets recreated automatically by `docker compose up -d` once it detects the changed `.env`, or if it was already crash-looping on the old password, its `restart: unless-stopped` policy retries it as soon as the database is healthy again.

No more discovering this via a crash loop, and no more needing to remember a password from months ago.

## 9. The same bug class in `kubernetes/setup.py` - and a sneakier variant of it

**Symptom:** same as #8, but with a `Secret` and a `PersistentVolumeClaim` instead of an `.env` file and a Docker volume - a database Pod stuck in `CrashLoopBackOff` with a Postgres authentication error, or a `CreateContainerConfigError` if the Secret is missing entirely.

**Cause:** a `Secret` and the `PVC` holding the actual Postgres data are two independently-persisted objects, exactly like an `.env` file and a Docker volume. `create_secret_with_key()` only checked `secret_exists()` before generating/reusing a password - if a Secret was deleted (e.g. `kubectl delete secret violetboard-secret -n violetboard`) while its PVC survived, a fresh Secret got created with a password that doesn't match what's already initialized on disk.

There was also a **sneakier** variant: the function's fallback tries to reuse credentials from the local Compose `.env` file. If that Compose password had since been rotated (for example, via the fix in #8) while the Kubernetes PVC was initialized with the *old* one, the script would print a confident `Found existing credentials ... reusing them` and silently write the *wrong* password into the new Secret - no warning at all until the Pod started crash-looping.

A second, less obvious issue: even after fixing the Secret, Kubernetes only resolves `secretKeyRef` values when a Pod is first created - an already-running (or already crash-looping) application Pod does **not** pick up a Secret change on its own. It needs an explicit `kubectl rollout restart`.

**Fix (now handled proactively):** `create_secret_with_key()` now checks `pvc_exists()` before trusting any password source - reused-from-Compose or freshly typed - and offers the same three options as #8: keep the known password, reset it in place via `kubectl exec deploy/<db> -- psql -U postgres -c "ALTER USER ..."` (works without knowing the old one, since `kubectl exec` reaches the Pod directly rather than over the network), or delete just that app's database Deployment + PVC and start over. All three paths finish with a `kubectl rollout restart` of the *application* Deployment, so it always ends up with a fresh Pod referencing the current Secret value - never a stale one baked in from before.

## 10. Keel never triggers an update when every build is tagged `:latest`

**Symptom:** Keel's logs show its poll job running on schedule (`trigger.poll.RepositoryWatcher: new watch repository tags job added`), with no RBAC or auth errors, but it never actually updates the Deployment even long after a new image was pushed. With `DEBUG=true` set (`kubectl set env deployment/keel -n keel DEBUG=true`), the real reason becomes visible:
```
level=debug msg="registry.tags url=https://ghcr.io/v2/.../tags/list"
level=debug msg="trigger.poll.WatchRepositoryTagsJob: checking tags" current_tag=latest repository_tags="[latest]"
level=debug msg="trigger.poll.WatchRepositoryTagsJob: events: []"
```

**Cause:** this trigger job compares the repository's **list of tag names**, not image digests. Since every build in this project only ever pushed a single tag (`latest`), the tag list Keel sees never changes - `["latest"]` today looks identical to `["latest"]` next week, even though the image *behind* that tag is completely different. Keel has no way to detect "the same name now points somewhere else" through this code path, regardless of the `keel.sh/policy` annotation.

**Fix:** switch to a real versioning scheme instead of relying on `:latest` for change detection. Each app's CI workflow now also pushes a monotonically increasing tag alongside `latest`, using GitHub Actions' own build counter:
```yaml
tags: |
  type=raw,value=latest
  type=raw,value=v0.0.${{ github.run_number }}
```
The `terraform-gcp` Deployments were switched from `image = "...:latest"` to `image = "...:${var.echoo_backend_tag}"` (etc.), bootstrapped with whatever the current real tag is, and the Keel annotation changed from `keel.sh/policy: force` to `keel.sh/policy: minor` - a real semver-style policy that compares version *numbers*, not tag name lists, so it correctly detects that `v0.0.10` is newer than `v0.0.9`. The one-time bootstrap tag only matters for the very first `terraform apply`; every build after that is picked up by Keel on its own.

## 11. Keel logs are full of `forbidden` errors for StatefulSets/DaemonSets/CronJobs

**Symptom:** constant `reflector.go` warnings and `Unhandled Error` entries in the Keel logs, e.g. `statefulsets.apps is forbidden: User "system:serviceaccount:keel:keel" cannot list resource "statefulsets"`.

**Cause:** Keel's Kubernetes provider always watches every workload type it knows about (Deployments, StatefulSets, DaemonSets, CronJobs) regardless of whether the cluster actually has any - it doesn't check first. The `ClusterRole` in `auto-deploy.tf` only granted access to Deployments (the only workload type this project uses), so the other three watchers fail on every list/watch attempt.

**Fix:** added read-only (`get`, `list`, `watch`) rules for `statefulsets`/`daemonsets` (API group `apps`) and `cronjobs` (API group `batch`) to the `keel` ClusterRole. This doesn't change Keel's actual behavior (there's nothing of those types to update), it just stops the log spam - the Deployment-watching path this project actually relies on already had full permissions and was unaffected either way.
## 12. GCP VM never finishes installing k3s - `fetch_kubeconfig` times out after ~10 minutes

**Symptom:** `terraform apply -target=google_compute_instance.k3s -target=null_resource.fetch_kubeconfig` hangs on `null_resource.fetch_kubeconfig: Still creating...` for far longer than the "a few minutes" the script expects, and eventually fails with `Timed out waiting for k3s to become ready on the VM.` SSHing into the VM manually and checking `sudo journalctl -u google-startup-scripts.service` shows:
```
Script "startup-script" failed with error: exit status 127
```

**Cause:** exit status 127 means "command not found". The minimal Debian 12 cloud image doesn't reliably have `curl` available yet at the point the startup script runs (very early in boot) - so the script's first line, `curl -sfL https://get.k3s.io | sh -s -...`, fails before k3s is ever touched. `curl` does show up on the VM shortly after (some background process installs it later), which is what made this confusing to diagnose - checking `which curl` well after boot shows it present, hiding that it wasn't there at the critical moment.

**Fix applied then (one-off, on the already-running VM):** SSH in and run the two startup-script lines manually once `curl` was confirmed present.

**Fix applied now (permanent, for any future VM):** `vm.tf`'s `metadata_startup_script` now runs `apt-get update -y && apt-get install -y curl` before ever calling `curl`, so this can no longer race.

## 13. Terraform can create the namespaces/Secrets, but every `kubernetes_*` resource fails with a TLS certificate error

**Symptom:**
```
Error: Post "https://<VM_PUBLIC_IP>:6443/api/v1/namespaces": tls: failed to verify certificate:
x509: certificate is valid for 10.186.0.2, 10.43.0.1, 127.0.0.1, ::1, not <VM_PUBLIC_IP>
```

**Cause:** k3s auto-generates its API server's TLS certificate at install time, and only includes the addresses it can see about itself: its internal VM IP, the cluster service IP, and loopback. It has no way to know its own public IP - that only exists as a NAT mapping on Google's side, not as an address actually bound to the VM's own network interface. `kubeconfig.tf` fetches the kubeconfig and rewrites it to point at the public IP (since that's the only address reachable from outside the VM) - but the certificate itself still doesn't list that IP as valid, so TLS verification fails the moment Terraform's Kubernetes provider tries to use it.

**Fix applied then (one-off, on the already-running VM):** SSH in, write `/etc/rancher/k3s/config.yaml` with a `tls-san` entry for the VM's public IP, then `sudo systemctl restart k3s` to regenerate the certificate - followed by re-fetching the kubeconfig from the Windows machine, since the old cached copy still referenced the old certificate.

**Fix applied now (permanent, for any future VM):** `vm.tf`'s startup script asks the GCE metadata server for the VM's own public IP (`http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip`) and passes it straight to the k3s installer via `INSTALL_K3S_EXEC="server --tls-san $EXTERNAL_IP"`, so the certificate is correct from the very first boot - no manual restart step needed.

## 14. Echoo registration/WebSocket fails with a network error even after the port fix - CORS rejects the public IP

**Symptom:** after fixing the frontend's wrong backend port (see #10's sibling issue, the `api.ts` port-mapping bug - not itself a `cloud-lab` bug, it's in the Echoo app repo), the browser console still shows `WebSocket connection ... failed` and/or a network error on `POST /auth/register`, now correctly pointed at the right port.

**Cause:** Echoo's backend (`backend/config/cors.ts`) uses a custom origin-matching function that only allows `localhost`/`127.0.0.1` and private (RFC 1918) network ranges (`10.x`, `172.16-31.x`, `192.168.x`). A public GCP VM's IP is a real internet-routable address, not a private one - it matches none of these, so every cross-origin request (including the WebSocket handshake's initial HTTP request) gets rejected by AdonisJS's CORS middleware before it reaches the actual route handler.

**Fix:** `cors.ts` now also accepts an explicit `ALLOWED_ORIGINS` environment variable (comma-separated exact origins), checked before the private-network heuristics. `terraform-gcp/echoo.tf` sets this to the VM's own public IP on port 8111 (Echoo's frontend port) via `google_compute_instance.k3s.network_interface[0].access_config[0].nat_ip`, the same pattern already used for Violet-board's `APP_URL`. Compose and local Kubernetes/Terraform are unaffected - `localhost` and typical LAN IPs already pass the existing private-network checks.

**Note:** like the port-mapping bug, this fix lives in the Echoo app repo (`backend/config/cors.ts`), not in this infrastructure repo - only the `ALLOWED_ORIGINS` value being *passed in* is `cloud-lab`'s responsibility.

## 15. `terraform plan` wants to downgrade an image Keel already auto-updated

**Symptom:** after Keel successfully rolls a Deployment to a newer version tag on its own, the next `terraform plan`/`apply` shows that image field as changing *backwards* - e.g. `echoo-backend:v0.0.10 -> echoo-backend:v0.0.9` - threatening to undo Keel's work.

**Cause:** this is an inherent tension in mixing Terraform (which enforces a fixed, declared state) with an external operator that mutates the same field continuously (Keel). The `echoo_backend_tag` etc. variables in `variables.tf` only ever represented the *bootstrap* tag for the very first apply - Terraform has no way to know Keel has since moved the live Deployment beyond that value, so it treats the older, declared tag as the desired state and plans to restore it.

**Fix (permanent):** each of the 4 application `kubernetes_deployment_v1` resources now has a `lifecycle` block:
```hcl
lifecycle {
  ignore_changes = [spec[0].template[0].spec[0].container[0].image]
}
```
This tells Terraform to never diff or touch that specific field once the resource exists - ownership of the image tag is handed off to Keel permanently after the first apply. The `*_tag` variables now only matter for that first bootstrap; every apply after that (for env vars, Services, RBAC, anything else) leaves whatever image Keel has since rolled out completely untouched, no matter how out of date the variable default becomes.

**Before this fix was in place:** the workaround was to check what's actually running and manually update the tag variables to match before every apply:
```bash
kubectl get pods -n echoo -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```
This is no longer necessary, but the underlying lesson is worth keeping in mind for any future resource where two systems (Terraform and an operator/controller) might manage the same field: decide upfront which one owns it, and use `ignore_changes` (or an equivalent mechanism) to make that explicit rather than discovering the conflict via a plan that wants to move a version backwards.