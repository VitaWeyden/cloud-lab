#!/usr/bin/env python3

import os
import shutil
import subprocess
import sys
import secrets
import base64
import time

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

def docker_volumes_matching(name_substring):
    if not shutil.which("docker"):
        return []
    result = run('docker volume ls --format "{{.Name}}"', capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if name_substring in line]

def reset_postgres_password(db_service, new_password):
    # The official postgres image's default pg_hba.conf trusts local
    # connections over the container's unix socket, even though a real
    # password is required over the network. `docker compose exec` talks to
    # the container directly (not over the network), so this lets us set a
    # brand-new password from the outside without ever knowing the old one,
    # and without touching the data volume at all.
    info(f"Starting {db_service} so its password can be reset (existing data is kept)...")
    result = run(f"docker compose up -d {db_service}")
    if result.returncode != 0:
        return False

    info("Waiting for the database to accept connections...")
    ready = False
    for _ in range(15):
        result = run(f"docker compose exec -T {db_service} pg_isready -U postgres", capture_output=True)
        if result.returncode == 0:
            ready = True
            break
        time.sleep(2)

    if not ready:
        error(f"{db_service} did not become ready in time")
        return False

    escaped = new_password.replace("'", "''")  # SQL string literal escaping
    sql = f"ALTER USER postgres WITH PASSWORD '{escaped}';"
    result = run(
        f"docker compose exec -T {db_service} psql -U postgres",
        input=sql,
        text=True,
        capture_output=True,
    )
    return result.returncode == 0

def reset_app_data(services, volume_hints):
    # Scoped to exactly this app - the other application's containers and
    # volumes are never touched.
    volumes = []
    for hint in volume_hints:
        volumes.extend(docker_volumes_matching(hint))

    services_str = " ".join(services)
    info(f"Stopping and removing: {services_str}...")
    run(f"docker compose rm -f -s {services_str}")

    if volumes:
        info(f"Removing volume(s): {', '.join(volumes)}...")
        result = run(f'docker volume rm {" ".join(volumes)}')
        if result.returncode != 0:
            return False

    return True

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

def write_env(env_file, example_file, app_key, password):
    with open(example_file) as f:
        lines = f.readlines()

    with open(env_file, "w") as f:
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("#") or not stripped:
                f.write(line)
                continue
            key = stripped.split("=")[0].strip()
            if key == "APP_KEY" and app_key:
                f.write(f"APP_KEY={app_key}\n")
            elif key in ("DB_PASSWORD", "POSTGRES_PASSWORD"):
                f.write(f"{key}={password}\n")
            else:
                f.write(line)

    success(f"{env_file} created")

def setup_env(env_file, example_file, app_name, key_generator, db_volume_hint, db_service):
    required = ["POSTGRES_PASSWORD", "APP_KEY"]

    if is_env_complete(env_file, required):
        success(f"{env_file} already exists and is complete, skipping")
        return True

    if os.path.exists(env_file):
        warn(f"{env_file} exists but is incomplete – recreating...")
        os.remove(env_file)
    else:
        warn(f"{env_file} not found – creating from example...")

    app_key = key_generator()
    info("APP_KEY generated automatically")

    # PostgreSQL only ever applies POSTGRES_PASSWORD on first init of an empty
    # data directory. If a volume from an earlier run of this project is
    # still around, its real password won't match anything typed in below -
    # unless it's handled one of the two ways below.
    existing_volumes = docker_volumes_matching(db_volume_hint)

    if not existing_volumes:
        password = input(f"{CYAN}[?]{RESET} Enter a password for {app_name}: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        write_env(env_file, example_file, app_key, password)
        return True

    warn(f"{app_name}'s database already has data from a previous run:")
    for v in existing_volumes:
        warn(f"    {v}")
    print()
    print(f"  {CYAN}[1]{RESET} Keep it as is - I still know the existing password, just use it")
    print(f"  {CYAN}[2]{RESET} Keep the data, but set a new password (works even if you forgot the old one)")
    print(f"  {CYAN}[3]{RESET} Start fresh - delete {app_name}'s database and volume(s), use a brand-new password")
    choice = input(f"{CYAN}[?]{RESET} Choice [1/2/3]: ").strip()

    if choice == "1":
        password = input(f"{CYAN}[?]{RESET} Enter the EXISTING password already used for {app_name}'s database: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        write_env(env_file, example_file, app_key, password)
        return True

    elif choice == "2":
        password = input(f"{CYAN}[?]{RESET} Enter a NEW password for {app_name}'s database: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        write_env(env_file, example_file, app_key, password)
        if not reset_postgres_password(db_service, password):
            error(f"Could not reset the password for {db_service}.")
            error("You can try again, or pick option 3 to delete the volume instead.")
            return False
        success(f"{app_name}'s password was reset in place - existing data was kept")
        return True

    elif choice == "3":
        # Only the database is touched here - not the application container.
        # Once this app's env_file changes (new password), `docker compose
        # up -d` later in main() will detect the config diff and recreate
        # the app container on its own; if it's already crash-looping on
        # the old bad password, its `restart: unless-stopped` policy will
        # retry it anyway as soon as the database is healthy again.
        if not reset_app_data([db_service], [db_volume_hint, db_volume_hint.replace("pgdata", "seeded")]):
            error("Failed to remove the old database container/volume(s) - check the output above and retry.")
            return False
        success(f"{app_name}'s old database and data removed")
        password = input(f"{CYAN}[?]{RESET} Enter a password for {app_name}: ").strip()
        if not password:
            error("Password cannot be empty")
            return False
        write_env(env_file, example_file, app_key, password)
        return True

    else:
        error("Invalid choice, expected 1, 2, or 3")
        return False

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
        db_volume_hint="violetboard-pgdata",
        db_service="violetboard-db",
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
        db_volume_hint="echoo-pgdata",
        db_service="echoo-db",
    ):
        sys.exit(1)
    print()

    # 4. Pull latest images and start
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
    print()
    print(f"  {YELLOW}Logs:{RESET}   docker compose logs -f")
    print(f"  {YELLOW}Stop:{RESET}   docker compose down")
    print()

if __name__ == "__main__":
    main()