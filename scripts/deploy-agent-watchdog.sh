#!/usr/bin/env bash
# Brokkr · deploy the heimdall-agent watchdog (brokkr#14) to fleet hosts.
# Syncs the repo, installs the USER systemd units, enables the timer. Idempotent.
#
#   ./scripts/deploy-agent-watchdog.sh [user@host ...]
#     default hosts: configured role hosts (override by passing explicit targets)
#
# USER units (systemctl --user): the agent it guards is a user unit, so the
# restart runs on the same bus. Requires ssh + user lingering (already on wherever
# heimdall-agent runs). No sudo. Safe to deploy before the heimdall heartbeat
# enabler lands — the watchdog no-ops while the heartbeat file is absent.
set -euo pipefail

ENTRY_SCRIPT="${BASH_SOURCE[0]}"
ENTRY_PATH="$ENTRY_SCRIPT"
[[ "$ENTRY_PATH" == /* ]] || ENTRY_PATH="$(pwd -P)/$ENTRY_PATH"
[[ "$ENTRY_PATH" != *$'\n'* && "$ENTRY_PATH" != *$'\r'* ]] || { echo "brokkr watchdog deploy: deployment entry point path must not contain line breaks" >&2; exit 64; }
ENTRY_CURSOR=/
IFS=/ read -r -a ENTRY_COMPONENTS <<<"${ENTRY_PATH#/}"
for ENTRY_COMPONENT in "${ENTRY_COMPONENTS[@]}"; do
  case "$ENTRY_COMPONENT" in ''|.) continue ;; ..) ENTRY_CURSOR=$(dirname "$ENTRY_CURSOR"); continue ;; esac
  ENTRY_CURSOR="${ENTRY_CURSOR%/}/$ENTRY_COMPONENT"
  [[ ! -L "$ENTRY_CURSOR" ]] || { echo "brokkr watchdog deploy: deployment entry point path must not contain symlinks" >&2; exit 64; }
done
SCRIPT_DIR="$(cd "$(dirname "$ENTRY_SCRIPT")" && pwd -P)"
HERE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"
# This deploys a user unit whose ExecStart is %h/repos/brokkr.
REMOTE_HOME_MARKER=$'\x7e'
DEST="${BROKKR_USER_REMOTE_DIR:-${REMOTE_HOME_MARKER}/repos/brokkr}"
if [[ "$DEST" != "${REMOTE_HOME_MARKER}/repos/brokkr" ]]; then
  echo "brokkr watchdog deploy: BROKKR_USER_REMOTE_DIR must be ~/repos/brokkr (the user unit executes from that path)" >&2
  exit 64
fi
HOSTS=("$@")
if [ "${#HOSTS[@]}" -eq 0 ]; then
  read -r -a HOSTS <<<"${BROKKR_FLEET_TARGETS:-brokkr@control-node brokkr@nas-host brokkr@inference-host brokkr@edge-host}"
fi

# Refuse before any remote I/O unless this is the accepted, clean release source.
require_brokkr_deploy_source_binding "$HERE"
DEPLOY_PAYLOAD_PARENT=""
DEPLOY_PAYLOAD_ROOT=""
cleanup_deploy_payload() { [[ -z "$DEPLOY_PAYLOAD_PARENT" ]] || rm -rf "$DEPLOY_PAYLOAD_PARENT"; }
trap cleanup_deploy_payload EXIT
trap 'cleanup_deploy_payload; exit 1' HUP INT TERM
materialize_brokkr_deploy_payload "$HERE" "$BROKKR_EXPECTED_COMMIT"

for TARGET in "${HOSTS[@]}"; do
  echo "==> $TARGET : syncing repo"
  rsync -a --delete --exclude '.git' --exclude '.local' --exclude '.env*' --exclude 'secrets/' \
    "$DEPLOY_PAYLOAD_ROOT/" "$TARGET:$DEST/"

  echo "==> $TARGET : installing user units + enabling timer"
  ssh "$TARGET" '
    set -euo pipefail
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    remote_user="${USER:-$(id -un)}"
    mkdir -p ~/.config/systemd/user
    install -m 0644 '"$DEST"'/systemd/heimdall-agent-watchdog.service ~/.config/systemd/user/heimdall-agent-watchdog.service
    install -m 0644 '"$DEST"'/systemd/heimdall-agent-watchdog.timer   ~/.config/systemd/user/heimdall-agent-watchdog.timer
    loginctl enable-linger "$remote_user" >/dev/null 2>&1 || true
    systemctl --user daemon-reload
    systemctl --user enable --now heimdall-agent-watchdog.timer
    echo "-- timer --"; systemctl --user list-timers heimdall-agent-watchdog.timer --no-pager 2>/dev/null | head -2
    echo "-- one manual run --"; systemctl --user start heimdall-agent-watchdog.service || true
    journalctl --user -u heimdall-agent-watchdog.service -n 3 --no-pager 2>/dev/null || true
  '
  echo "==> $TARGET : done"
done
echo "==> All hosts done."
