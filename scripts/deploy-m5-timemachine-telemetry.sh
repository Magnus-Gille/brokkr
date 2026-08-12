#!/usr/bin/env bash
# Install a revision-bound M5 Time Machine telemetry release (brokkr#53).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/deploy-source.sh
source "$HERE/scripts/lib/deploy-source.sh"
usage() { echo "usage: $0 EXPECTED_SOURCE FULL_COMMIT_SHA [--apply]" >&2; exit 2; }
[ "$#" -ge 2 ] || usage
expected_source=$1; expected_revision=$2; apply=${3:-}
[ -z "$apply" ] || [ "$apply" = --apply ] || usage
cd "$HERE"
verify_brokkr_deploy_source_binding "$HERE" "$expected_source" "$expected_revision"
[ "$(hostname)" = "${BROKKR_M5_HOSTNAME:-m5}" ] || { echo "refusing: M5 host required" >&2; exit 2; }

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
probe_source="$config_home/brokkr/timemachine-probe.env"
delivery_source="$config_home/brokkr/heimdall.env"
validate_source() { # file required keys
  local file=$1 first=$2 second=${3:-} owner mode
  [ -f "$file" ] && [ ! -L "$file" ] || { echo "refusing: protected runtime input unavailable" >&2; exit 2; }
  if owner="$(stat -c '%u' "$file" 2>/dev/null)"; then :; else owner="$(stat -f '%u' "$file")"; fi
  if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then :; else mode="$(stat -f '%Lp' "$file")"; fi
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 600 ] || { echo "refusing: protected runtime input unsafe" >&2; exit 2; }
  grep -Eq "^${first}=.+$" "$file" || { echo "refusing: protected runtime input incomplete" >&2; exit 2; }
  [ -z "$second" ] || grep -Eq "^${second}=.+$" "$file" || { echo "refusing: protected runtime input incomplete" >&2; exit 2; }
}
validate_source "$probe_source" BROKKR_TM_BANDS_DIR
validate_source "$delivery_source" HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN

release_root="${BROKKR_TM_RELEASE_ROOT:-$HOME/.local/lib/brokkr/timemachine-telemetry}"
release="$release_root/releases/$expected_revision"
unit_dir="$config_home/systemd/user"
unit="$unit_dir/brokkr-timemachine-telemetry.service"
timer="$unit_dir/brokkr-timemachine-telemetry.timer"
# This is intentionally the exact path allowed by the unit's ReadWritePaths.
# It must exist before the service namespace is constructed; telemetry.sh cannot
# create it after systemd has rejected the namespace setup.
state_dir="$HOME/.local/state/brokkr"
if [ -z "$apply" ]; then
  echo "DRY-RUN: verified source $expected_revision; release target $release"
  exit 0
fi

install -d -m 700 "$release_root" "$state_dir"
stage="$(mktemp -d "$release_root/.stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
install -d -m 700 "$stage/timemachine" "$stage/heimdall" "$unit_dir" "$release_root/releases"
install -m 755 "$HERE/timemachine/telemetry.sh" "$stage/timemachine/telemetry.sh"
install -m 755 "$HERE/timemachine/destination-probe.py" "$stage/timemachine/destination-probe.py"
install -m 755 "$HERE/heimdall/push.sh" "$stage/heimdall/push.sh"
[ ! -e "$release" ] || { echo "refusing: revision release already exists" >&2; exit 2; }
mv "$stage" "$release"; trap - EXIT
rendered="$release/brokkr-timemachine-telemetry.service"
sed "s/@REVISION@/$expected_revision/g" "$HERE/systemd/m5/user/brokkr-timemachine-telemetry.service" > "$rendered"
[ ! -f "$unit" ] || cp "$unit" "$unit.previous-$expected_revision"
install -m 644 "$rendered" "$unit"
install -m 644 "$HERE/systemd/m5/user/brokkr-timemachine-telemetry.timer" "$timer"
systemctl --user daemon-reload
# A source warning is valid telemetry and telemetry.sh exits zero after a
# successful delivery.  Validate the actual installed unit before its timer is
# activated, so a bad source/credential/transport does not look installed.
systemctl --user start brokkr-timemachine-telemetry.service
systemctl --user enable --now brokkr-timemachine-telemetry.timer
systemctl --user is-enabled --quiet brokkr-timemachine-telemetry.timer
systemctl --user is-active --quiet brokkr-timemachine-telemetry.timer
echo "installed revision-bound release; timer is enabled and active; rollback: restore $unit.previous-$expected_revision (if present), disable timer, daemon-reload"
