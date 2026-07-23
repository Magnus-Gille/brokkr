#!/usr/bin/env bash
# Brokkr · deploy control-node maintenance + failure monitoring. Idempotent.
#
# The install target is deliberately separate from a canonical checkout. Runtime
# identity/layout and Heimdall delivery inputs are explicit so a deployment never
# assumes a particular account, home directory, or secret-file location.
set -euo pipefail

CONTROL_NODE="${1:-${BROKKR_SSH_TARGET:-brokkr@control-node}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_TARGET="${BROKKR_DEPLOY_TARGET:-${BROKKR_REMOTE_DIR:-/opt/brokkr}}"
RUNTIME_USER="${BROKKR_RUNTIME_USER:-brokkr}"
RUNTIME_HOME="${BROKKR_RUNTIME_HOME:-/home/$RUNTIME_USER}"
REGISTRY_PATH="${BROKKR_REGISTRY_PATH:-/opt/grimnir/services.json}"
HEIMDALL_URL="${BROKKR_HEIMDALL_URL:-}"
HEIMDALL_TOKEN_SOURCE="${BROKKR_HEIMDALL_TOKEN_SOURCE:-}"

die() { echo "brokkr deploy: $*" >&2; exit 64; }
valid_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]+$ ]]; }

[[ "$RUNTIME_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid BROKKR_RUNTIME_USER"
valid_path "$DEPLOY_TARGET" || die "invalid BROKKR_DEPLOY_TARGET"
valid_path "$RUNTIME_HOME" || die "invalid BROKKR_RUNTIME_HOME"
valid_path "$REGISTRY_PATH" || die "invalid BROKKR_REGISTRY_PATH"
valid_path "$HEIMDALL_TOKEN_SOURCE" || die "BROKKR_HEIMDALL_TOKEN_SOURCE must be an absolute server-side path"
[[ "$HEIMDALL_URL" =~ ^https?://[^[:space:]\']+$ ]] || die "BROKKR_HEIMDALL_URL must be an explicit non-secret http(s) URL"

echo "==> Syncing Brokkr release to $CONTROL_NODE"
rsync -a --delete --exclude '.git' --exclude '.local' "$HERE/" "$CONTROL_NODE:$DEPLOY_TARGET/"

echo "==> Rendering + installing control-node systemd units"
ssh "$CONTROL_NODE" "
  set -euo pipefail

  # Never enable the monitor before proving the token source is a protected,
  # regular root-owned file with exactly one non-empty token assignment.
  if ! sudo test -f '$HEIMDALL_TOKEN_SOURCE' || sudo test -L '$HEIMDALL_TOKEN_SOURCE' || ! sudo test -O '$HEIMDALL_TOKEN_SOURCE'; then
    echo 'ERROR: Heimdall token source is not a protected regular root-owned file' >&2
    exit 2
  fi
  token_mode=\$(sudo stat -c '%a' '$HEIMDALL_TOKEN_SOURCE')
  case \$token_mode in 400|600) ;; *) echo 'ERROR: Heimdall token source must have mode 0400 or 0600' >&2; exit 2 ;; esac
  if [ \"\$(sudo grep -Ec '^HEIMDALL_FLEET_TOKEN=' '$HEIMDALL_TOKEN_SOURCE')\" -ne 1 ] \
    || ! sudo grep -Eq '^HEIMDALL_FLEET_TOKEN=.+$' '$HEIMDALL_TOKEN_SOURCE'; then
    echo 'ERROR: Heimdall token source must contain exactly one non-empty fleet token' >&2
    exit 2
  fi

  sudo install -d -m 0700 -o '$RUNTIME_USER' -g '$RUNTIME_USER' '$RUNTIME_HOME/.config/brokkr'
  sudo sh -c \"umask 077; { printf '%s\\n' 'HEIMDALL_HUB_URL=$HEIMDALL_URL'; grep -E '^HEIMDALL_FLEET_TOKEN=' '$HEIMDALL_TOKEN_SOURCE'; } > '$RUNTIME_HOME/.config/brokkr/env'\"
  sudo chown '$RUNTIME_USER:$RUNTIME_USER' '$RUNTIME_HOME/.config/brokkr/env'
  sudo chmod 0600 '$RUNTIME_HOME/.config/brokkr/env'

  sudo env BROKKR_RUNTIME_USER='$RUNTIME_USER' BROKKR_RUNTIME_HOME='$RUNTIME_HOME' BROKKR_DEPLOY_TARGET='$DEPLOY_TARGET' BROKKR_REGISTRY_PATH='$REGISTRY_PATH' \
    '$DEPLOY_TARGET/scripts/render-systemd-failure-units.sh' /etc/systemd/system
  sudo install -m 0644 '$DEPLOY_TARGET/systemd/brokkr-maintenance-os.timer' /etc/systemd/system/brokkr-maintenance-os.timer
  sudo install -m 0644 '$DEPLOY_TARGET/systemd/brokkr-maintenance-deps.timer' /etc/systemd/system/brokkr-maintenance-deps.timer
  sudo install -m 0644 '$DEPLOY_TARGET/systemd/brokkr-systemd-failure-sweep.timer' /etc/systemd/system/brokkr-systemd-failure-sweep.timer

  sudo systemctl daemon-reload
  sudo systemctl enable --now brokkr-maintenance-os.timer brokkr-maintenance-deps.timer brokkr-systemd-failure-sweep.timer

  # Retire the old Grimnir maintenance units after the Brokkr units are enabled.
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
echo "==> Done. No Heimdall credential values were printed."
