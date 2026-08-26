# Troubleshooting & Lessons Learned

Issues hit while building and testing the Terraform path (`terraform/`), and what caused them. Kept here because they're useful DevOps/Kubernetes lessons on their own, not just bugs to forget about.

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

**Cause:** the Prometheus `Service`'s `port` field is used both for the external LoadBalancer port and for in-cluster DNS access. After changing it (to avoid a host-port clash with the Compose stack), the Grafana datasource ConfigMap still pointed at the old internal port (`http://prometheus:9090` instead of `:9099`).

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