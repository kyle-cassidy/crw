#!/bin/sh
# Launch/refresh the saas-shape stack. No secrets needed by design —
# CRW_DISABLE_SERVER_LLM_KEY=1 means this instance can never hold an LLM key.
set -eu
cd "$(dirname "$0")/.."
exec docker compose -p crw-saas \
  -f docker-compose.yml -f deploy/saas.override.yml \
  --env-file deploy/.env.saas \
  up -d --force-recreate crw
