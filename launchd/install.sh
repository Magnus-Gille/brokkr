#!/usr/bin/env bash
set -euo pipefail

# Brokkr · install/manage the offsite-photos LaunchAgent — runs ON THE MAC.
#
# Renders the versioned plist (substituting the repo path + $HOME) into
# ~/Library/LaunchAgents/ and (re)bootstraps it in the per-user GUI domain.
#
# Usage:
#   ./launchd/install.sh            install/refresh + enable the daily timer
#   ./launchd/install.sh run        install/refresh, then kick a run now (foreground-ish)
#   ./launchd/install.sh status     show whether the agent is loaded + last exit
#   ./launchd/install.sh uninstall  bootout + remove the plist

LABEL="io.grimnir.brokkr.offsite-photos"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROKKR_DIR="$(cd "$HERE/.." && pwd)"
SRC="$HERE/${LABEL}.plist"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST="$DEST_DIR/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: launchd is macOS-only (this is $(uname -s))" >&2; exit 1; }

render() {
  mkdir -p "$DEST_DIR" "$HOME/Library/Logs/brokkr"
  sed -e "s#__BROKKR_DIR__#${BROKKR_DIR}#g" -e "s#__HOME__#${HOME}#g" "$SRC" > "$DEST"
  chmod 644 "$DEST"
  echo "rendered → $DEST"
}

bootstrap() {
  # bootout first so a re-run picks up plist changes; ignore "not loaded".
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$DEST"
  launchctl enable "$DOMAIN/$LABEL"
  echo "bootstrapped $DOMAIN/$LABEL (daily 04:15)"
}

# The panel push is best-effort, so a failed unattended run only surfaces on the Heimdall
# dashboard if the credentials are present. Warn (don't block) so the operator knows a
# failure would otherwise be visible only in the log — see docs/offsite-photos-backup.md §5.
warn_if_no_heimdall() {
  local env_file="${BROKKR_OFFSITE_ENV_FILE:-$HOME/.config/brokkr/offsite-photos.env}"
  if [ -n "${HEIMDALL_HUB_URL:-}" ] && [ -n "${HEIMDALL_FLEET_TOKEN:-}" ]; then return 0; fi
  if [ -f "$env_file" ] && grep -q '^HEIMDALL_HUB_URL=' "$env_file" && grep -q '^HEIMDALL_FLEET_TOKEN=' "$env_file"; then return 0; fi
  echo "WARN: no HEIMDALL_HUB_URL/FLEET_TOKEN in env ($env_file) — a failed backup will NOT" >&2
  echo "      push a fail panel; it'll only show in ~/Library/Logs/brokkr/. See doc §5." >&2
}

case "${1:-install}" in
  install)   render; bootstrap; warn_if_no_heimdall ;;
  run)       render; bootstrap; warn_if_no_heimdall; echo "kicking a run now…"; launchctl kickstart -k "$DOMAIN/$LABEL"; echo "started — tail ~/Library/Logs/brokkr/offsite-photos-backup.log" ;;
  status)    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|last exit|program =' || echo "not loaded" ;;
  uninstall) launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$DEST"; echo "removed $DEST" ;;
  *)         echo "usage: $0 {install|run|status|uninstall}" >&2; exit 2 ;;
esac
