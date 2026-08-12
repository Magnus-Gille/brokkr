#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; HOME_DIR="$TMP/home"; mkdir -p "$REPO" "$HOME_DIR/.config/brokkr" "$TMP/bin"; REPO="$(cd "$REPO" && pwd -P)"
cp -R "$ROOT/scripts" "$ROOT/timemachine" "$ROOT/heimdall" "$ROOT/systemd" "$REPO/"
git init -q "$REPO"; git -C "$REPO" config user.name test; git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .; git -C "$REPO" commit -qm initial; SHA="$(git -C "$REPO" rev-parse HEAD)"
printf 'BROKKR_TM_BANDS_DIR=/private/bands\n' > "$HOME_DIR/.config/brokkr/timemachine-probe.env"
printf 'HEIMDALL_HUB_URL=https://example.invalid/api\nHEIMDALL_FLEET_TOKEN=test\n' > "$HOME_DIR/.config/brokkr/heimdall.env"; chmod 600 "$HOME_DIR/.config/brokkr"/*.env
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
EOF
chmod +x "$TMP/bin/systemctl"
SCRIPT="$REPO/scripts/deploy-m5-timemachine-telemetry.sh"
HOST_NAME="$(hostname)"; export HOME="$HOME_DIR" PATH="$TMP/bin:$PATH" BROKKR_M5_HOSTNAME="$HOST_NAME" SYSTEMCTL_LOG="$TMP/systemctl.log"
# CI may export XDG_CONFIG_HOME for the runner; this fixture intentionally
# exercises the HOME-default install layout it created above.
unset XDG_CONFIG_HOME
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; }; check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run(){ # shellcheck disable=SC2034 # assertions consume OUT/RC through check/eval
  OUT="$("$@" 2>&1)" || RC=$?; RC=${RC:-0}; }
echo deploy-m5-timemachine-telemetry.test.sh
RC=0; run "$SCRIPT" "$REPO/wrong" "$SHA"; check "wrong source refuses before mutation" '[[ "$RC" -ne 0 && ! -e "$HOME_DIR/.local/lib/brokkr" ]]'
RC=0; printf dirty >> "$REPO/timemachine/telemetry.sh"; run "$SCRIPT" "$REPO" "$SHA"; check "dirty source refuses before mutation" '[[ "$RC" -ne 0 && ! -e "$HOME_DIR/.local/lib/brokkr" ]]'; git -C "$REPO" checkout -- timemachine/telemetry.sh
RC=0; run "$SCRIPT" "$REPO" "$SHA" --apply
# shellcheck disable=SC2034 # assertions consume this through check/eval
UNIT="$HOME_DIR/.config/systemd/user/brokkr-timemachine-telemetry.service"
if [[ "$RC" -eq 0 && -f "$UNIT" ]]; then ok "exact clean source installs release"; else bad "exact clean source installs release"; printf '  fixture apply output: %s\n' "$OUT"; fi
check "installed unit avoids canonical checkout" '! grep -q "$REPO" "$UNIT" && grep -q "/releases/$SHA/" "$UNIT"'
check "installer creates unit state directory before first start" '[[ -d "$HOME_DIR/.local/state/brokkr" && "$(stat -f %Lp "$HOME_DIR/.local/state/brokkr" 2>/dev/null || stat -c %a "$HOME_DIR/.local/state/brokkr")" == 700 ]]'
check "runtime service validation precedes timer activation" '[[ "$(grep -nFx -- "--user start brokkr-timemachine-telemetry.service" "$TMP/systemctl.log" | cut -d: -f1)" -lt "$(grep -nFx -- "--user enable --now brokkr-timemachine-telemetry.timer" "$TMP/systemctl.log" | cut -d: -f1)" ]]'
check "timer is enabled and active after install" 'grep -qFx -- "--user is-enabled --quiet brokkr-timemachine-telemetry.timer" "$TMP/systemctl.log" && grep -qFx -- "--user is-active --quiet brokkr-timemachine-telemetry.timer" "$TMP/systemctl.log"'
check "unit timeout exceeds sequential probe and delivery budgets" '[[ "$(sed -nE "s/^TimeoutStartSec=([0-9]+)$/\\1/p" "$ROOT/systemd/m5/user/brokkr-timemachine-telemetry.service")" -gt 30 ]]'
echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
