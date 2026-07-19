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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# This deploys a user unit whose ExecStart is %h/repos/brokkr.
DEST="${BROKKR_USER_REMOTE_DIR:-~/repos/brokkr}"
HOSTS=("$@")
if [ "${#HOSTS[@]}" -eq 0 ]; then
  read -r -a HOSTS <<<"${BROKKR_FLEET_TARGETS:-brokkr@control-node brokkr@nas-host brokkr@inference-host brokkr@edge-host}"
fi

for TARGET in "${HOSTS[@]}"; do
  echo "==> $TARGET : syncing repo"
  rsync -a --delete --exclude '.git' --exclude '.local' "$HERE/" "$TARGET:$DEST/"

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
