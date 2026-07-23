#!/usr/bin/env bash
# Brokkr · render control-node system units for an explicit runtime identity.
#
# The tracked units retain safe clean-install defaults. Deployers call this
# renderer on the target host to substitute only validated, non-secret runtime
# values into copies under /etc/systemd/system.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-}"
RUNTIME_USER="${BROKKR_RUNTIME_USER:-brokkr}"
RUNTIME_HOME="${BROKKR_RUNTIME_HOME:-/home/$RUNTIME_USER}"
DEPLOY_TARGET="${BROKKR_DEPLOY_TARGET:-/opt/brokkr}"
REGISTRY_PATH="${BROKKR_REGISTRY_PATH:-/opt/grimnir/services.json}"

usage() {
  echo "usage: $0 <systemd-unit-output-dir>" >&2
  exit 64
}
valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/@:+-]+$ ]]
}

[ -n "$OUT_DIR" ] && valid_path "$OUT_DIR" || usage
if [[ ! "$RUNTIME_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "brokkr render: invalid BROKKR_RUNTIME_USER" >&2
  exit 64
fi
if ! valid_path "$RUNTIME_HOME"; then
  echo "brokkr render: invalid BROKKR_RUNTIME_HOME" >&2
  exit 64
fi
if ! valid_path "$DEPLOY_TARGET"; then
  echo "brokkr render: invalid BROKKR_DEPLOY_TARGET" >&2
  exit 64
fi
if ! valid_path "$REGISTRY_PATH"; then
  echo "brokkr render: invalid BROKKR_REGISTRY_PATH" >&2
  exit 64
fi
if [ ! -d "$OUT_DIR" ]; then
  echo "brokkr render: output directory does not exist" >&2
  exit 2
fi

render() {
  local unit="$1"
  local source="$HERE/systemd/$unit" tmp
  tmp="$(mktemp "$OUT_DIR/.$unit.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  sed \
    -e "s|^User=brokkr$|User=$RUNTIME_USER|" \
    -e "s|^WorkingDirectory=/opt/brokkr$|WorkingDirectory=$DEPLOY_TARGET|" \
    -e "s|^Environment=REGISTRY_PATH=/opt/grimnir/services.json$|Environment=REGISTRY_PATH=$REGISTRY_PATH|" \
    -e "s|^EnvironmentFile=-/home/brokkr/.config/brokkr/env$|EnvironmentFile=-$RUNTIME_HOME/.config/brokkr/env|" \
    -e "s|^ExecStart=/opt/brokkr/|ExecStart=$DEPLOY_TARGET/|" \
    "$source" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$OUT_DIR/$unit"
  trap - RETURN
}

for unit in \
  brokkr-maintenance-os.service \
  brokkr-maintenance-deps.service \
  brokkr-systemd-failure@.service \
  brokkr-systemd-failure-sweep.service; do
  render "$unit"
done
