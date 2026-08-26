# Docker Compose

The base layer of **cloud-lab**: just the two applications running as plain Docker containers, no orchestrator, no monitoring stack. See the [root README](../README.md#how-the-four-approaches-relate-to-each-other) for how this fits with the other three approaches.

Kubernetes is not required for this option.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Python 3](https://www.python.org/downloads/)
- [Git](https://git-scm.com/)

## Run

```bash
git clone https://github.com/VitaWeyden/cloud-lab.git
cd cloud-lab
python compose/start.py
```

The script automatically:

- creates the required `.env` files from the `.env.example` templates;
- generates application secret keys (`APP_KEY`);
- asks for a database password for each application;
- pulls the latest images from GHCR;
- starts all containers.

| Service | URL |
|---|---|
| Violet-board | http://localhost:8100 |
| Echoo | http://localhost:8101 |
| Echoo backend | http://localhost:3334 |

## Update to the latest application images

```bash
cd compose
docker compose pull
docker compose up -d
```

## View logs

```bash
cd compose
docker compose logs -f
```

## Stop

```bash
cd compose
docker compose down
```

## Full reset, including databases

```bash
cd compose
docker compose down -v
```

## Port conflicts

If a port is already in use, edit `docker-compose.yml` and change the host port on the left side:

```yaml
ports:
  - "8100:80"
```

Do not change the container port on the right unless the application itself is also reconfigured.

## Design notes

- `docker-compose.yml` does not build any images — it only pulls pre-built images from GHCR. Images are built and pushed automatically by GitHub Actions in each application's own repository.
- The `violetboard-app` service is given the network alias `app` (in addition to its real service name) so it matches the `fastcgi_pass` directive baked into the Violet-board Nginx config — the same reason the equivalent Kubernetes Service is literally named `app` (see [kubernetes/README.md](../kubernetes/README.md)).
- Each app's Postgres container has a `pg_isready` healthcheck, and the app container waits on `condition: service_healthy` before starting — this is the Compose equivalent of the `wait-for-db` init container used in the Kubernetes manifests.
- There is intentionally no monitoring here (no Prometheus, Grafana, cAdvisor, or Node Exporter). That's introduced starting from the [Kubernetes](../kubernetes/README.md) layer.

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for issues hit while building this project.