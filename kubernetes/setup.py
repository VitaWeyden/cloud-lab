#!/usr/bin/env python3

import os
import shutil
import subprocess
import sys
import secrets
import base64

GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"
CYAN   = "\033[96m"
RESET  = "\033[0m"

def info(msg):    print(f"{CYAN}[•]{RESET} {msg}")
def success(msg): print(f"{GREEN}[✓]{RESET} {msg}")
def warn(msg):    print(f"{YELLOW}[!]{RESET} {msg}")
def error(msg):   print(f"{RED}[✗]{RESET} {msg}")

def run(args, **kwargs):
    """Runs a command from a list of arguments (no shell involved).
    This avoids cmd.exe / PowerShell / bash quoting differences entirely –
    important because passwords may contain special characters."""
    return subprocess.run(args, **kwargs)

def check_prerequisites():
    ok = True
    for tool, install_hint in [
        ("docker", "https://docs.docker.com/get-docker/"),
        ("kubectl", "https://kubernetes.io/docs/tasks/tools/"),
        ("k3d", "https://k3d.io/#installation"),
    ]:
        if shutil.which(tool):
            success(f"{tool} found")
        else:
            error(f"{tool} not found – install it first: {install_hint}")
            ok = False
    return ok

def cluster_exists(name):
    result = run(["k3d", "cluster", "list", name], capture_output=True)
    return result.returncode == 0

def create_cluster(name):
    if cluster_exists(name):
        success(f"Cluster '{name}' already exists, skipping")
        return True

    warn(f"Cluster '{name}' not found – creating...")
    args = [
        "k3d", "cluster", "create", name,
        "--port", "8110:8110@loadbalancer",
        "--port", "8111:8111@loadbalancer",
        "--port", "3344:3344@loadbalancer",
        "--port", "3010:3010@loadbalancer",
        "--port", "9099:9099@loadbalancer",
    ]
    result = run(args)
    if result.returncode != 0:
        error("Failed to create cluster")
        return False
    success(f"Cluster '{name}' created")
    return True

def namespace_exists(name):
    result = run(["kubectl", "get", "namespace", name], capture_output=True)
    return result.returncode == 0

def create_namespace(name):
    if namespace_exists(name):
        success(f"Namespace '{name}' already exists, skipping")
        return
    run(["kubectl", "create", "namespace", name])
    success(f"Namespace '{name}' created")

def secret_exists(name, namespace):
    result = run(["kubectl", "get", "secret", name, "--namespace", namespace], capture_output=True)
    return result.returncode == 0

def configmap_exists(name, namespace):
    result = run(["kubectl", "get", "configmap", name, "--namespace", namespace], capture_output=True)
    return result.returncode == 0

def generate_violetboard_key():
    return "base64:" + base64.b64encode(secrets.token_bytes(32)).decode()

def generate_echoo_key():
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()

def read_env_file(path):
    """Reads a simple KEY=VALUE .env file into a dict. Returns {} if not found."""
    values = {}
    if not os.path.exists(path):
        return values
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values

def create_secret_with_key(secret_name, namespace, app_name, key_generator, env_file_path):
    if secret_exists(secret_name, namespace):
        success(f"Secret '{secret_name}' already exists in '{namespace}', skipping")
        return True

    env_values = read_env_file(env_file_path)
    password = env_values.get("DB_PASSWORD", "").strip()
    app_key = env_values.get("APP_KEY", "").strip()

    if password and app_key:
        success(f"Found existing credentials in {env_file_path}, reusing them")
    else:
        warn(f"{env_file_path} not found or incomplete – asking for new credentials")
        if not app_key:
            app_key = key_generator()
            info("APP_KEY generated automatically")
        if not password:
            password = input(f"{CYAN}[?]{RESET} Enter a PostgreSQL password for {app_name}: ").strip()
            if not password:
                error("Password cannot be empty")
                return False

    args = [
        "kubectl", "create", "secret", "generic", secret_name,
        "--namespace", namespace,
        f"--from-literal=DB_PASSWORD={password}",
        f"--from-literal=APP_KEY={app_key}",
    ]
    result = run(args)
    if result.returncode != 0:
        error(f"Failed to create secret '{secret_name}'")
        return False
    success(f"Secret '{secret_name}' created")
    return True

def create_secret_password_only(secret_name, namespace, app_name, key_name, env_file_path, env_key):
    if secret_exists(secret_name, namespace):
        success(f"Secret '{secret_name}' already exists in '{namespace}', skipping")
        return True

    env_values = read_env_file(env_file_path)
    password = env_values.get(env_key, "").strip()

    if password:
        success(f"Found existing password in {env_file_path}, reusing it")
    else:
        password = input(f"{CYAN}[?]{RESET} Enter a password for {app_name}: ").strip()
        if not password:
            error("Password cannot be empty")
            return False

    args = [
        "kubectl", "create", "secret", "generic", secret_name,
        "--namespace", namespace,
        f"--from-literal={key_name}={password}",
    ]
    result = run(args)
    if result.returncode != 0:
        error(f"Failed to create secret '{secret_name}'")
        return False
    success(f"Secret '{secret_name}' created")
    return True

def create_dashboard_configmap(script_dir):
    """Creates the Grafana dashboard ConfigMap from the JSON files in dashboards/."""
    if configmap_exists("grafana-dashboards", "monitoring"):
        success("ConfigMap 'grafana-dashboards' already exists, skipping")
        return True

    dashboards_dir = os.path.join(script_dir, "monitoring", "dashboards")
    node_exporter = os.path.join(dashboards_dir, "node-exporter.json")

    if not os.path.exists(node_exporter):
        error(f"Dashboard file not found: {node_exporter}")
        error("Make sure node-exporter.json exists in kubernetes/monitoring/dashboards/")
        return False

    args = [
        "kubectl", "create", "configmap", "grafana-dashboards",
        "--namespace", "monitoring",
        f"--from-file=node-exporter.json={node_exporter}",
    ]
    result = run(args)
    if result.returncode != 0:
        error("Failed to create grafana-dashboards ConfigMap")
        return False
    success("ConfigMap 'grafana-dashboards' created")
    return True

def main():
    print()
    print(f"{CYAN}{'─' * 50}")
    print(f"  cloud-lab – Kubernetes setup")
    print(f"{'─' * 50}{RESET}")
    print()

    cluster_name = "cloud-lab"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    compose_dir = os.path.join(repo_root, "compose")

    # 1. Prerequisites
    info("Checking prerequisites...")
    if not check_prerequisites():
        sys.exit(1)
    print()

    # 2. Cluster
    info("Setting up k3d cluster...")
    if not create_cluster(cluster_name):
        sys.exit(1)
    print()

    # 3. Namespaces
    info("Setting up namespaces...")
    for ns in ["violetboard", "echoo", "monitoring"]:
        create_namespace(ns)
    print()

    # 4. Secrets
    info("Setting up secrets...")
    if not create_secret_with_key(
        secret_name="violetboard-secret",
        namespace="violetboard",
        app_name="Violet-board",
        key_generator=generate_violetboard_key,
        env_file_path=os.path.join(compose_dir, "violetboard.env"),
    ):
        sys.exit(1)

    if not create_secret_with_key(
        secret_name="echoo-secret",
        namespace="echoo",
        app_name="Echoo",
        key_generator=generate_echoo_key,
        env_file_path=os.path.join(compose_dir, "echoo.env"),
    ):
        sys.exit(1)

    if not create_secret_password_only(
        secret_name="grafana-secret",
        namespace="monitoring",
        app_name="Grafana",
        key_name="GRAFANA_PASSWORD",
        env_file_path=os.path.join(compose_dir, "monitoring.env"),
        env_key="GRAFANA_PASSWORD",
    ):
        sys.exit(1)
    print()

    # 5. Grafana dashboard ConfigMap
    info("Setting up Grafana dashboards...")
    if not create_dashboard_configmap(script_dir):
        sys.exit(1)
    print()

    # 6. Apply all manifests
    info("Applying Kubernetes manifests...")
    for folder in ["violetboard", "echoo", "monitoring"]:
        path = os.path.join(script_dir, folder)
        result = run(["kubectl", "apply", "-f", path])
        if result.returncode != 0:
            error(f"Failed to apply manifests in {folder}/")
            sys.exit(1)
        success(f"{folder}/ applied")
    print()

    success("Kubernetes environment is ready!")
    print()
    print(f"  {GREEN}Violet-board:{RESET}  http://localhost:8110")
    print(f"  {GREEN}Echoo:{RESET}         http://localhost:8111")
    print(f"  {GREEN}Grafana:{RESET}       http://localhost:3010")
    print(f"  {GREEN}Prometheus:{RESET}    http://localhost:9099")
    print()
    print(f"  {YELLOW}Check pods:{RESET}  kubectl get pods --all-namespaces")
    print(f"  {YELLOW}Stop:{RESET}        k3d cluster stop cloud-lab")
    print(f"  {YELLOW}Delete:{RESET}      k3d cluster delete cloud-lab")
    print()

if __name__ == "__main__":
    main()