#!/usr/bin/env bash
# Smoke tests for the throwaway copy of the whole stack that runs inside the GitHub runner.
# Usage:  smoke-test.sh http://localhost:8080 sha-1a2b3c4
# This is what plays the role of a staging server, at no cost. If any check fails, nothing is pushed or deployed.
set -euo pipefail

BASE="${1:?Usage: smoke-test.sh http://localhost:8080 sha-1a2b3c4}"
TAG="${2:?Usage: smoke-test.sh http://localhost:8080 sha-1a2b3c4}"
BASE="${BASE%/}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass() { echo "PASS  $1"; }
fail() { echo "::error::SMOKE TEST FAILED: $1"; exit 1; }

# 1. Health must be 200 and must say the database is up. Allow up to 30 seconds for start-up.
code=""
for _ in $(seq 1 10); do
  code="$(curl -s -o "$TMP/health" -w '%{http_code}' --max-time 5 "$BASE/api/health" 2>/dev/null || true)"
  [ "$code" = "200" ] && break
  sleep 3
done
[ "$code" = "200" ] || fail "/api/health answered '${code:-nothing}' instead of 200"
grep -q '"database": *"up"' "$TMP/health" || fail "/api/health is 200 but the database is not reported as up"
pass "/api/health is 200 and the database is up"

# 2. Both tiers must report the tag that was just built.
curl -fsS --max-time 5 "$BASE/api/version" > "$TMP/version" || fail "/api/version did not answer"
grep -q "\"version\": *\"$TAG\"" "$TMP/version" || fail "backend reports $(tr -d '\n' < "$TMP/version") instead of $TAG"
pass "backend reports $TAG"
curl -fsS --max-time 5 "$BASE/version.txt" > "$TMP/frontend" || fail "/version.txt did not answer"
[ "$(tr -d '[:space:]' < "$TMP/frontend")" = "$TAG" ] || fail "frontend reports $(tr -d '[:space:]' < "$TMP/frontend") instead of $TAG"
pass "frontend reports $TAG"

# 3. A form entry must be saved and read back, through the frontend, the backend and the database.
MARKER="ci-smoke-$TAG-$$"
code="$(curl -s -o "$TMP/post" -w '%{http_code}' --max-time 5 -X POST "$BASE/api/submissions" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"CI test\",\"email\":\"ci@example.com\",\"message\":\"$MARKER\"}" 2>/dev/null || true)"
[ "$code" = "201" ] || fail "saving an entry answered '${code:-nothing}' instead of 201"
curl -fsS --max-time 5 "$BASE/api/submissions" > "$TMP/list" || fail "reading entries back did not answer"
grep -qF "$MARKER" "$TMP/list" || fail "the saved entry was not found when reading back"
pass "an entry was saved and read back"

# 4. The input check must reject an empty entry.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$BASE/api/submissions" \
  -H 'Content-Type: application/json' -d '{"name":"","email":"","message":""}' 2>/dev/null || true)"
[ "$code" = "400" ] || fail "an empty entry answered '${code:-nothing}' instead of 400"
pass "an empty entry is rejected with 400"

echo "All smoke tests passed for $TAG."
