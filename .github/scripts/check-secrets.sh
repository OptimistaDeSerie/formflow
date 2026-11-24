#!/usr/bin/env bash
# Fails early, with a clear message, if any GitHub Actions secret is missing.
# It prints only the NAMES of missing secrets, never any value.
# Why: it is much cheaper to learn about a missing secret in the first 10 seconds
# than after the images have been built, tested and pushed.
set -euo pipefail

REQUIRED=(
  DOCKERHUB_USERNAME
  DOCKERHUB_TOKEN
  VM_HOST
  VM_USER
  VM_SSH_PRIVATE_KEY
  VM_HOST_FINGERPRINT
  DB_PASSWORD
)

missing=()
for name in "${REQUIRED[@]}"; do
  if [ -z "${!name:-}" ]; then
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::Missing GitHub Actions secrets: ${missing[*]}"
  echo "Add them in the repository under Settings > Secrets and variables > Actions > New repository secret."
  echo "The names must match exactly, including capital letters."
  exit 1
fi
echo "All ${#REQUIRED[@]} secrets are present."
