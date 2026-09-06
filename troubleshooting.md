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