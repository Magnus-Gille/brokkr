#!/usr/bin/env bash
set -euo pipefail

# Brokkr · install/manage the agent-cli-update LaunchAgent — runs ON THE MAC.
#
# Copies scripts/agent-cli-update.sh as committed at this checkout's HEAD into
# ~/.local/lib/brokkr/agent-cli-update/releases/<full-sha>/, renders the versioned plist
# (pointing at that copy, + $HOME) into ~/Library/LaunchAgents/ and (re)bootstraps it in
# the per-user GUI domain. Unlike the offsite-photos agent it never runs the checkout
# itself, so a branch switch or a removed worktree cannot change what launchd runs.
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
UPDATER="scripts/agent-cli-update.sh"
RELEASE_ROOT="$HOME/.local/lib/brokkr/agent-cli-update/releases"
REV=""
RELEASE=""

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: launchd is macOS-only (this is $(uname -s))" >&2; exit 1; }

# The release path (under $HOME) is substituted with sed and lands inside XML, so refuse
# characters that would break either rather than render a plist that quietly points
# somewhere else.
case "$HOME" in
  /*) ;;
  *) echo "ERROR: '$HOME' is not an absolute path" >&2; exit 1 ;;
esac
case "$HOME" in
  *[\#\&\\\<\>\"]*|*$'\n'*) echo "ERROR: '$HOME' contains a character that cannot be rendered into the plist" >&2; exit 1 ;;
esac

# The release is exactly the committed updater at HEAD: an uncommitted edit is refused
# rather than shipped under a revision it does not match.
resolve_release() {
  REV="$(git -C "$BROKKR_DIR" rev-parse --verify HEAD 2>/dev/null)" \
    || { echo "ERROR: $BROKKR_DIR is not a git checkout with a HEAD" >&2; exit 1; }
  [[ "$REV" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { echo "ERROR: unexpected HEAD revision '$REV'" >&2; exit 1; }
  if ! git -C "$BROKKR_DIR" diff --quiet HEAD -- "$UPDATER"; then
    echo "ERROR: $UPDATER has uncommitted changes; commit them so the release is exactly $REV" >&2
    exit 1
  fi
  RELEASE="$RELEASE_ROOT/$REV"
}

install_release() {
  local tmp
  mkdir -p "$RELEASE/scripts"
  tmp="$(mktemp "$RELEASE/scripts/.agent-cli-update.sh.XXXXXX")"
  if ! git -C "$BROKKR_DIR" show "$REV:$UPDATER" >"$tmp"; then
    rm -f "$tmp"
    echo "ERROR: cannot read $UPDATER at $REV" >&2
    exit 1
  fi
  chmod 755 "$tmp"
  mv -f "$tmp" "$RELEASE/$UPDATER"
  echo "installed release → $RELEASE"
}

# Renders into a temporary file, lints it, and only then replaces the installed plist.
# RENDER_CHANGED says whether the installed plist actually changed.
RENDER_CHANGED=0
render() {
  local tmp
  mkdir -p "$DEST_DIR" "$HOME/Library/Logs/brokkr"
  tmp="$DEST.new.$$"
  sed -e "s#__RELEASE__#${RELEASE}#g" -e "s#__HOME__#${HOME}#g" "$SRC" > "$tmp"
  chmod 644 "$tmp"
  if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp" >/dev/null; then
    rm -f "$tmp"; echo "ERROR: rendered plist is invalid" >&2; exit 1
  fi
  if [ -f "$DEST" ] && cmp -s "$tmp" "$DEST"; then
    rm -f "$tmp"; RENDER_CHANGED=0; echo "unchanged → $DEST"
  else
    mv -f "$tmp" "$DEST"; RENDER_CHANGED=1; echo "rendered → $DEST"
  fi
}

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
job_state() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk -F' = ' '/^[[:space:]]*state = /{print $2; exit}'; }
# A bootout stops a running job, which would cut an update off mid-install (or mid-rollback),
# so neither install nor run touches the agent while it is running.
refuse_if_running() {
  if [ "$(job_state)" = running ]; then
    echo "ERROR: $LABEL is running an update right now; retry when it has finished (launchctl print $DOMAIN/$LABEL)" >&2
    exit 1
  fi
}

bootstrap() {
  # bootout first so a re-run picks up plist changes; ignore "not loaded".
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$DEST"
  launchctl enable "$DOMAIN/$LABEL"
  echo "bootstrapped $DOMAIN/$LABEL (04:17, 10:17, 16:17, 22:17 local)"
}

case "${1:-install}" in
  install)   resolve_release; refuse_if_running; install_release; render; bootstrap ;;
  # An idle, loaded job with an unchanged plist is only kicked: no bootout. No -k either, so a
  # run that starts in the meantime is left alone rather than killed.
  run)       resolve_release; refuse_if_running; install_release; render
             if [ "$RENDER_CHANGED" = 1 ] || ! loaded; then bootstrap; fi
             echo "starting a run now…"; launchctl kickstart "$DOMAIN/$LABEL"; echo "started — tail ~/Library/Logs/brokkr/agent-cli-update.launchd.log; state in ~/.local/state/brokkr/agent-cli-update.json" ;;
  status)    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|last exit|program =' || echo "not loaded" ;;
  uninstall) launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -f "$DEST"; echo "removed $DEST (release copies under $RELEASE_ROOT are kept)" ;;
  *)         echo "usage: $0 {install|run|status|uninstall}" >&2; exit 2 ;;
esac
