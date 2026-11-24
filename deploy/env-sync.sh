#!/usr/bin/env bash
# Runs on the VM, started by the pipeline. It reads two lines from standard input:
#   line 1: the database password (from the GitHub secret DB_PASSWORD)
#   line 2: the Docker Hub username (from the GitHub secret DOCKERHUB_USERNAME)
# Because they arrive on standard input, they never appear in a command line or in a log.
#
# What it does:
#   - No .env file yet (a brand-new VM): writes one, permissions 600.
#   - .env already exists: checks the password in it matches the GitHub secret. It NEVER overwrites.
#
# Why it never overwrites: Postgres reads its password only the first time it starts. If the .env
# were silently replaced with a different password, the backend could no longer log in to its own
# database, and a rollback would not fix it. A mismatch must stop the pipeline instead.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/formflow}"
cd "$APP_DIR"

PASS=""; DOCKER_ID=""
IFS= read -r PASS || [ -n "$PASS" ] || true
IFS= read -r DOCKER_ID || [ -n "$DOCKER_ID" ] || true

if ! [[ "$PASS" =~ ^[A-Za-z0-9]{12,}$ ]]; then
  echo "The database password received is empty or not 12 or more letters and numbers. Nothing changed."
  exit 2
fi

if [ -f .env ]; then
  CURRENT="$(grep -E '^DB_PASSWORD=' .env | head -n 1 | cut -d= -f2- || true)"
  if [ "$CURRENT" = "$PASS" ]; then
    echo "OK: the GitHub secret DB_PASSWORD matches the password in $APP_DIR/.env."
    exit 0
  fi
  echo "STOP: the GitHub secret DB_PASSWORD does NOT match the password in $APP_DIR/.env."
  echo "Nothing was changed. Fix the GitHub secret so it equals the password you typed into make-env.sh."
  echo "If you lost it, read it on the VM with: grep DB_PASSWORD $APP_DIR/.env"
  exit 4
fi

if ! [[ "$DOCKER_ID" =~ ^[a-z0-9]{4,30}$ ]]; then
  echo "No .env exists yet and the Docker Hub username received is not valid. Nothing written."
  exit 2
fi

umask 077
cat > .env <<ENV
DOCKERHUB_USER=$DOCKER_ID
IMAGE_TAG=none-yet
DB_NAME=formflow
DB_USER=formflow
DB_PASSWORD=$PASS
HTTP_PORT=80
ENV
chmod 600 .env
echo "No .env existed. Wrote a new one (permissions 600) from the GitHub secrets."
