#!/usr/bin/env bash
# Deploys one version of FormFlow on the VM, checks it is healthy, and goes back by itself if not.
# Usage:   ./deploy.sh sha-1a2b3c4            (a normal release)
#          ./deploy.sh sha-1a2b3c4 ROLLBACK   (used by rollback.sh)
# Run it inside /opt/formflow. The pipeline will call this same script over SSH.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/formflow}"
NEW_TAG="${1:?Usage: ./deploy.sh sha-1a2b3c4}"
ACTION="${2:-DEPLOY}"
HEALTH_BASE="${HEALTH_BASE:-http://localhost}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

TAG_RE='^sha-[0-9a-f]{7}$'
if ! [[ "$NEW_TAG" =~ $TAG_RE ]]; then
  echo "Refusing: '$NEW_TAG' is not a tag like sha-1a2b3c4 (sha- plus 7 characters). Nothing changed."
  exit 2
fi
if [ "$ACTION" != "DEPLOY" ] && [ "$ACTION" != "ROLLBACK" ]; then
  echo "Refusing: second argument must be DEPLOY or ROLLBACK. Nothing changed."
  exit 2
fi

cd "$APP_DIR"
if [ ! -f .env ]; then
  echo "No .env in $APP_DIR. Run ./make-env.sh first. Nothing changed."
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "Cannot talk to Docker. Log out and SSH in again so the docker group applies. Nothing changed."
  exit 3
fi

COMPOSE=(docker compose -f docker-compose.prod.yml)
CURRENT_TAG="$(grep -E '^IMAGE_TAG=' .env | head -n 1 | cut -d= -f2- || true)"

log_line() {  # log_line RESULT TAG
  printf '%s %s %s %s by=%s run=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACTION" "$2" "$1" "$(id -un)" "${RUN_ID:-manual}" >> deploy-history.log
}

echo "== $ACTION to $NEW_TAG (current: ${CURRENT_TAG:-none}) =="

# 1. Download the new images first. If this fails, nothing on the server has changed yet.
echo "-- Pulling images"
if ! IMAGE_TAG="$NEW_TAG" "${COMPOSE[@]}" pull; then
  echo "Pull failed. Does the tag $NEW_TAG exist on Docker Hub for both images? Nothing changed."
  log_line PULL_FAILED "$NEW_TAG"
  exit 1
fi

# 2. Record the tag being replaced, then write the new tag into .env.
if [[ "$CURRENT_TAG" =~ $TAG_RE ]] && [ "$CURRENT_TAG" != "$NEW_TAG" ]; then
  printf '%s\n' "$CURRENT_TAG" > previous_tag
fi
if grep -qE '^IMAGE_TAG=' .env; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$NEW_TAG/" .env
else
  printf 'IMAGE_TAG=%s\n' "$NEW_TAG" >> .env
fi
chmod 600 .env

# 3. Start the new version.
echo "-- Starting containers"
"${COMPOSE[@]}" up -d --remove-orphans

# 4. Health check: /api/health must answer 200 AND /api/version must report the new tag.
echo "-- Health check (up to ${WAIT_SECONDS}s)"
healthy=false
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$HEALTH_BASE/api/health" >/dev/null 2>&1 \
     && curl -fsS --max-time 3 "$HEALTH_BASE/api/version" 2>/dev/null | grep -qF "$NEW_TAG"; then
    healthy=true
    break
  fi
  sleep 3
done

if [ "$healthy" = true ]; then
  log_line OK "$NEW_TAG"
  echo "OK: $NEW_TAG is live."
  curl -fsS --max-time 3 "$HEALTH_BASE/api/version" || true
  echo
  exit 0
fi

# 5. Failed. A normal release goes back by itself; a failed rollback just reports.
log_line FAILED "$NEW_TAG"
echo "FAILED: $NEW_TAG did not become healthy within ${WAIT_SECONDS}s."
"${COMPOSE[@]}" ps || true
if [ "$ACTION" = "DEPLOY" ] && [ -f previous_tag ]; then
  PREV="$(cat previous_tag)"
  if [[ "$PREV" =~ $TAG_RE ]] && [ "$PREV" != "$NEW_TAG" ]; then
    echo "Going back to the last good version: $PREV"
    "$SELF" "$PREV" ROLLBACK || true
  fi
else
  echo "No automatic rollback was possible. Run ./rollback.sh sha-xxxxxxx with a version you know is good."
fi
exit 1
