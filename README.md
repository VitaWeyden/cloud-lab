# cloud-lab

> Cloud-native infrastructure lab: Docker, CI/CD, Kubernetes, Terraform

## Author

[Zsófia Gergely](https://github.com/VitaWeyden)

## About

This repository contains the infrastructure and deployment configuration for two applications built as university projects. The focus is not on the applications themselves, but on building a modern, production-like platform around them using cloud-native technologies.

The goal is to learn and demonstrate real-world DevOps and Cloud Engineering practices: containerization, automated CI/CD pipelines, orchestration, monitoring, and infrastructure as code.

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for real issues hit while building this, including Terraform gotchas, Kubernetes scheduling deadlocks, and how they were diagnosed and fixed.

### How the four approaches relate to each other

Each approach can run entirely on its own, but they're deliberately layered so each one builds conceptually on the previous:

```text
Docker Compose   → the 2 applications only, plain containers, no orchestration
      │
      ▼
Kubernetes       → same 2 applications, now orchestrated, + monitoring added
      │
      ▼
Terraform        → the same Kubernetes + monitoring setup, declared as code
```

`terraform-gcp/` is the exception: it's a fully independent track that deploys everything to a real Google Cloud VM, rather than a layer on top of the local k3d setups above.

Monitoring is intentionally **not** part of the Docker Compose setup — it's introduced starting at the Kubernetes layer, since Prometheus/Grafana/kube-state-metrics are a more natural fit once there's an orchestrator to observe.

## CI/CD pipeline

The CI/CD pipeline itself lives in the two application repositories, not here — [Violet-board](https://github.com/VitaWeyden/Violet-board) and [Echoo](https://github.com/VitaWeyden/Echoo) each have their own GitHub Actions workflow.

**What's automated (CI):** on every push to `main`, GitHub Actions builds a Docker image for each application component and pushes it to GHCR tagged `latest` — no manual build or push step anywhere.

**What's not automated (CD) outside the GCP layer:** Compose, Kubernetes (local k3d), and local Terraform all still need a manual pull + restart:

```bash
# Docker Compose
docker compose pull && docker compose up -d

# Kubernetes / Terraform (kubectl works against both)
kubectl rollout restart deployment/violetboard-app -n violetboard
```

See each approach's own README for the exact commands.

**The exception is the [Google Cloud layer](./terraform-gcp/README.md#automatic-redeployment):** it runs [Keel](https://keel.sh), which polls GHCR and automatically redeploys the moment a new image is pushed — no manual step needed there.

## Documentation

Each approach has its own dedicated README with full setup instructions, ports, and design notes:

| Approach | Layer | Docs |
|---|---|---|
| Docker Compose | Base – 2 applications only | [compose/README.md](./compose/README.md) |
| Kubernetes (k3d) | + monitoring | [kubernetes/README.md](./kubernetes/README.md) |
| Local Terraform | Same as Kubernetes, declarative | [terraform/README.md](./terraform/README.md) |
| Terraform (Google Cloud) | Independent | [terraform-gcp/README.md](./terraform-gcp/README.md) |

## Milestones

- [x] Docker Compose orchestration
- [x] GitHub Actions CI/CD pipelines
- [x] GitHub Container Registry image storage
- [x] Monitoring with Prometheus and Grafana
- [x] Kubernetes with K3s via k3d
- [x] Local Terraform deployment
- [x] Cloud deployment on Google Cloud

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
        ├── Docker Compose (apps only)
        │     docker compose pull
        │     docker compose up -d
        │
        └── Kubernetes (apps + monitoring)
              kubectl apply -f kubernetes/
              or
              python kubernetes/setup.py
                    │
                    └── Terraform (same, declarative)
                          terraform apply
```

## Tech Stack

| Layer | Technology |
|---|---|
| Containerization | Docker |
| Orchestration | Docker Compose / Kubernetes (K3s) |
| CI/CD | GitHub Actions |
| Automatic redeployment (GCP only) | Keel |
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

Monitoring only exists starting from the Kubernetes layer:

| Service | Kubernetes (kubectl) | Terraform |
|---|---:|---:|
| Grafana | 3010 | 3010 |
| Prometheus | 9099 | 9099 |

Full details, including per-service setup and troubleshooting, live in each approach's own README (see [Documentation](#documentation) above).

## Repository Structure

```text
cloud-lab/
│
├── compose/                        # Docker Compose orchestration (apps only, no monitoring)
│   ├── README.md
│   ├── docker-compose.yml
│   ├── start.py                    # One-command setup and start script
│   ├── violetboard.env.example
│   └── echoo.env.example
│
├── kubernetes/                     # Kubernetes manifests for local k3d (apps + monitoring)
│   ├── README.md
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
│   └── README.md
│
├── terraform-gcp/                  # Google Cloud deployment (independent, in progress)
│   └── README.md
│
├── TROUBLESHOOTING.md              # Issues, causes, and fixes
└── README.md
```