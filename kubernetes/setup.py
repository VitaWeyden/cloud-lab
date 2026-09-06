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

def pvc_exists(name, namespace):
    result = run(["kubectl", "get", "pvc", name, "--namespace", namespace], capture_output=True)
    return result.returncode == 0

def deployment_exists(name, namespace):
    result = run(["kubectl", "get", "deployment", name, "--namespace", namespace], capture_output=True)
    return result.returncode == 0

def wait_for_pod_ready(app_label, namespace, timeout_seconds=60):
    result = run([
        "kubectl", "wait", "pod",
        "--for=condition=ready",
        "--selector", f"app={app_label}",
        "--namespace", namespace,
        f"--timeout={timeout_seconds}s",
    ], capture_output=True)
    return result.returncode == 0

def reset_postgres_password(db_deployment, db_manifest_path, namespace, new_password):
    # `kubectl exec` reaches the pod directly, the same way `docker compose
    # exec` does for the Compose setup - and the official postgres image
    # trusts local (unix socket) connections regardless of POSTGRES_PASSWORD,
    # so this works even without knowing the password currently in use.
    # Requires the Secret to already exist with the new password (the caller
    # creates/updates it before calling this).
    info(f"Making sure {db_deployment} is running so its password can be reset...")
    result = run(["kubectl", "apply", "-f", db_manifest_path], capture_output=True)
    if result.returncode != 0:
        error(f"Failed to apply {db_manifest_path}")
        return False

    if not wait_for_pod_ready(db_deployment, namespace, timeout_seconds=60):
        error(f"{db_deployment} did not become ready in time")
        return False

    escaped = new_password.replace("'", "''")
    sql = f"ALTER USER postgres WITH PASSWORD '{escaped}';"
    result = run(
        ["kubectl", "exec", f"deploy/{db_deployment}", "--namespace", namespace, "--", "psql", "-U", "postgres"],
        input=sql,
        text=True,
        capture_output=True,
    )
    return result.returncode == 0

def delete_pvc_and_db(db_deployment, pvc_name, namespace):
    # Scoped to exactly this app's database - the application Deployment and
    # the other application's namespace are never touched. If the app
    # Deployment is currently crash-looping on the old password, it'll pick
    # up the new one on its own next restart once the fresh secret exists.
    if deployment_exists(db_deployment, namespace):
        info(f"Deleting deployment '{db_deployment}' in '{namespace}'...")
        run(["kubectl", "delete", "deployment", db_deployment, "--namespace", namespace])
    if pvc_exists(pvc_name, namespace):
        info(f"Deleting PVC '{pvc_name}' in '{namespace}'...")
        result = run(["kubectl", "delete", "pvc", pvc_name, "--namespace", namespace])
        if result.returncode != 0:
            return False
    return True

def restart_deployment_if_exists(name, namespace):
    if deployment_exists(name, namespace):
        run(["kubectl", "rollout", "restart", f"deployment/{name}", "--namespace", namespace])

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

def _create_secret_object(secret_name, namespace, password, app_key):
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

def create_secret_with_key(secret_name, namespace, app_name, key_generator, env_file_path,
                            db_deployment, db_manifest_path, pvc_name, app_deployment):
    if secret_exists(secret_name, namespace):
        success(f"Secret '{secret_name}' already exists in '{namespace}', skipping")
        return True

    env_values = read_env_file(env_file_path)
    app_key = env_values.get("APP_KEY", "").strip()
    if not app_key:
        app_key = key_generator()
        info("APP_KEY generated automatically")

    # A PVC is a separate, independently-persisted object from the Secret -
    # exactly like a Docker volume is separate from a Compose .env file. If
    # one already has real Postgres data in it, whatever password ends up in
    # a freshly created Secret needs to actually match it (or the PVC needs
    # to go) - otherwise the DB pod ends up in CrashLoopBackOff the same way
    # a Compose container would keep restarting on a bad password.
    #
    # Also, unlike Compose (which recreates a container whenever its env_file
    # content changes), Kubernetes only resolves `secretKeyRef` values when a
    # Pod is first created - an already-running app Pod won't pick up a
    # newly-created or updated Secret on its own. Every branch below that
    # touches the Secret restarts the app Deployment as a result, so it
    # always ends up with a fresh Pod referencing the current Secret value.
    if not pvc_exists(pvc_name, namespace):
        password = env_values.get("DB_PASSWORD", "").strip()
        if password:
            success(f"Found existing credentials in {env_file_path}, reusing them")
        else:
            password = input(f"{CYAN}[?]{RESET} Enter a PostgreSQL password for {app_name}: ").strip()
            if not password:
                error("Password cannot be empty")
                return False
        if not _create_secret_object(secret_name, namespace, password, app_key):
            return False
        restart_deployment_if_exists(app_deployment, namespace)
        return True

    warn(f"{app_name}'s database already has data from a previous run (PVC '{pvc_name}' exists).")
    print()
    print(f"  {CYAN}[1]{RESET} Keep it as is - I still know the existing password, just use it")
    print(f"  {CYAN}[2]{RESET} Keep the data, but set a new password (works even if you forgot the old one)")
    print(f"  {CYAN}[3]{RESET} Start fresh - delete {app_name}'s database and PVC, use a brand-new password")
    choice = input(f"{CYAN}[?]{RESET} Choice [1/2/3]: ").strip()

    if choice == "1":
        password = input(f"{CYAN}[?]{RESET} Enter the EXISTING password already used for {app_name}'s database: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        if not _create_secret_object(secret_name, namespace, password, app_key):
            return False
        restart_deployment_if_exists(app_deployment, namespace)
        return True

    elif choice == "2":
        password = input(f"{CYAN}[?]{RESET} Enter a NEW password for {app_name}'s database: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        if not _create_secret_object(secret_name, namespace, password, app_key):
            return False
        if not reset_postgres_password(db_deployment, db_manifest_path, namespace, password):
            error(f"Could not reset the password for {db_deployment}.")
            error("You can try again, or pick option 3 to delete the PVC instead.")
            return False
        restart_deployment_if_exists(app_deployment, namespace)
        success(f"{app_name}'s password was reset in place - existing data was kept")
        return True

    elif choice == "3":
        # Only this app's database is touched here - not the application
        # Deployment (beyond the restart below), and never the other
        # application's namespace.
        if not delete_pvc_and_db(db_deployment, pvc_name, namespace):
            error("Failed to remove the old database/PVC - check the output above and retry.")
            return False
        success(f"{app_name}'s old database and PVC removed")
        password = input(f"{CYAN}[?]{RESET} Enter a password for {app_name}: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        if not _create_secret_object(secret_name, namespace, password, app_key):
            return False
        restart_deployment_if_exists(app_deployment, namespace)
        return True

    else:
        error("Invalid choice, expected 1, 2, or 3")
        return False

def create_secret_password_only(secret_name, namespace, app_name, key_name):
    if secret_exists(secret_name, namespace):
        success(f"Secret '{secret_name}' already exists in '{namespace}', skipping")
        return True

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
        db_deployment="violetboard-db",
        db_manifest_path=os.path.join(script_dir, "violetboard", "db.yaml"),
        pvc_name="violetboard-db-pvc",
        app_deployment="violetboard-app",
    ):
        sys.exit(1)

    if not create_secret_with_key(
        secret_name="echoo-secret",
        namespace="echoo",
        app_name="Echoo",
        key_generator=generate_echoo_key,
        env_file_path=os.path.join(compose_dir, "echoo.env"),
        db_deployment="echoo-db",
        db_manifest_path=os.path.join(script_dir, "echoo", "db.yaml"),
        pvc_name="echoo-db-pvc",
        app_deployment="echoo-backend",
    ):
        sys.exit(1)

    if not create_secret_password_only(
        secret_name="grafana-secret",
        namespace="monitoring",
        app_name="Grafana",
        key_name="GRAFANA_PASSWORD",
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