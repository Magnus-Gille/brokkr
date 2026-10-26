#!/usr/bin/env bash
# Hermetic gates for scripts/setup-host-patching.sh (Grimnir ADR-009). ssh is a fake on PATH that
# runs the command string against a per-host temp "remote root": /etc/ is rewritten into that
# root, and sudo, apt-get, systemctl and unattended-upgrade are fakes that only record what they
# were asked to do. No real host, network or package manager is touched.
# shellcheck disable=SC2016,SC2034 # assertions are evaluated later by check/eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/test/lib/fixture-cleanup.sh
source "$HERE/lib/fixture-cleanup.sh"
TMP="$(fixture_cleanup_alloc)"
trap 'fixture_cleanup_on_exit "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

BIN="$TMP/bin"; RBIN="$TMP/rbin"; ROOTS="$TMP/roots"; CALLS="$TMP/calls"
mkdir -p "$BIN" "$RBIN" "$ROOTS"
: >"$CALLS"

cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# usage: ssh [-o opt]... TARGET COMMAND  (stdin is forwarded to the command)
while [[ "${1:-}" == -o ]]; do shift 2; done
target=$1; shift
host=${target#*@}
printf 'ssh %s %s\n' "$target" "$*" >>"$MOCK_CALLS"
root="$MOCK_ROOTS/$host"
[[ -d "$root" ]] || exit 255
cmd=$(printf '%s' "$1" | sed "s#/etc/#$root/etc/#g")
exec env MOCK_ROOT="$root" PATH="$MOCK_RBIN:$PATH" sh -c "$cmd"
FAKE
cat >"$RBIN/sudo" <<'FAKE'
#!/bin/sh
exec env "$@"
FAKE
cat >"$RBIN/apt-get" <<'FAKE'
#!/bin/sh
echo "apt-get $*" >>"$MOCK_ROOT/actions.log"
case "$*" in *install*) exit "${MOCK_APT_INSTALL_RC:-0}" ;; esac
exit 0
FAKE
cat >"$RBIN/systemctl" <<'FAKE'
#!/bin/sh
echo "systemctl $*" >>"$MOCK_ROOT/actions.log"
exit 0
FAKE
cat >"$RBIN/unattended-upgrade" <<'FAKE'
#!/bin/sh
echo "unattended-upgrade $*" >>"$MOCK_ROOT/actions.log"
case "$*" in
  *-d*) echo "Initial blacklist: "; echo "Allowed origins are: o=Fixture,a=fixture-stable,l=Fixture-Label" ;;
esac
exit "${MOCK_UU_RC:-0}"
FAKE
chmod +x "$BIN/ssh" "$RBIN/sudo" "$RBIN/apt-get" "$RBIN/systemctl" "$RBIN/unattended-upgrade"

GOOD_AUTO=$'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
OFF_AUTO=$'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n'
SENTINEL_50=$'// distribution 50unattended-upgrades, must survive\n'

# make_host NAME ID ID_LIKE [20auto-upgrades content; "-" for none]
make_host() {
  local r="$ROOTS/$1"
  rm -rf "$r"; mkdir -p "$r/etc/apt/apt.conf.d"
  { printf 'PRETTY_NAME="Fixture OS"\nID=%s\n' "$2"; [[ -n "$3" ]] && printf 'ID_LIKE="%s"\n' "$3"; } >"$r/etc/os-release"
  if [[ "${4:--}" != "-" ]]; then
    printf '%s' "$4" >"$r/etc/apt/apt.conf.d/20auto-upgrades"
    printf '%s' "$SENTINEL_50" >"$r/etc/apt/apt.conf.d/50unattended-upgrades"
  fi
}
conf() { printf '%s/%s/etc/apt/apt.conf.d' "$ROOTS" "$1"; }
written() { (cd "$(conf "$1")" && ls | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'); }
actions() { cat "$ROOTS/$1/actions.log" 2>/dev/null || true; }
same_file() { cmp -s "$1" "$2"; }

OUT=""; RC=0
run() { # args...  (env MOCK_* set by the caller via export)
  : >"$CALLS"
  OUT="$(env PATH="$BIN:$PATH" DEPLOY_USER=tester MOCK_CALLS="$CALLS" MOCK_ROOTS="$ROOTS" MOCK_RBIN="$RBIN" \
    REGISTRY_PATH="$TMP/no-registry.json" bash "$ROOT/scripts/setup-host-patching.sh" "$@" 2>&1)"; RC=$?
}
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${OUT:-}" ]] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -40; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

DEBIAN_SET="20auto-upgrades 50unattended-upgrades 51brokkr-claude-code 52brokkr-debian-updates"
UBUNTU_SET="20auto-upgrades 50unattended-upgrades 51brokkr-claude-code 52brokkr-ubuntu-updates"

echo "setup-host-patching.test.sh"

# ── Debian family ────────────────────────────────────────────────────────────
for spec in "debian|debian|" "raspbian|raspbian|debian" "derivative|somepi|debian"; do
  IFS='|' read -r h id like <<<"$spec"
  make_host "$h" "$id" "$like" -
  run "$h"
  check "$h: succeeds" '[[ "$RC" -eq 0 ]]'
  check "$h: writes exactly the Debian-family set" '[[ "$(written "$h")" == "$DEBIAN_SET" ]]'
  for f in 20auto-upgrades 50unattended-upgrades 51brokkr-claude-code 52brokkr-debian-updates; do
    check "$h: $f matches the repository copy" 'same_file "$ROOT/apt/$f" "$(conf "$h")/$f"'
  done
  check "$h: installs the patcher and enables the apt timers" \
    'actions "$h" | grep -q "install -y unattended-upgrades needrestart" && actions "$h" | grep -q "enable --now apt-daily.timer apt-daily-upgrade.timer"'
  check "$h: prints the effective Allowed origins" '[[ "$OUT" == *"Allowed origins are: o=Fixture"* ]]'
  check "$h: reports the detected OS" '[[ "$OUT" == *"OS: debian"* ]]'
done

# ── Ubuntu ───────────────────────────────────────────────────────────────────
make_host ubu ubuntu debian "$GOOD_AUTO"
run ubu
check "ubuntu: succeeds" '[[ "$RC" -eq 0 ]]'
check "ubuntu: writes only the two drop-ins beside the distribution files" \
  '[[ "$(written ubu)" == "$UBUNTU_SET" ]]'
printf '%s' "$SENTINEL_50" >"$TMP/expect50"
printf "%s" "$GOOD_AUTO" >"$TMP/expect20"
check "ubuntu: the distribution 50unattended-upgrades is untouched" 'same_file "$TMP/expect50" "$(conf ubu)/50unattended-upgrades"'
check "ubuntu: the distribution 20auto-upgrades is untouched" 'same_file "$TMP/expect20" "$(conf ubu)/20auto-upgrades"'
check "ubuntu: 51brokkr-claude-code matches the repository copy" 'same_file "$ROOT/apt/51brokkr-claude-code" "$(conf ubu)/51brokkr-claude-code"'
check "ubuntu: 52brokkr-ubuntu-updates matches the repository copy" 'same_file "$ROOT/apt/52brokkr-ubuntu-updates" "$(conf ubu)/52brokkr-ubuntu-updates"'
check "ubuntu: the Debian drop-in is never pushed" '[[ ! -e "$(conf ubu)/52brokkr-debian-updates" ]]'
check "ubuntu: no ssh command ever targets 20auto-upgrades or 50unattended-upgrades" \
  '! grep -E "tee .*/(20auto-upgrades|50unattended-upgrades)" "$CALLS"'
check "ubuntu: reports the detected OS" '[[ "$OUT" == *"OS: ubuntu"* ]]'
check "ubuntu: prints the effective Allowed origins" '[[ "$OUT" == *"Allowed origins are: o=Fixture"* ]]'

# Ubuntu whose periodic unattended-upgrade is off, or whose 20auto-upgrades is missing, fails
# clearly and changes no configuration.
make_host ubu-off ubuntu debian "$OFF_AUTO"
run ubu-off
check "ubuntu with periodic unattended-upgrade off: fails the host" '[[ "$RC" -ne 0 ]]'
check "ubuntu with periodic unattended-upgrade off: clear message" \
  '[[ "$OUT" == *"20auto-upgrades"* && "$OUT" == *"APT::Periodic::Unattended-Upgrade"* ]]'
check "ubuntu with periodic unattended-upgrade off: no drop-in pushed" '[[ "$(written ubu-off)" == "20auto-upgrades 50unattended-upgrades" ]]'
printf '%s' "$OFF_AUTO" >"$TMP/expect-off"
check "ubuntu with periodic unattended-upgrade off: distribution file untouched" 'same_file "$TMP/expect-off" "$(conf ubu-off)/20auto-upgrades"'

make_host ubu-missing ubuntu debian -
run ubu-missing
check "ubuntu without 20auto-upgrades: fails the host with nothing written" \
  '[[ "$RC" -ne 0 && -z "$(written ubu-missing)" && "$OUT" == *"20auto-upgrades"* ]]'

# ── Anything else ────────────────────────────────────────────────────────────
make_host odd alpine "" -
run odd
check "unknown OS: fails the host" '[[ "$RC" -ne 0 && "$OUT" == *"unsupported OS"* ]]'
check "unknown OS: nothing written and no package or service action" '[[ -z "$(written odd)" && -z "$(actions odd)" ]]'

make_host mint linuxmint "ubuntu debian" -
run mint
check "an Ubuntu derivative (ID_LIKE ubuntu debian) is not treated as Debian" \
  '[[ "$RC" -ne 0 && -z "$(written mint)" && -z "$(actions mint)" ]]'

make_host nolike fedora "rhel centos" -
run nolike
check "a non-Debian ID_LIKE fails the host" '[[ "$RC" -ne 0 && -z "$(written nolike)" && -z "$(actions nolike)" ]]'

make_host noos debian "" -
rm -f "$ROOTS/noos/etc/os-release"
run noos
check "missing /etc/os-release fails the host with nothing written" \
  '[[ "$RC" -ne 0 && -z "$(written noos)" && -z "$(actions noos)" ]]'

# ── Failures stay per host ───────────────────────────────────────────────────
make_host good debian "" -
make_host odd2 alpine "" -
run odd2 good
check "one unsupported host does not stop the others" \
  '[[ "$RC" -ne 0 && "$(written good)" == "$DEBIAN_SET" && -z "$(written odd2)" ]]'

make_host badval debian "" -
export MOCK_UU_RC=1
run badval
unset MOCK_UU_RC
check "a failing unattended-upgrade --dry-run validation fails the host" '[[ "$RC" -ne 0 && "$OUT" == *"validation failed"* ]]'

make_host badapt debian "" -
export MOCK_APT_INSTALL_RC=100
run badapt
unset MOCK_APT_INSTALL_RC
check "a failed package install fails the host before any config push" '[[ "$RC" -ne 0 && -z "$(written badapt)" ]]'

# ── --dry-run ────────────────────────────────────────────────────────────────
make_host dr-deb debian "" -
run --dry-run dr-deb
check "dry-run debian: succeeds" '[[ "$RC" -eq 0 ]]'
check "dry-run debian: reports the OS and exactly the four files" \
  '[[ "$OUT" == *"OS: debian"* && "$(grep "would: push" <<<"$OUT")" == "  would: push 20auto-upgrades + 50unattended-upgrades + 51brokkr-claude-code + 52brokkr-debian-updates to /etc/apt/apt.conf.d/" ]]'
check "dry-run debian: changes nothing" '[[ -z "$(written dr-deb)" && -z "$(actions dr-deb)" ]]'

make_host dr-ubu ubuntu debian "$GOOD_AUTO"
run --dry-run dr-ubu
check "dry-run ubuntu: reports the OS and only the two drop-ins" \
  '[[ "$RC" -eq 0 && "$OUT" == *"OS: ubuntu"* && "$(grep "would: push" <<<"$OUT")" == "  would: push 51brokkr-claude-code + 52brokkr-ubuntu-updates to /etc/apt/apt.conf.d/" ]]'
check "dry-run ubuntu: changes nothing" '[[ "$(written dr-ubu)" == "20auto-upgrades 50unattended-upgrades" && -z "$(actions dr-ubu)" ]]'

make_host dr-odd alpine "" -
run --dry-run dr-odd
check "dry-run unknown OS: fails the host and changes nothing" '[[ "$RC" -ne 0 && "$OUT" == *"unsupported OS"* && -z "$(written dr-odd)" && -z "$(actions dr-odd)" ]]'
check "dry-run never calls tee, a package manager or systemctl over ssh" '! grep -E "tee |apt-get|systemctl" "$CALLS"'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
