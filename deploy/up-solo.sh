#!/bin/sh
# Launch/refresh the solo-shape stack with the LLM key from 1Password.
#
# Two auth paths, tried in order:
#   1. UNATTENDED — Keychain token -> local 1Password Connect REST API
#      (delta-op-connect-api, :8085). Zero prompts; used by launchd/update.sh.
#      Token entry: account "delta-op-token-delta-agent-platform",
#      service "delta-platform" (mirrored by delta-data-platform's
#      scripts/setup-keychain-tokens.sh).
#   2. INTERACTIVE — `op run` via the desktop app (Touch ID) when a TTY is
#      attached and the Connect path is unavailable.
#
# The plaintext key is only ever held in this process's memory and handed to
# `docker compose` via the environment. It is never written to disk or printed.
set -eu
cd "$(dirname "$0")/.."

VAULT="delta-agent-platform"
ITEM="fast-crw-ANTHROPIC"
FIELD="credential"
KC_ACCOUNT="delta-op-token-${VAULT}"
KC_SERVICE="delta-platform"
CONNECT="${OP_CONNECT_HOST:-http://localhost:8085}"

compose_up() {
  # Key arrives via exported env; no --env-file so compose never sees the
  # literal op:// reference string.
  docker compose -p crw-solo \
    -f docker-compose.yml -f deploy/solo.override.yml \
    up -d --force-recreate crw
}

# Non-secret vars (ports, searxng/browserless secrets) come from the env file.
set -a; . ./deploy/.env.solo; set +a

token=$(security find-generic-password -a "$KC_ACCOUNT" -s "$KC_SERVICE" -w 2>/dev/null || true)
if [ -n "$token" ]; then
  vid=$(curl -sf -H "Authorization: Bearer $token" "$CONNECT/v1/vaults" \
    | jq -r --arg v "$VAULT" '.[] | select(.name==$v) | .id')
  iid=$(curl -sf -H "Authorization: Bearer $token" \
    "$CONNECT/v1/vaults/$vid/items?filter=title%20eq%20%22$ITEM%22" | jq -r '.[0].id')
  key=$(curl -sf -H "Authorization: Bearer $token" "$CONNECT/v1/vaults/$vid/items/$iid" \
    | jq -r --arg f "$FIELD" '.fields[] | select(.label==$f) | .value')
  if [ -z "$key" ] || [ "$key" = "null" ]; then
    echo "up-solo: Connect reachable but could not resolve $ITEM/$FIELD in $VAULT" >&2
    exit 1
  fi
  CRW_SOLO_LLM_KEY="$key" compose_up
  echo "up-solo: launched (unattended via Connect)"
elif [ -t 0 ]; then
  # Interactive fallback: op resolves the op:// ref in .env.solo (Touch ID).
  exec op run --env-file=deploy/.env.solo -- sh -c '
    docker compose -p crw-solo \
      -f docker-compose.yml -f deploy/solo.override.yml \
      up -d --force-recreate crw'
else
  echo "up-solo: no Keychain Connect token and no TTY for Touch ID fallback." >&2
  echo "Run delta-data-platform/scripts/setup-keychain-tokens.sh once to mirror" >&2
  echo "the $VAULT Connect token into the Keychain." >&2
  exit 1
fi
