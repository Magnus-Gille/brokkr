#!/usr/bin/env bash
set -euo pipefail

# Brokkr · install/manage the agent-cli-update LaunchAgent — runs ON THE MAC.
#
# Renders the versioned plist (substituting the repo path + $HOME) into
# ~/Library/LaunchAgents/ and (re)bootstraps it in the per-user GUI domain. The agent
# runs scripts/agent-cli-update.sh from this checkout, like the offsite-photos agent.
#
# Usage:
#   ./launchd/install-agent-cli-update.sh            install/refresh + enable the schedule
#   ./launchd/install-agent-cli-update.sh run        install/refresh, then start a run now
#   ./launchd/install-agent-cli-update.sh status     show whether the agent is loaded + last exit
#   ./launchd/install-agent-cli-update.sh uninstall  bootout + remove the plist

LABEL="io.grimnir.brokkr.agent-cli-update"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROKKR_DIR="$(cd "$HERE/.." && pwd)"
SRC="$HERE/${LABEL}.plist"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST="$DEST_DIR/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: launchd is macOS-only (this is $(uname -s))" >&2; exit 1; }

# The paths are substituted with sed and land inside XML, so refuse characters that would
# break either rather than render a plist that quietly points somewhere else.
for value in "$BROKKR_DIR" "$HOME"; do
  case "$value" in
    /*) ;;
    *) echo "ERROR: '$value' is not an absolute path" >&2; exit 1 ;;
  esac
  case "$value" in
    *[\#\&\\\<\>\"]*|*$'\n'*) echo "ERROR: '$value' contains a character that cannot be rendered into the plist" >&2; exit 1 ;;
  esac
done

render() {
  mkdir -p "$DEST_DIR" "$HOME/Library/Logs/brokkr"
  sed -e "s#__BROKKR_DIR__#${BROKKR_DIR}#g" -e "s#__HOME__#${HOME}#g" "$SRC" > "$DEST"
  chmod 644 "$DEST"
  echo "rendered → $DEST"
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$DEST" >/dev/null || { echo "ERROR: rendered plist is invalid" >&2; exit 1; }; fi
}

bootstrap() {
  # bootout first so a re-run picks up plist changes; ignore "not loaded".
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$DEST"
  launchctl enable "$DOMAIN/$LABEL"
  echo "bootstrapped $DOMAIN/$LABEL (04:17, 10:17, 16:17, 22:17 local)"
}

case "${1:-install}" in
  install)   render; bootstrap ;;
  # No -k: a run that is already in progress is left alone rather than killed mid-install.
  run)       render; bootstrap; echo "starting a run now…"; launchctl kickstart "$DOMAIN/$LABEL"; echo "started — tail ~/Library/Logs/brokkr/agent-cli-update.launchd.log; state in ~/.local/state/brokkr/agent-cli-update.json" ;;
  status)    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|last exit|program =' || echo "not loaded" ;;
  uninstall) launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$DEST"; echo "removed $DEST" ;;
  *)         echo "usage: $0 {install|run|status|uninstall}" >&2; exit 2 ;;
esac
