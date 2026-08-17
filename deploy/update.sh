#!/bin/sh
# Weekly image update for both crw stacks, launchd-safe.
#
#   pull new image -> recreate solo+saas via their wrappers -> verify
#   /health + /v1/capabilities on both -> roll back to the previous image
#   if verification fails.
#
# Usage: update.sh [--force]
#   --force  recreate + verify even when the pulled image is unchanged
#            (used for testing the full path without waiting for a release).
#
# Exit codes: 0 ok/no-op, 1 update failed AND rollback verified, 2 rollback
# also failed (both stacks may be down — investigate immediately).
set -eu

# launchd starts jobs with PATH=/usr/bin:/bin — docker and jq live elsewhere.
PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"; export PATH

cd "$(dirname "$0")/.."
# Image source of truth is CRW_IMAGE in deploy/.env.solo (the compose overrides
# interpolate the same variable) so update.sh and the stacks can never diverge.
IMAGE="${CRW_IMAGE:-$(sed -n 's/^CRW_IMAGE=//p' deploy/.env.solo)}"
IMAGE="${IMAGE:-ghcr.io/us/crw:latest}"
FORCE="${1:-}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

verify() { # verify <port> <label>
  port=$1; label=$2; tries=30
  while [ $tries -gt 0 ]; do
    if curl -sf "http://127.0.0.1:$port/health" | jq -e '.status=="ok"' >/dev/null 2>&1 \
      && curl -sf "http://127.0.0.1:$port/v1/capabilities" | jq -e '.version' >/dev/null 2>&1; then
      log "verify OK: $label (:$port) version=$(curl -sf http://127.0.0.1:$port/v1/capabilities | jq -r .version)"
      return 0
    fi
    tries=$((tries - 1)); sleep 2
  done
  log "verify FAILED: $label (:$port)"
  return 1
}

recreate_both() {
  # up-solo.sh has no TTY here, so it uses the Keychain->Connect path; if
  # secrets are unavailable it exits non-zero BEFORE touching the container,
  # which we treat as "skip, don't rollback" — the running stack is untouched.
  if ! deploy/up-solo.sh; then
    log "solo recreate skipped/failed before container replacement (secrets?)"
    SOLO_SKIPPED=1
  fi
  deploy/up-saas.sh >/dev/null
}

old_id=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo none)
log "pulling $IMAGE (current: ${old_id#sha256:})"
docker pull -q "$IMAGE" >/dev/null
new_id=$(docker image inspect --format '{{.Id}}' "$IMAGE")

if [ "$new_id" = "$old_id" ] && [ "$FORCE" != "--force" ]; then
  log "no update ($IMAGE unchanged); done"
  exit 0
fi
if [ "$new_id" = "$old_id" ]; then
  log "forced run (image unchanged); recreating stacks"
else
  log "image changed -> ${new_id#sha256:}; recreating stacks"
fi

SOLO_SKIPPED=0
recreate_both

ok=0
[ "$SOLO_SKIPPED" = 1 ] || verify 3000 solo || ok=1
verify 3001 saas || ok=1

if [ $ok -eq 0 ]; then
  log "update complete"
  exit 0
fi

if [ "$old_id" = "none" ]; then
  log "verification failed and no previous image to roll back to"
  exit 2
fi

log "ROLLBACK: retagging ${old_id#sha256:} as $IMAGE and recreating"
docker tag "$old_id" "$IMAGE"
SOLO_SKIPPED=0
recreate_both
rb=0
[ "$SOLO_SKIPPED" = 1 ] || verify 3000 solo-rollback || rb=1
verify 3001 saas-rollback || rb=1
if [ $rb -eq 0 ]; then
  log "rollback verified; NOTE next scheduled run will retry the bad image"
  exit 1
fi
log "ROLLBACK FAILED — stacks unhealthy, manual intervention needed"
exit 2
