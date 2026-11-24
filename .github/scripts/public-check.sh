#!/usr/bin/env bash
# Checks the app the way a visitor reaches it: over the public address, from outside the VM.
# Usage:  public-check.sh http://20.106.75.210 sha-1a2b3c4 [seconds to keep trying, default 60]
# It passes only when ALL of these are true:
#   /api/health   answers 200 and says the database is up
#   /api/version  reports exactly this tag (backend)
#   /version.txt  contains exactly this tag (frontend)
set -euo pipefail

BASE="${1:?Usage: public-check.sh http://ADDRESS sha-1a2b3c4 [seconds]}"
TAG="${2:?Usage: public-check.sh http://ADDRESS sha-1a2b3c4 [seconds]}"
WAIT="${3:-60}"
BASE="${BASE%/}"

if ! [[ "$TAG" =~ ^sha-[0-9a-f]{7}$ ]]; then
  echo "::error::'$TAG' is not a tag like sha-1a2b3c4."
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REASON="no answer yet"

check_once() {
  local code
  code="$(curl -s -o "$TMP/health" -w '%{http_code}' --max-time 5 "$BASE/api/health" 2>/dev/null || true)"
  if [ "$code" != "200" ]; then REASON="/api/health answered '${code:-nothing}' instead of 200"; return 1; fi
  if ! grep -q '"database": *"up"' "$TMP/health"; then REASON="/api/health is 200 but the database is not reported as up"; return 1; fi

  code="$(curl -s -o "$TMP/version" -w '%{http_code}' --max-time 5 "$BASE/api/version" 2>/dev/null || true)"
  if [ "$code" != "200" ]; then REASON="/api/version answered '${code:-nothing}' instead of 200"; return 1; fi
  if ! grep -q "\"version\": *\"$TAG\"" "$TMP/version"; then
    REASON="backend reports $(tr -d '\n' < "$TMP/version") instead of $TAG"; return 1
  fi

  code="$(curl -s -o "$TMP/frontend" -w '%{http_code}' --max-time 5 "$BASE/version.txt" 2>/dev/null || true)"
  if [ "$code" != "200" ]; then REASON="/version.txt answered '${code:-nothing}' instead of 200"; return 1; fi
  if [ "$(tr -d '[:space:]' < "$TMP/frontend")" != "$TAG" ]; then
    REASON="frontend reports $(tr -d '[:space:]' < "$TMP/frontend") instead of $TAG"; return 1
  fi
  return 0
}

echo "Checking $BASE for $TAG (up to ${WAIT}s)"
deadline=$(( $(date +%s) + WAIT ))
while :; do
  if check_once; then
    echo "OK: $BASE serves $TAG (health 200, database up, backend and frontend both report $TAG)."
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
  sleep 3
done
echo "::error::Public check failed: $REASON"
exit 1
