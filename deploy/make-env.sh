#!/usr/bin/env bash
# Runs ONCE on the VM, inside /opt/formflow. Creates the private .env file.
# It asks for two values, so no password is ever typed into a command line or kept in shell history.
set -euo pipefail

cd "$(dirname "$0")"

if [ -e .env ] && [ "${1:-}" != "--force" ]; then
  echo ".env already exists. Nothing changed. Run './make-env.sh --force' to replace it."
  exit 1
fi

read -r -p "Your Docker Hub username (Docker ID, lowercase): " DOCKER_ID
if ! [[ "$DOCKER_ID" =~ ^[a-z0-9]{4,30}$ ]]; then
  echo "A Docker ID is 4 to 30 lowercase letters and numbers. Nothing written."
  exit 1
fi

read -r -s -p "Database password (12 or more letters and numbers, nothing is shown as you type): " DB_PASS
echo
if ! [[ "$DB_PASS" =~ ^[A-Za-z0-9]{12,}$ ]]; then
  echo "The password must be 12 or more characters, letters and numbers only. Nothing written."
  exit 1
fi
read -r -s -p "Type the same password again: " DB_PASS2
echo
if [ "$DB_PASS" != "$DB_PASS2" ]; then
  echo "The two passwords differ. Nothing written."
  exit 1
fi

umask 077
cat > .env <<ENV
DOCKERHUB_USER=$DOCKER_ID
IMAGE_TAG=none-yet
DB_NAME=formflow
DB_USER=formflow
DB_PASSWORD=$DB_PASS
HTTP_PORT=80
ENV
chmod 600 .env

echo ".env written with permissions 600 (only you can read it)."
echo "Save the database password in your private note. GitHub will need the same one later."
