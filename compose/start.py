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

def run(cmd, **kwargs):
    return subprocess.run(cmd, shell=True, **kwargs)

def check_prerequisites():
    ok = True
    if shutil.which("docker"):
        success("docker found")
    else:
        error("docker not found – install Docker Desktop: https://docs.docker.com/get-docker/")
        ok = False

    result = run("docker compose version", capture_output=True)
    if result.returncode == 0:
        success("docker compose found")
    else:
        error("docker compose not found")
        ok = False

    return ok

def generate_violetboard_key():
    return "base64:" + base64.b64encode(secrets.token_bytes(32)).decode()

def generate_echoo_key():
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()

def is_env_complete(env_file, required_keys):
    if not os.path.exists(env_file):
        return False
    with open(env_file) as f:
        content = f.read()
    for line in content.splitlines():
        for key in required_keys:
            if line.startswith(f"{key}=") and line.strip() == f"{key}=":
                return False
    return True

def setup_env(env_file, example_file, app_name, key_generator=None):
    required = ["POSTGRES_PASSWORD"] if key_generator else ["GRAFANA_PASSWORD"]
    if key_generator:
        required.append("APP_KEY")

    if is_env_complete(env_file, required):
        success(f"{env_file} already exists and is complete, skipping")
        return True

    if os.path.exists(env_file):
        warn(f"{env_file} exists but is incomplete – recreating...")
        os.remove(env_file)
    else:
        warn(f"{env_file} not found – creating from example...")

    with open(example_file) as f:
        lines = f.readlines()

    app_key = key_generator() if key_generator else None
    if app_key:
        info("APP_KEY generated automatically")

    password = input(f"{CYAN}[?]{RESET} Enter a password for {app_name}: ").strip()
    if not password:
        error("Password cannot be empty")
        return False

    with open(env_file, "w") as f:
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("#") or not stripped:
                f.write(line)
                continue
            key = stripped.split("=")[0].strip()
            if key == "APP_KEY" and app_key:
                f.write(f"APP_KEY={app_key}\n")
            elif key in ("DB_PASSWORD", "POSTGRES_PASSWORD", "GRAFANA_PASSWORD"):
                f.write(f"{key}={password}\n")
            else:
                f.write(line)

    success(f"{env_file} created")
    return True

def main():
    print()
    print(f"{CYAN}{'─' * 50}")
    print(f"  cloud-lab – setup & start")
    print(f"{'─' * 50}{RESET}")
    print()

    script_dir = os.path.dirname(os.path.abspath(__file__))

    if not os.path.exists(os.path.join(script_dir, "docker-compose.yml")):
        error("docker-compose.yml not found next to this script.")
        error("Make sure you are running this from inside the compose/ folder (or via `python compose/start.py` from the repo root).")
        sys.exit(1)

    os.chdir(script_dir)

    # 1. Prerequisites
    info("Checking prerequisites...")
    if not check_prerequisites():
        sys.exit(1)
    print()

    # 2. Violet-board env
    info("Setting up Violet-board environment...")
    if not setup_env(
        env_file="violetboard.env",
        example_file="violetboard.env.example",
        app_name="Violet-board",
        key_generator=generate_violetboard_key,
    ):
        sys.exit(1)
    print()

    # 3. Echoo env
    info("Setting up Echoo environment...")
    if not setup_env(
        env_file="echoo.env",
        example_file="echoo.env.example",
        app_name="Echoo",
        key_generator=generate_echoo_key,
    ):
        sys.exit(1)
    print()

    # 4. Monitoring env
    info("Setting up Monitoring environment...")
    if not setup_env(
        env_file="monitoring.env",
        example_file="monitoring.env.example",
        app_name="Grafana",
    ):
        sys.exit(1)
    print()

    # 5. Pull latest images and start
    info("Pulling latest images from GHCR...")
    run("docker compose pull")
    print()

    info("Starting containers...")
    result = run("docker compose up -d")
    if result.returncode != 0:
        error("docker compose failed – check the output above")
        sys.exit(1)

    print()
    success("Everything is running!")
    print()
    print(f"  {GREEN}Violet-board:{RESET}  http://localhost:8100")
    print(f"  {GREEN}Echoo:{RESET}         http://localhost:8101")
    print(f"  {GREEN}Grafana:{RESET}       http://localhost:3000")
    print(f"  {GREEN}Prometheus:{RESET}    http://localhost:9090")
    print()
    print(f"  {YELLOW}Logs:{RESET}   docker compose logs -f")
    print(f"  {YELLOW}Stop:{RESET}   docker compose down")
    print()

if __name__ == "__main__":
    main()