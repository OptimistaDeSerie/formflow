#!/usr/bin/env bash
# Puts the VM back on an older version. No rebuild, because old images stay on Docker Hub.
# Usage:   ./rollback.sh sha-1a2b3c4     go to this exact version
#          ./rollback.sh                  go to the version saved in previous_tag
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/formflow}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  if [ -f "$APP_DIR/previous_tag" ]; then
    TARGET="$(cat "$APP_DIR/previous_tag")"
    echo "No tag given. Using previous_tag: $TARGET"
  else
    echo "No tag given and no previous_tag file. Usage: ./rollback.sh sha-1a2b3c4"
    exit 2
  fi
fi

exec "$HERE/deploy.sh" "$TARGET" ROLLBACK
