# cloud-engineering-lab

> Cloud-native infrastructure lab: Docker, CI/CD, Kubernetes, Terraform

## Author

[Zsófia Gergely](https://github.com/VitaWeyden)

## About

This repository contains the infrastructure and deployment configuration for two applications built as university projects. The focus is not on the applications themselves, but on building a modern, production-like platform around them using cloud-native technologies.

The goal is to learn and demonstrate real-world DevOps and Cloud Engineering practices: containerization, automated CI/CD pipelines, orchestration, monitoring, and infrastructure as code.

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for real issues hit while building this, including Terraform gotchas, Kubernetes scheduling deadlocks, and how they were diagnosed and fixed.

## Milestones

- [x] Docker Compose orchestration
- [x] GitHub Actions CI/CD pipelines
- [x] GitHub Container Registry image storage
- [x] Monitoring with Prometheus and Grafana
- [x] Kubernetes with K3s via k3d
- [x] Local Terraform deployment
- [ ] Cloud deployment on Google Cloud

## Applications

| Application | Repository | Description |
|---|---|---|
| Violet-board | [VitaWeyden/Violet-board](https://github.com/VitaWeyden/Violet-board) | E-commerce webshop – Laravel, PostgreSQL |
| Echoo | [VitaWeyden/Echoo](https://github.com/VitaWeyden/Echoo) | Chat application – AdonisJS, Vue, PostgreSQL |

## Architecture

```text
GitHub (Violet-board / Echoo)
        │
        │  git push → GitHub Actions
        ▼
GitHub Container Registry (GHCR)
  ghcr.io/vitaweyden/violet-board-app
  ghcr.io/vitaweyden/violet-board-web
  ghcr.io/vitaweyden/echoo-backend
  ghcr.io/vitaweyden/echoo-frontend
        │
        ├── Docker Compose mode
        │     docker compose pull
        │     docker compose up -d
        │
        └── Kubernetes mode
              kubectl apply -f kubernetes/
              or
              python kubernetes/setup.py
```

## Tech Stack

| Layer | Technology |
|---|---|
| Containerization | Docker |
| Orchestration | Docker Compose / Kubernetes (K3s) |
| CI/CD | GitHub Actions |
| Image Registry | GitHub Container Registry (GHCR) |
| Web Server | Nginx |
| Database | PostgreSQL |
| Monitoring | Prometheus, Grafana, Node Exporter, kube-state-metrics |
| Infrastructure as Code | Terraform |
| Cloud Platform | Google Cloud |

## Local port matrix

| Service | Docker Compose | Kubernetes (kubectl) | Terraform |
|---|---:|---:|---:|
| Violet-board (web) | 8100 | 8110 | 8110 |
| Echoo (frontend) | 8101 | 8111 | 8111 |
| Echoo backend (API) | 3334 | 3344 | 3344 |
| Grafana | 3000 | 3010 | 3010 |
| Prometheus | 9090 | 9099 | 9099 |

## Repository Structure

```text
cloud-engineering-lab/
│
├── compose/                        # Docker Compose orchestration
│   ├── docker-compose.yml
│   ├── start.py                    # One-command setup and start script
│   ├── violetboard.env.example
│   ├── echoo.env.example
│   └── monitoring.env.example
│
├── monitoring/                     # Monitoring config for Compose
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasource.yml
│           └── dashboards/
│               └── dashboards.yml
│
├── kubernetes/                     # Kubernetes manifests for local k3d
│   ├── setup.py
│   ├── violetboard/
│   │   ├── db.yaml
│   │   ├── app.yaml
│   │   └── web.yaml
│   ├── echoo/
│   │   ├── db.yaml
│   │   ├── backend.yaml
│   │   └── frontend.yaml
│   └── monitoring/
│       ├── prometheus.yaml
│       ├── grafana.yaml
│       ├── exporters.yaml
│       └── dashboards/
│           └── node-exporter.json
│
├── terraform/                      # Local k3d infrastructure as code
│
├── terraform-gcp/                  # Google Cloud deployment
│
├── TROUBLESHOOTING.md              # Issues, causes, and fixes
└── README.md
```

---

## Option A – Docker Compose

The simplest local option. Kubernetes is not required.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Python 3](https://www.python.org/downloads/)
- [Git](https://git-scm.com/)

### Run

```bash
git clone https://github.com/VitaWeyden/cloud-engineering-lab.git
cd cloud-engineering-lab
python compose/start.py
```

The script automatically:

- creates the required `.env` files;
- generates application secret keys;
- asks for database and Grafana passwords;
- pulls the latest images from GHCR;
- starts all containers.

| Service | URL |
|---|---|
| Violet-board | http://localhost:8100 |
| Echoo | http://localhost:8101 |
| Echoo backend | http://localhost:3334 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

### Update to the latest application images

```bash
cd compose
docker compose pull
docker compose up -d
```

### View logs

```bash
cd compose
docker compose logs -f
```

### Stop

```bash
cd compose
docker compose down
```

### Full reset, including databases

```bash
cd compose
docker compose down -v
```

### Port conflicts

If a port is already in use, edit `compose/docker-compose.yml` and change the host port on the left side:

```yaml
ports:
  - "8100:80"
```

Do not change the container port on the right unless the application itself is also reconfigured.

---

## Option B – Kubernetes with k3d

A production-like local setup using K3s inside Docker through k3d.

### Prerequisites

- Docker Desktop
- Python 3
- Git
- kubectl
- k3d

### Run

```bash
git clone https://github.com/VitaWeyden/cloud-engineering-lab.git
cd cloud-engineering-lab
python kubernetes/setup.py
```

The script automatically:

- creates a k3d cluster with all required ports;
- creates the `violetboard`, `echoo`, and `monitoring` namespaces;
- creates Kubernetes Secrets;
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

### Check pod status

```bash
kubectl get pods --all-namespaces
```

### Update to the latest application images

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

### Stop the cluster and keep data

```bash
k3d cluster stop cloud-engineering-lab
```

### Start the cluster again

```bash
k3d cluster start cloud-engineering-lab
```

### Delete the cluster and all data

```bash
k3d cluster delete cloud-engineering-lab
```

### Kubernetes design notes

**Namespaces** – The cluster is divided into `violetboard`, `echoo`, and `monitoring` namespaces.

**Secrets** – Passwords and application keys are stored as Kubernetes Secrets. The setup script can reuse credentials from the local Compose environment files.

**PersistentVolumeClaims** – The databases, seed markers, Prometheus, and Grafana use persistent storage.

**Terraform** – The local `terraform/` directory is an alternative way to manage the same k3d cluster. Do not run `kubernetes/setup.py` and `terraform apply` against the same cluster because both manage the same resources.

**cAdvisor** – cAdvisor is intentionally excluded from local k3d. It will be added to the Google Cloud VM deployment, where a real Linux host is available.

**Monitoring** – Node Exporter and kube-state-metrics are included. The Node Exporter Full dashboard is provisioned automatically.

---

## Option C – Local Terraform

A declarative alternative to `kubernetes/setup.py`. It creates the same k3d cluster, namespaces, secrets, deployments, and monitoring resources using Terraform.

### Prerequisites

- Everything required by Option B
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5.0 or newer

### Initialize

```bash
cd terraform
terraform init
```

### First deployment

If the cluster does not exist yet, create it first:

```bash
terraform apply -target=null_resource.k3d_cluster
terraform apply
```

If the cluster already exists:

```bash
terraform apply
```

| Service | URL |
|---|---|
| Violet-board | http://localhost:8110 |
| Echoo | http://localhost:8111 |
| Echoo backend | http://localhost:3344 |
| Grafana | http://localhost:3010 |
| Prometheus | http://localhost:9099 |

### Show the Grafana password

```bash
terraform output grafana_password
```

### Update to the latest application images

Terraform does not detect when the digest behind an unchanged `:latest` tag changes.

Restart the application deployments manually:

```bash
kubectl rollout restart deployment/violetboard-app -n violetboard
kubectl rollout restart deployment/violetboard-web -n violetboard
kubectl rollout restart deployment/echoo-backend -n echoo
kubectl rollout restart deployment/echoo-frontend -n echoo
```

Check the rollouts:

```bash
kubectl rollout status deployment/violetboard-app -n violetboard
kubectl rollout status deployment/violetboard-web -n violetboard
kubectl rollout status deployment/echoo-backend -n echoo
kubectl rollout status deployment/echoo-frontend -n echoo
```

### Destroy everything

```bash
terraform destroy
```

### Notes

- `terraform.tfstate` contains generated passwords and keys in plain text. Never commit it.
- The current k3d cluster provisioner assumes Windows and PowerShell.
- The kubectl and local Terraform variants manage the same cluster and must be used as alternatives.

---

## Option D – Google Cloud

The Google Cloud deployment will live in the separate `terraform-gcp/` directory.

The planned cloud deployment includes:

- a Google Compute Engine VM;
- firewall rules;
- K3s installation;
- application and monitoring resources;
- persistent storage;
- automatic application image updates;
- optional static IP;
- cost-control safeguards.

This mode is still under development and must be tested on a real Google Cloud project before it is considered complete.

---

## Monitoring

### Grafana dashboards

The Node Exporter Full dashboard, ID `1860`, is provisioned automatically.

Additional dashboards can be imported from:

https://grafana.com/grafana/dashboards/

### Prometheus targets

Docker Compose:

http://localhost:9090/targets

Kubernetes and local Terraform:

http://localhost:9099/targets

Configured targets include:

- Prometheus
- Node Exporter
- kube-state-metrics in Kubernetes modes