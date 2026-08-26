# Kubernetes with k3d

A production-like local setup using K3s inside Docker through [k3d](https://k3d.io/). Builds on top of [Docker Compose](../compose/README.md): same two applications, now orchestrated, with a monitoring stack added on top. See the [root README](../README.md#how-the-four-approaches-relate-to-each-other) for how this fits with the other three approaches.

## Prerequisites

- Docker Desktop
- Python 3
- Git
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [k3d](https://k3d.io/#installation)

## Run

```bash
git clone https://github.com/VitaWeyden/cloud-lab.git
cd cloud-lab
python kubernetes/setup.py
```

The script automatically:

- creates a k3d cluster with all required ports forwarded;
- creates the `violetboard`, `echoo`, and `monitoring` namespaces;
- creates Kubernetes Secrets (reusing credentials from the local Compose `.env` files if they already exist, otherwise prompting for new ones);
- creates the Grafana dashboard ConfigMap;
- applies all Kubernetes manifests.

| Service | URL |
|---|---|
| Violet-board | http://localhost:8110 |
| Echoo | http://localhost:8111 |
| Echoo backend | http://localhost:3344 |
| Grafana | http://localhost:3010 |
| Prometheus | http://localhost:9099 |

These ports intentionally differ from the Docker Compose ports so Compose and the k3d environment can run at the same time.

## Check pod status

```bash
kubectl get pods --all-namespaces
```

## Update to the latest application images

The application deployments use the `:latest` tag with `imagePullPolicy: Always`.

Restart the four application deployments:

```bash
kubectl rollout restart deployment/violetboard-app -n violetboard
kubectl rollout restart deployment/violetboard-web -n violetboard
kubectl rollout restart deployment/echoo-backend -n echoo
kubectl rollout restart deployment/echoo-frontend -n echoo
```

Check that every rollout completed:

```bash
kubectl rollout status deployment/violetboard-app -n violetboard
kubectl rollout status deployment/violetboard-web -n violetboard
kubectl rollout status deployment/echoo-backend -n echoo
kubectl rollout status deployment/echoo-frontend -n echoo
```

## Stop the cluster and keep data

```bash
k3d cluster stop cloud-lab
```

## Start the cluster again

```bash
k3d cluster start cloud-lab
```

## Delete the cluster and all data

```bash
k3d cluster delete cloud-lab
```

## Design notes

**Namespaces** – The cluster is divided into `violetboard`, `echoo`, and `monitoring` namespaces.

**Secrets** – Passwords and application keys are stored as Kubernetes Secrets. The setup script can reuse credentials from the local Compose environment files for the two applications; the Grafana admin password has no Compose equivalent, so it's always asked for interactively.

**PersistentVolumeClaims** – The databases, seed markers, Prometheus, and Grafana use persistent storage.

**Terraform** – The local [`terraform/`](../terraform/README.md) directory is an alternative, declarative way to manage the same k3d cluster. Do not run `kubernetes/setup.py` and `terraform apply` against the same cluster because both manage the same resources.

**cAdvisor** – cAdvisor is intentionally excluded from local k3d. It's planned for the Google Cloud VM deployment, where a real Linux host is available.

**Monitoring** – Node Exporter and kube-state-metrics are included alongside Prometheus and Grafana. The Node Exporter Full dashboard (Grafana dashboard ID `1860`) is provisioned automatically via a ConfigMap. Additional dashboards can be imported from https://grafana.com/grafana/dashboards/.

Prometheus targets: http://localhost:9099/targets — configured targets are Prometheus (self), Node Exporter, and kube-state-metrics.

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for issues hit while building this project, including a PVC scheduling deadlock and a Grafana datasource port mismatch.