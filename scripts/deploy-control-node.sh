#!/usr/bin/env bash
# Brokkr · deploy to the control node: sync the repo and install the maintenance
# timers. Idempotent.
#
#   BROKKR_SSH_TARGET=brokkr@control-node ./scripts/deploy-control-node.sh [user@host]
#
# Requires ssh + passwordless sudo on control-node. The maintenance timers read
# grimnir's services.json registry at runtime (REGISTRY_PATH env var) — that
# coupling is baked into the systemd unit Environment= directives and into
# the scripts themselves via the REGISTRY_PATH default.
#
# This deploy also performs the cutover automatically + idempotently: it retires the OLD
# grimnir-maintenance-os/-deps units (disable + remove) that this repo replaces, so they
# do not keep firing after their scripts moved to brokkr. Safe to re-run anytime.
#
# Verify the new timers took over:
#   ssh brokkr@control-node systemctl list-timers brokkr-maintenance-\*.timer
set -euo pipefail

CONTROL_NODE="${1:-${BROKKR_SSH_TARGET:-brokkr@control-node}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${BROKKR_REMOTE_DIR:-/opt/brokkr}"
HEIMDALL_SOURCE_ENV="${BROKKR_HEIMDALL_SOURCE_ENV:-/etc/brokkr/heimdall-source.env}"

echo "==> Syncing repo to $CONTROL_NODE:$DEST"
rsync -a --delete --exclude '.git' --exclude '.local' "$HERE/" "$CONTROL_NODE:$DEST/"

echo "==> Installing systemd units on $CONTROL_NODE"
ssh "$CONTROL_NODE" "
  set -euo pipefail

  # The failure monitor must never be enabled without its primary delivery
  # path. Derive its owner-only runtime env from the same host-local source
  # convention used by the NAS deployment; values never leave the host or log.
  if ! sudo test -f '$HEIMDALL_SOURCE_ENV'; then
    echo 'ERROR: Heimdall source environment is missing; refusing to enable the failure sweep' >&2
    exit 2
  fi
  if [ \"\$(sudo grep -Ec '^HEIMDALL_HUB_URL=' '$HEIMDALL_SOURCE_ENV')\" -ne 1 ] \
    || [ \"\$(sudo grep -Ec '^HEIMDALL_FLEET_TOKEN=' '$HEIMDALL_SOURCE_ENV')\" -ne 1 ] \
    || ! sudo grep -Eq '^HEIMDALL_HUB_URL=.+$' '$HEIMDALL_SOURCE_ENV' \
    || ! sudo grep -Eq '^HEIMDALL_FLEET_TOKEN=.+$' '$HEIMDALL_SOURCE_ENV'; then
    echo 'ERROR: Heimdall source environment must contain exactly one non-empty URL and fleet token; refusing to enable the failure sweep' >&2
    exit 2
  fi
  sudo install -d -m 0700 -o brokkr -g brokkr /home/brokkr/.config/brokkr
  sudo sh -c \"umask 077; grep -E '^HEIMDALL_(HUB_URL|FLEET_TOKEN)=' '$HEIMDALL_SOURCE_ENV' > /home/brokkr/.config/brokkr/env\"
  sudo chown brokkr:brokkr /home/brokkr/.config/brokkr/env
  sudo chmod 0600 /home/brokkr/.config/brokkr/env

  sudo install -m 0644 '$DEST'/systemd/brokkr-maintenance-os.service  /etc/systemd/system/brokkr-maintenance-os.service
  sudo install -m 0644 '$DEST'/systemd/brokkr-maintenance-os.timer    /etc/systemd/system/brokkr-maintenance-os.timer
  sudo install -m 0644 '$DEST'/systemd/brokkr-maintenance-deps.service /etc/systemd/system/brokkr-maintenance-deps.service
  sudo install -m 0644 '$DEST'/systemd/brokkr-maintenance-deps.timer   /etc/systemd/system/brokkr-maintenance-deps.timer
  sudo install -m 0644 '$DEST'/systemd/brokkr-systemd-failure@.service /etc/systemd/system/brokkr-systemd-failure@.service
  sudo install -m 0644 '$DEST'/systemd/brokkr-systemd-failure-sweep.service /etc/systemd/system/brokkr-systemd-failure-sweep.service
  sudo install -m 0644 '$DEST'/systemd/brokkr-systemd-failure-sweep.timer /etc/systemd/system/brokkr-systemd-failure-sweep.timer

  sudo systemctl daemon-reload
  sudo systemctl enable --now brokkr-maintenance-os.timer brokkr-maintenance-deps.timer brokkr-systemd-failure-sweep.timer

  # Cutover (idempotent): retire the OLD grimnir-maintenance-* units this repo replaces,
  # so they do not keep firing now that their scripts moved to brokkr.
  removed=0
  for u in grimnir-maintenance-os grimnir-maintenance-deps; do
    if sudo test -e /etc/systemd/system/\$u.timer || sudo test -e /etc/systemd/system/\$u.service; then
      sudo systemctl disable --now \$u.timer \$u.service 2>/dev/null || true
      sudo rm -f /etc/systemd/system/\$u.service /etc/systemd/system/\$u.timer
      removed=1; echo \"retired old \$u.*\"
    fi
  done
  [ \"\$removed\" = 1 ] && sudo systemctl daemon-reload

  echo '-- timer status --'
  systemctl list-timers brokkr-maintenance-os.timer brokkr-maintenance-deps.timer brokkr-systemd-failure-sweep.timer --no-pager 2>/dev/null || true
"
echo "==> Done. Old grimnir-maintenance-* units retired if present; brokkr-maintenance timers active."
