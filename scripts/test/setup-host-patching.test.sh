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
    REGISTRY_PATH="${TEST_REGISTRY:-$TMP/no-registry.json}" bash "$ROOT/scripts/setup-host-patching.sh" "$@" 2>&1)"; RC=$?
}
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${OUT:-}" ]] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -40; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

DEBIAN_SET="20auto-upgrades 50unattended-upgrades 51brokkr-claude-code 52brokkr-debian-updates"
UBUNTU_SET="20auto-upgrades 50unattended-upgrades 51brokkr-claude-code 52brokkr-ubuntu-updates"
# The security baseline a host NOT approved for regular updates gets (Ubuntu: its own 20/50 + 51).
SECURITY_SET="20auto-upgrades 50unattended-upgrades 51brokkr-claude-code"
# ADR-009 approves regular updates on named hosts only. The hosts below are the ones the tests
# that expect the 52 drop-in are approved for (placeholder names; real IDs are runtime env only).
export BROKKR_REGULAR_UPDATE_HOSTS="debian raspbian derivative ubu good dr-deb dr-ubu"

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

# ── Regular updates only on approved hosts (BROKKR_REGULAR_UPDATE_HOSTS) ─────
# Unlisted hosts get the security baseline only and lose a stale 52brokkr drop-in.
STALE=$'// stale Brokkr regular-update drop-in\n'
stale_52() { # host: both 52 files present
  printf '%s' "$STALE" >"$(conf "$1")/52brokkr-debian-updates"
  printf '%s' "$STALE" >"$(conf "$1")/52brokkr-ubuntu-updates"
}

make_host unl-deb debian "" -
BROKKR_REGULAR_UPDATE_HOSTS="someone-else" run unl-deb
check "unlisted Debian host: succeeds with the security baseline only" '[[ "$RC" -eq 0 && "$(written unl-deb)" == "$SECURITY_SET" ]]'
check "unlisted Debian host: says regular updates are not enabled" '[[ "$OUT" == *"regular updates: not enabled"* ]]'
make_host lst-deb debian "" -
BROKKR_REGULAR_UPDATE_HOSTS="someone-else lst-deb" run lst-deb
check "listed Debian host (one of several IDs): gets the Debian regular-update drop-in" '[[ "$RC" -eq 0 && "$(written lst-deb)" == "$DEBIAN_SET" && "$OUT" == *"regular updates: enabled"* ]]'

make_host unl-ubu ubuntu debian "$GOOD_AUTO"
BROKKR_REGULAR_UPDATE_HOSTS="someone-else" run unl-ubu
check "unlisted Ubuntu host: only 51 beside the distribution files" '[[ "$RC" -eq 0 && "$(written unl-ubu)" == "$SECURITY_SET" && ! -e "$(conf unl-ubu)/52brokkr-ubuntu-updates" ]]'
check "unlisted Ubuntu host: distribution files untouched" 'same_file "$TMP/expect50" "$(conf unl-ubu)/50unattended-upgrades" && same_file "$TMP/expect20" "$(conf unl-ubu)/20auto-upgrades"'
make_host lst-ubu ubuntu debian "$GOOD_AUTO"
BROKKR_REGULAR_UPDATE_HOSTS="lst-ubu" run lst-ubu
check "listed Ubuntu host: gets the Ubuntu regular-update drop-in" '[[ "$RC" -eq 0 && "$(written lst-ubu)" == "$UBUNTU_SET" ]]'

make_host stale-deb debian "" -; stale_52 stale-deb
BROKKR_REGULAR_UPDATE_HOSTS="someone-else" run stale-deb
check "unlisted host with stale 52 drop-ins: both are removed" '[[ "$RC" -eq 0 && "$(written stale-deb)" == "$SECURITY_SET" ]]'
check "unlisted host with stale 52 drop-ins: the run says so" \
  '[[ "$OUT" == *"removed 52brokkr-debian-updates"* && "$OUT" == *"removed 52brokkr-ubuntu-updates"* ]]'
check "unlisted host with stale 52 drop-ins: removal is a sudo rm -f of exactly those files" \
  'grep -F "sudo rm -f /etc/apt/apt.conf.d/52brokkr-debian-updates" "$CALLS" | grep -q . && ! grep -E "rm -f [^ ]*[*]" "$CALLS"'
make_host stale-ubu ubuntu debian "$GOOD_AUTO"; stale_52 stale-ubu
BROKKR_REGULAR_UPDATE_HOSTS="" run stale-ubu
check "unlisted Ubuntu host with stale 52 drop-ins: removed, baseline kept" '[[ "$RC" -eq 0 && "$(written stale-ubu)" == "$SECURITY_SET" ]]'

make_host stale-listed debian "" -; printf '%s' "$STALE" >"$(conf stale-listed)/52brokkr-ubuntu-updates"
BROKKR_REGULAR_UPDATE_HOSTS="stale-listed" run stale-listed
check "listed host: the other OS family's stale drop-in is removed, its own is current" \
  '[[ "$RC" -eq 0 && "$(written stale-listed)" == "$DEBIAN_SET" && "$OUT" == *"removed 52brokkr-ubuntu-updates"* ]] && same_file "$ROOT/apt/52brokkr-debian-updates" "$(conf stale-listed)/52brokkr-debian-updates"'

make_host empty-set debian "" -; stale_52 empty-set
BROKKR_REGULAR_UPDATE_HOSTS="" run empty-set
check "empty setting: no host gets regular updates and stale ones go" '[[ "$RC" -eq 0 && "$(written empty-set)" == "$SECURITY_SET" ]]'
make_host unset-set debian "" -
( unset BROKKR_REGULAR_UPDATE_HOSTS; run unset-set; printf '%s\n%s\n' "$RC" "$(written unset-set)" >"$TMP/unset.out" )
check "unset setting behaves like an empty one" '[[ "$(sed -n 1p "$TMP/unset.out")" == 0 && "$(sed -n 2p "$TMP/unset.out")" == "$SECURITY_SET" ]]'

# An invalid entry fails closed before any host is contacted: ignoring it would silently strip
# regular updates (and the drop-in) from the host it was meant to approve.
make_host inv debian "" -
BROKKR_REGULAR_UPDATE_HOSTS='inv bad;$(id)' run inv
check "invalid entry: exits 2 before contacting any host" '[[ "$RC" -eq 2 && ! -s "$CALLS" && -z "$(written inv)" ]]'
check "invalid entry: says so without echoing it" '[[ "$OUT" == *"BROKKR_REGULAR_UPDATE_HOSTS has an invalid entry"* && "$OUT" != *"bad;"* ]]'

# Matching: the host as given, without .local, or its short name.
make_host box.local debian "" -
BROKKR_REGULAR_UPDATE_HOSTS="box" run box.local
check "an ID matches the host given with .local" '[[ "$RC" -eq 0 && "$(written box.local)" == "$DEBIAN_SET" ]]'
make_host reg-a debian "" -; make_host reg-b debian "" -
cat >"$TMP/registry.json" <<'JSON'
{"components":[{"name":"a","repo":"a","host":"reg-a","deploy":true},{"name":"b","repo":"b","host":"reg-b","deploy":true}]}
JSON
TEST_REGISTRY="$TMP/registry.json" BROKKR_REGULAR_UPDATE_HOSTS="reg-a" run
check "registry-derived host list: only the listed registry host gets regular updates" \
  '[[ "$RC" -eq 0 && "$(written reg-a)" == "$DEBIAN_SET" && "$(written reg-b)" == "$SECURITY_SET" ]]'

# --dry-run shows the decision per host and changes nothing (stale files are only reported).
make_host dr-lst debian "" -; make_host dr-unl debian "" -; stale_52 dr-unl
BROKKR_REGULAR_UPDATE_HOSTS="dr-lst" run --dry-run dr-lst dr-unl
check "dry-run: listed host decision and push list" \
  '[[ "$OUT" == *"regular updates: enabled"* && "$OUT" == *"would: push 20auto-upgrades + 50unattended-upgrades + 51brokkr-claude-code + 52brokkr-debian-updates to"* ]]'
check "dry-run: unlisted host decision, baseline-only push list" \
  '[[ "$OUT" == *"regular updates: not enabled"* && "$OUT" == *"would: push 20auto-upgrades + 50unattended-upgrades + 51brokkr-claude-code to"* ]]'
check "dry-run: reports the stale drop-ins it would remove, and removes nothing" \
  '[[ "$OUT" == *"would: remove 52brokkr-debian-updates"* && "$OUT" == *"would: remove 52brokkr-ubuntu-updates"* && "$(written dr-unl)" == "52brokkr-debian-updates 52brokkr-ubuntu-updates" && -z "$(written dr-lst)" ]]'
check "dry-run: no rm, tee, package manager or systemctl over ssh" '! grep -E "rm -f|tee |apt-get|systemctl" "$CALLS"'

# ── The policy files themselves (ADR-009: exact vendor channels, no reboot) ──
# patterns FILE: the quoted origin patterns of a drop-in, one per line, comments ignored.
patterns() { grep -v '^[[:space:]]*//' "$ROOT/apt/$1" | grep -o '"origin=[^"]*"'; }
EXPECT_DEBIAN='"origin=Debian,codename=${distro_codename},label=Debian"
"origin=Debian,codename=${distro_codename}-updates,label=Debian"
"origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation"
"origin=gh,label=gh,codename=stable"'
EXPECT_UBUNTU='"origin=Ubuntu,archive=${distro_codename}-updates,label=Ubuntu"
"origin=Tailscale,label=Tailscale,codename=${distro_codename}"'
check "52brokkr-debian-updates admits exactly the enumerated Debian-family channels" '[[ "$(patterns 52brokkr-debian-updates)" == "$EXPECT_DEBIAN" ]]'
check "52brokkr-ubuntu-updates admits exactly the enumerated Ubuntu channels" '[[ "$(patterns 52brokkr-ubuntu-updates)" == "$EXPECT_UBUNTU" ]]'
check "51brokkr-claude-code admits exactly the Claude Code stable channel" \
  '[[ "$(patterns 51brokkr-claude-code)" == "\"origin=Anthropic,label=Anthropic,codename=stable\"" ]]'
check "every non-distribution origin pattern pins a codename or channel" \
  '! { patterns 51brokkr-claude-code; patterns 52brokkr-debian-updates; patterns 52brokkr-ubuntu-updates; } | grep -vE "^\"origin=(Debian|Ubuntu|Raspberry Pi Foundation)," | grep -v "codename=" | grep -q .'
check "no Tailscale pattern for Debian-family hosts" '[[ "$(patterns 52brokkr-debian-updates)" != *Tailscale* ]]'
check "no -backports or -proposed pattern in the regular-update drop-ins" \
  '! { patterns 52brokkr-debian-updates; patterns 52brokkr-ubuntu-updates; } | grep -Eq "backports|proposed"'
check "the security baseline keeps Automatic-Reboot false and lists only Debian-Security" \
  'grep -q "^Unattended-Upgrade::Automatic-Reboot \"false\";" "$ROOT/apt/50unattended-upgrades" && [[ "$(patterns 50unattended-upgrades)" == "\"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\"" ]]'
check "no apt file enables a reboot" '! grep -E "Automatic-Reboot[^\"]*\"true\"" "$ROOT"/apt/*'

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
