#!/usr/bin/env bash
# Brokkr · deploy to the NAS Pi: sync the repo, derive the Heimdall env from the shared
# fleet token, install the systemd timer, and run one snapshot. Idempotent.
#
#   BROKKR_SSH_TARGET=brokkr@nas-host ./scripts/deploy-nas.sh [user@host]
#
# Requires ssh + passwordless sudo on the NAS. Heimdall settings are copied server-side
# from BROKKR_HEIMDALL_SOURCE_ENV into an owner-only local env; they never enter this repo.
set -euo pipefail

NAS="${1:-${BROKKR_SSH_TARGET:-brokkr@nas-host}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${BROKKR_REMOTE_DIR:-/opt/brokkr}"
HEIMDALL_SOURCE_ENV="${BROKKR_HEIMDALL_SOURCE_ENV:-/etc/brokkr/heimdall-source.env}"

echo "==> Syncing repo to $NAS:$DEST"
rsync -a --delete --exclude '.git' --exclude '.local' "$HERE/" "$NAS:$DEST/"

echo "==> Configuring + installing on $NAS"
ssh "$NAS" "
  set -euo pipefail
  # Heimdall push env: copy only the two expected assignments, server-side.
  mkdir -p ~/.config/brokkr && chmod 700 ~/.config/brokkr
  if [ -f '$HEIMDALL_SOURCE_ENV' ]; then
    ( umask 077; grep -E '^HEIMDALL_(HUB_URL|FLEET_TOKEN)=' '$HEIMDALL_SOURCE_ENV' > ~/.config/brokkr/env )
    chmod 600 ~/.config/brokkr/env
    echo \"   brokkr env vars: \$(grep -oE '^HEIMDALL_[A-Z_]+' ~/.config/brokkr/env | tr '\n' ' ')\"
  else
    echo '   WARNING: '$HEIMDALL_SOURCE_ENV' not found — Heimdall push will be skipped until configured'
  fi

  sudo install -m 0644 '$DEST'/systemd/brokkr-health.service /etc/systemd/system/brokkr-health.service
  sudo install -m 0644 '$DEST'/systemd/brokkr-health.timer   /etc/systemd/system/brokkr-health.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now brokkr-health.timer

  echo '-- running one snapshot now --'
  sudo systemctl start brokkr-health.service
  sleep 2
  echo '-- health.json --'; cat ~/.local/state/brokkr/health.json 2>/dev/null || echo '(none)'
  echo; echo '-- journal --'; journalctl -u brokkr-health.service -n 6 --no-pager 2>/dev/null
  echo '-- timer --'; systemctl list-timers brokkr-health.timer --no-pager 2>/dev/null | sed -n '1,2p'
"
echo "==> Done."
