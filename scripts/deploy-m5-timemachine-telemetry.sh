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
validate_probe_source() {
  local file=$1 bands_count max_age_count line_count max_age
  validate_source "$file" BROKKR_TM_BANDS_DIR
  ! grep -q '[[:cntrl:]]' "$file" || { echo "refusing: protected runtime input invalid" >&2; exit 2; }
  [ "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10 ] || {
    echo "refusing: protected runtime input invalid" >&2
    exit 2
  }
  bands_count="$(grep -Ec '^BROKKR_TM_BANDS_DIR=/.*$' "$file" || true)"
  max_age_count="$(grep -Ec '^BROKKR_TM_MAX_AGE_SECS=[1-9][0-9]*$' "$file" || true)"
  line_count="$(wc -l < "$file" | tr -d '[:space:]')"
  [ "$bands_count" -eq 1 ] && [ "$max_age_count" -le 1 ] &&
    [ "$line_count" -eq $((bands_count + max_age_count)) ] || {
      echo "refusing: protected runtime input invalid" >&2
      exit 2
    }
  max_age="$(sed -n 's/^BROKKR_TM_MAX_AGE_SECS=//p' "$file")"
  if [ -n "$max_age" ] && { [ "${#max_age}" -gt 7 ] || [ "$max_age" -gt 2678400 ]; }; then
    echo "refusing: protected runtime input invalid" >&2
    exit 2
  fi
}
validate_probe_source "$probe_source"
validate_source "$delivery_source" HEIMDALL_HUB_URL HEIMDALL_FLEET_TOKEN

release_root="${BROKKR_TM_RELEASE_ROOT:-$HOME/.local/lib/brokkr/timemachine-telemetry}"
release="$release_root/releases/$expected_revision"
unit_dir="$config_home/systemd/user"
unit="$unit_dir/brokkr-timemachine-telemetry.service"
timer="$unit_dir/brokkr-timemachine-telemetry.timer"
if [ -z "$apply" ]; then
  echo "DRY-RUN: verified source $expected_revision; release target $release"
  exit 0
fi

install -d -m 700 "$release_root"
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
systemctl --user enable brokkr-timemachine-telemetry.timer
echo "installed revision-bound release; rollback: restore $unit.previous-$expected_revision (if present), disable timer, daemon-reload"
