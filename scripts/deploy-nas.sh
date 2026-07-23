#!/usr/bin/env bash
# Brokkr · deploy a rendered release to the NAS Pi. Idempotent.
#
# Runtime identity and layout are deliberately explicit. See docs/nas-deploy.md.
set -euo pipefail

NAS="${1:-${BROKKR_SSH_TARGET:-brokkr@nas-host}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_TARGET="${BROKKR_DEPLOY_TARGET:-}"
RUNTIME_USER="${BROKKR_RUNTIME_USER:-}"
RUNTIME_HOME="${BROKKR_RUNTIME_HOME:-}"
REGISTRY_PATH="${BROKKR_REGISTRY_PATH:-}"
HEIMDALL_SOURCE_ENV="${BROKKR_HEIMDALL_SOURCE_ENV:-}"

die() { echo "brokkr NAS deploy: $*" >&2; exit 64; }
valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]+$ ]] \
    && [[ "$1" != *'//'* && "$1" != */./* && "$1" != */../* && "$1" != */. && "$1" != */.. ]]
}
require() { [[ -n "${!1:-}" ]] || die "$1 is required"; }

require BROKKR_RUNTIME_USER
require BROKKR_RUNTIME_HOME
require BROKKR_DEPLOY_TARGET
require BROKKR_REGISTRY_PATH
[[ "$RUNTIME_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid BROKKR_RUNTIME_USER"
valid_path "$RUNTIME_HOME" || die "invalid BROKKR_RUNTIME_HOME"
valid_path "$DEPLOY_TARGET" || die "invalid BROKKR_DEPLOY_TARGET"
valid_path "$REGISTRY_PATH" || die "invalid BROKKR_REGISTRY_PATH"
if [[ -n "$HEIMDALL_SOURCE_ENV" ]]; then
  valid_path "$HEIMDALL_SOURCE_ENV" || die "invalid BROKKR_HEIMDALL_SOURCE_ENV"
fi

echo "==> Preparing NAS release target"
ssh "$NAS" "
  set -euo pipefail
  if ! id '$RUNTIME_USER' >/dev/null 2>&1 \
    || ! sudo test -d '$RUNTIME_HOME' || sudo test -L '$RUNTIME_HOME' \
    || ! sudo -u '$RUNTIME_USER' test -O '$RUNTIME_HOME' \
    || ! sudo -u '$RUNTIME_USER' test -w '$RUNTIME_HOME'; then
    echo 'ERROR: runtime user or home is not usable' >&2
    exit 2
  fi
  if sudo test -e '$DEPLOY_TARGET' || sudo test -L '$DEPLOY_TARGET'; then
    if ! sudo test -d '$DEPLOY_TARGET' || sudo test -L '$DEPLOY_TARGET' \
      || ! sudo -u '$RUNTIME_USER' test -O '$DEPLOY_TARGET' \
      || ! sudo -u '$RUNTIME_USER' test -w '$DEPLOY_TARGET'; then
      echo 'ERROR: existing release target is not a runtime-user-owned writable directory' >&2
      exit 2
    fi
  else
    if ! sudo install -d -m 0750 -o '$RUNTIME_USER' '$DEPLOY_TARGET' \
      || ! sudo test -d '$DEPLOY_TARGET' || sudo test -L '$DEPLOY_TARGET' \
      || ! sudo -u '$RUNTIME_USER' test -O '$DEPLOY_TARGET' \
      || ! sudo -u '$RUNTIME_USER' test -w '$DEPLOY_TARGET'; then
      echo 'ERROR: could not prepare a runtime-user-owned writable release target' >&2
      exit 2
    fi
  fi
"

echo "==> Syncing Brokkr release to $NAS"
rsync -a --delete --exclude '.git' --exclude '.local' \
  --rsync-path="sudo -u $RUNTIME_USER rsync" "$HERE/" "$NAS:$DEPLOY_TARGET/"

echo "==> Rendering + installing NAS systemd units"
ssh "$NAS" "
  set -euo pipefail
  if ! id '$RUNTIME_USER' >/dev/null 2>&1 \
    || ! sudo test -d '$RUNTIME_HOME' || sudo test -L '$RUNTIME_HOME' \
    || ! sudo -u '$RUNTIME_USER' test -O '$RUNTIME_HOME' \
    || ! sudo -u '$RUNTIME_USER' test -w '$RUNTIME_HOME'; then
    echo 'ERROR: runtime user or home is not usable' >&2
    exit 2
  fi
  if ! sudo test -d '$DEPLOY_TARGET' || sudo test -L '$DEPLOY_TARGET' \
    || ! sudo -u '$RUNTIME_USER' test -O '$DEPLOY_TARGET' \
    || ! sudo -u '$RUNTIME_USER' test -w '$DEPLOY_TARGET'; then
    echo 'ERROR: release target is not a runtime-user-owned writable directory' >&2
    exit 2
  fi
  if ! sudo test -f '$REGISTRY_PATH' || sudo test -L '$REGISTRY_PATH' \
    || ! sudo -u '$RUNTIME_USER' test -r '$REGISTRY_PATH'; then
    echo 'ERROR: registry path is not a readable regular file for the runtime user' >&2
    exit 2
  fi

  runtime_env='$RUNTIME_HOME/.config/brokkr/env'

  # Copy only the two expected assignments from a protected server-side source.
  # Never print the source path or its values. When no provisioning source was
  # supplied, inspect only metadata for an existing runtime env; the health
  # snapshot below remains the semantic delivery check.
  if [ -n '$HEIMDALL_SOURCE_ENV' ]; then
    if ! sudo test -f '$HEIMDALL_SOURCE_ENV' || sudo test -L '$HEIMDALL_SOURCE_ENV' \
      || ! sudo test -O '$HEIMDALL_SOURCE_ENV'; then
      echo 'ERROR: Heimdall source is not a protected regular root-owned file' >&2
      exit 2
    fi
    source_mode=\$(sudo stat -c '%a' '$HEIMDALL_SOURCE_ENV')
    case \$source_mode in 400|600) ;; *) echo 'ERROR: Heimdall source has unsafe permissions' >&2; exit 2 ;; esac
    if [ \"\$(sudo grep -Ec '^HEIMDALL_HUB_URL=.+$' '$HEIMDALL_SOURCE_ENV')\" -ne 1 ] \
      || [ \"\$(sudo grep -Ec '^HEIMDALL_FLEET_TOKEN=.+$' '$HEIMDALL_SOURCE_ENV')\" -ne 1 ]; then
      echo 'ERROR: Heimdall source must contain exactly one non-empty URL and fleet token' >&2
      exit 2
    fi
    sudo install -d -m 0700 -o '$RUNTIME_USER' '$RUNTIME_HOME/.config/brokkr'
    sudo sh -c \"umask 077; grep -E '^HEIMDALL_(HUB_URL|FLEET_TOKEN)=' '$HEIMDALL_SOURCE_ENV' > '$RUNTIME_HOME/.config/brokkr/env'\"
    sudo chown '$RUNTIME_USER' '$RUNTIME_HOME/.config/brokkr/env'
    sudo chmod 0600 '$RUNTIME_HOME/.config/brokkr/env'
    echo '   Heimdall runtime environment provisioned from protected source'
  elif sudo test -e \$runtime_env || sudo test -L \$runtime_env; then
    if ! sudo test -f \$runtime_env || sudo test -L \$runtime_env \
      || ! sudo -u '$RUNTIME_USER' test -O \$runtime_env \
      || ! sudo -u '$RUNTIME_USER' test -r \$runtime_env \
      || ! sudo test -s \$runtime_env; then
      echo 'ERROR: preserved Heimdall runtime environment is not a protected readable non-empty regular file' >&2
      exit 2
    fi
    runtime_mode=\$(sudo stat -c '%a' \$runtime_env)
    case \$runtime_mode in
      400|600) ;;
      *) echo 'ERROR: preserved Heimdall runtime environment has unsafe permissions' >&2; exit 2 ;;
    esac
    echo '   Heimdall runtime environment preserved (provisioning source omitted)'
  else
    echo '   WARNING: Heimdall runtime environment not configured; pushes will be skipped'
  fi

  rendered_dir=\$(mktemp -d /tmp/brokkr-nas-units.XXXXXX)
  trap 'rm -rf \$rendered_dir' EXIT
  sudo env BROKKR_RUNTIME_USER='$RUNTIME_USER' BROKKR_RUNTIME_HOME='$RUNTIME_HOME' BROKKR_DEPLOY_TARGET='$DEPLOY_TARGET' BROKKR_REGISTRY_PATH='$REGISTRY_PATH' \
    '$DEPLOY_TARGET/scripts/render-systemd-failure-units.sh' \$rendered_dir
  for executable in '$DEPLOY_TARGET/scripts/health-snapshot.sh' '$DEPLOY_TARGET/scripts/systemd-failure-monitor.sh'; do
    if ! sudo test -f \$executable || sudo test -L \$executable || ! sudo test -x \$executable; then
      echo 'ERROR: required deployed executable is missing, symlinked, or not executable' >&2
      exit 2
    fi
  done
  sudo systemd-analyze verify \
    \$rendered_dir/brokkr-health.service \
    \$rendered_dir/brokkr-systemd-failure@.service \
    \$rendered_dir/brokkr-systemd-failure-sweep.service \
    '$DEPLOY_TARGET/systemd/brokkr-health.timer' \
    '$DEPLOY_TARGET/systemd/brokkr-systemd-failure-sweep.timer'

  sudo install -m 0644 \$rendered_dir/brokkr-health.service /etc/systemd/system/brokkr-health.service
  sudo install -m 0644 '$DEPLOY_TARGET/systemd/brokkr-health.timer' /etc/systemd/system/brokkr-health.timer
  sudo install -m 0644 \$rendered_dir/brokkr-systemd-failure@.service /etc/systemd/system/brokkr-systemd-failure@.service
  sudo install -m 0644 \$rendered_dir/brokkr-systemd-failure-sweep.service /etc/systemd/system/brokkr-systemd-failure-sweep.service
  sudo install -m 0644 '$DEPLOY_TARGET/systemd/brokkr-systemd-failure-sweep.timer' /etc/systemd/system/brokkr-systemd-failure-sweep.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now brokkr-health.timer brokkr-systemd-failure-sweep.timer

  echo '-- running one snapshot now --'
  sudo systemctl start brokkr-health.service
  sleep 2
  echo '-- health.json --'; sudo -u '$RUNTIME_USER' cat '$RUNTIME_HOME/.local/state/brokkr/health.json' 2>/dev/null || echo '(none)'
  echo; echo '-- journal --'; sudo journalctl -u brokkr-health.service -n 6 --no-pager 2>/dev/null
  echo '-- timer --'; sudo systemctl list-timers brokkr-health.timer --no-pager 2>/dev/null | sed -n '1,2p'
  echo '-- failure-monitor timer --'; sudo systemctl list-timers brokkr-systemd-failure-sweep.timer --no-pager 2>/dev/null | sed -n '1,2p'
"
echo "==> Done. No Heimdall credential values or source paths were printed."
