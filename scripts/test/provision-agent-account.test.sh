#!/usr/bin/env bash
# Hermetic coverage for scripts/provision-agent-account.sh. Every system command is a PATH shim
# that records its argv; no root, network, systemd, nftables or real account is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/bin"
STATE="$TMP/state"
ROOT_DIR="$TMP/root"
CALLS="$TMP/calls"
FIXTURE="$TMP/repo"
KEYS="$TMP/keys"
mkdir -p "$STUBS" "$KEYS"
: >"$CALLS"

# --- fixture repository bound to a commit (deploy-source binding) ------------------------------
mkdir -p "$FIXTURE/scripts/lib"
cp "$SOURCE_REPO/scripts/provision-agent-account.sh" "$FIXTURE/scripts/"
cp "$SOURCE_REPO/scripts/lib/deploy-source.sh" "$FIXTURE/scripts/lib/"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" config user.email test@example.invalid
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" add scripts
git -C "$FIXTURE" -c core.hooksPath=/dev/null commit -qm 'fixture agent account provisioner'
HEAD_SHA=$(git -C "$FIXTURE" rev-parse HEAD)

# --- keys --------------------------------------------------------------------------------------
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -C 'operator@laptop.example' -f "$KEYS/agent" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -C 'second@laptop.example' -f "$KEYS/other" >/dev/null
else
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKeyOne operator@laptop.example\n' >"$KEYS/agent.pub"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKeyTwo second@laptop.example\n' >"$KEYS/other.pub"
  cat >"$STUBS/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keygen %s\n' "$*" >>"$STUB_CALLS"
grep -q garbage "$2" && exit 1
printf '256 SHA256:fixture fixture (ED25519)\n'
EOF
  chmod +x "$STUBS/ssh-keygen"
fi
PUB="$KEYS/agent.pub"
B64=$(awk '{print $2}' "$PUB")
printf '%s\n%s\n' "$(cat "$PUB")" "$(cat "$KEYS/other.pub")" >"$KEYS/two.pub"
printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7fixture rsa@example.test\n' >"$KEYS/rsa.pub"
printf 'ssh-ed25519 AAAAgarbagegarbage broken@example.test\n' >"$KEYS/garbage.pub"
printf 'command="id" %s\n' "$(cat "$PUB")" >"$KEYS/options.pub"
printf '# just a comment\n' >"$KEYS/comment.pub"
: >"$KEYS/empty.pub"
ln -s "$PUB" "$KEYS/link.pub"

# --- command shims -----------------------------------------------------------------------------
stub() { cat >"$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub sudo <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUB_CALLS"
STUB_SUDO=1 exec "$@"
EOF
stub id <<'EOF'
#!/usr/bin/env bash
printf 'id %s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  -u) cat "$STUB_STATE/euid" ;;
  -un) cat "$STUB_STATE/invoker" ;;
  -nG) [[ -f "$STUB_STATE/groups/$2" ]] || exit 1; cat "$STUB_STATE/groups/$2" ;;
  *) echo "id stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
stub getent <<'EOF'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >>"$STUB_CALLS"
case "$1" in
  passwd|group) grep -m1 "^$2:" "$STUB_STATE/$1" || exit 2 ;;
  *) exit 99 ;;
esac
EOF
stub useradd <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'useradd %s\n' "$*" >>"$STUB_CALLS"
[[ ${STUB_FAIL:-} != useradd ]] || exit 9
name=${!#}
uid=${STUB_NEW_UID:-1001}
printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$name" "$uid" "$uid" "$name" >>"$STUB_STATE/passwd"
printf '%s:x:%s:\n' "$name" "$uid" >>"$STUB_STATE/group"
mkdir -p "$STUB_STATE/groups" "$BROKKR_AGENT_ROOT/home/$name"
printf '%s%s\n' "$name" "${STUB_EXTRA_GROUP:+ $STUB_EXTRA_GROUP}" >"$STUB_STATE/groups/$name"
EOF
stub usermod <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'usermod %s\n' "$*" >>"$STUB_CALLS"
EOF
stub loginctl <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'loginctl %s\n' "$*" >>"$STUB_CALLS"
if [[ $1 == terminate-user ]]; then
  case ${STUB_TERMINATE:-ok} in
    notloggedin) echo "Failed to terminate user $2: User ID 1001 is not logged in." >&2; exit 1 ;;
    error) echo "Failed to terminate user $2: Access denied" >&2; exit 1 ;;
  esac
fi
EOF
stub systemctl <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'systemctl %s\n' "$*" >>"$STUB_CALLS"
load() { # simulate the egress unit loading its ruleset file
  local u=${1#brokkr-agent-egress-}
  u=${u%.service}
  cp "$BROKKR_AGENT_ROOT/etc/brokkr/agent-account/$u.nft" "$STUB_STATE/loaded.nft"
}
case "$1" in
  is-active)
    shift; quiet=0
    if [[ ${1:-} == --quiet ]]; then quiet=1; shift; fi
    if grep -qx -- "$1" "$STUB_STATE/active"; then [[ $quiet -eq 1 ]] || echo active; exit 0; fi
    [[ $quiet -eq 1 ]] || echo inactive
    exit 3 ;;
  enable)
    [[ ${STUB_FAIL:-} != enable ]] || exit 1
    unit=${!#}
    if ! grep -qx -- "$unit" "$STUB_STATE/active"; then echo "$unit" >>"$STUB_STATE/active"; load "$unit"; fi ;;
  restart|reload) load "$2" ;;
  daemon-reload|set-property) : ;;
  *) echo "systemctl stub: unexpected: $*" >&2; exit 99 ;;
esac
EOF
stub nft <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'nft %s\n' "$*" >>"$STUB_CALLS"
case "$1 $2" in
  '-c -f')
    [[ ${STUB_NFT_CHECK_FAIL:-} != 1 ]] || { echo 'nft stub: Error: syntax error' >&2; exit 1; }
    grep -q '^table inet brokkr_agent_' "$3" ;;
  'list table') [[ -f "$STUB_STATE/loaded.nft" ]] || exit 1; cat "$STUB_STATE/loaded.nft" ;;
  *) exit 99 ;;
esac
EOF
stub findmnt <<'EOF'
#!/usr/bin/env bash
printf 'findmnt %s\n' "$*" >>"$STUB_CALLS"
echo "${STUB_PROC_OPTS:-rw,nosuid,nodev,noexec,relatime}"
EOF
stub install <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_SUDO:-} ]] || printf 'install %s\n' "$*" >>"$STUB_CALLS"
dir=0 mode='' owner='' group=''
while [[ $# -gt 0 ]]; do
  case $1 in
    -d) dir=1; shift ;;
    -m) mode=$2; shift 2 ;;
    -o) owner=$2; shift 2 ;;
    -g) group=$2; shift 2 ;;
    *) break ;;
  esac
done
if [[ $dir -eq 1 ]]; then
  for d in "$@"; do
    mkdir -p "$d" && chmod "$mode" "$d" || exit 1
    printf '%s %s %s %s\n' "$d" "$mode" "$owner" "$group" >>"$STUB_STATE/meta"
  done
else
  cat "$1" >"$2" && chmod "$mode" "$2" || exit 1
  printf '%s %s %s %s\n' "$2" "$mode" "$owner" "$group" >>"$STUB_STATE/meta"
fi
EOF
for tool in chmod mv rm; do
  cat >"$STUBS/$tool" <<EOF
#!/usr/bin/env bash
[[ -n \${STUB_SUDO:-} ]] || printf '%s\n' "$tool \$*" >>"\$STUB_CALLS"
exec "$(command -v "$tool")" "\$@"
EOF
  chmod +x "$STUBS/$tool"
done

# --- harness -----------------------------------------------------------------------------------
PASS=0
FAIL=0
OUT=''
RC=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2
  printf '%s\n' "$OUT" | head -12 | sed 's/^/    | /' >&2
}
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

reset_host() {
  rm -rf "$ROOT_DIR" "$STATE"
  mkdir -p "$ROOT_DIR" "$STATE/groups"
  : >"$STATE/passwd"; : >"$STATE/group"; : >"$STATE/active"; : >"$STATE/meta"
  echo 1000 >"$STATE/euid"
  echo operator >"$STATE/invoker"
  : >"$CALLS"
}

# run [script args...]: NOBIND=1 omits the deploy-source binding. Per-test STUB_* variables are
# set as prefix assignments on this function call.
run() {
  local src=$FIXTURE sha=$HEAD_SHA
  if [[ -n ${NOBIND:-} ]]; then src=''; sha=''; fi
  : >"$CALLS"
  OUT=$(cd "$FIXTURE" && PATH="$STUBS:$PATH" STUB_CALLS="$CALLS" STUB_STATE="$STATE" \
    BROKKR_AGENT_ROOT="$ROOT_DIR" BROKKR_AGENT_SBIN='' \
    BROKKR_EXPECTED_SOURCE="$src" BROKKR_EXPECTED_COMMIT="$sha" \
    bash scripts/provision-agent-account.sh "$@" 2>&1)
  RC=$?
}

out_has() { grep -qF -- "$1" <<<"$OUT"; }
has_call() { grep -qF -- "$1" "$CALLS"; }
no_call() { ! grep -qE -- "$1" "$CALLS"; }
call_line() { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
call_count() { grep -cF -- "$1" "$CALLS"; }
before() { # earlier-call later-call
  local a b
  a=$(call_line "$1"); b=$(call_line "$2")
  [[ -n $a && -n $b && $a -lt $b ]]
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
mode_is() { [[ "$(mode_of "$1")" == "$2" ]]; }
meta_has() { grep -qxF -- "$1" "$STATE/meta"; }
same_content() { printf '%s\n' "$2" | cmp -s - "$1"; }
absent() { [[ ! -e $1 && ! -L $1 ]]; }
rc_is() { [[ $RC -eq $1 ]]; }
files_under_root() { find "$ROOT_DIR" -mindepth 1 | wc -l | tr -d ' '; }
snapshot() { (cd "$ROOT_DIR" && find . -type f | sort | while read -r f; do printf '%s ' "$f"; cksum <"$f"; done); }
only_via_sudo() { no_call '^(useradd|usermod|loginctl|nft|install|chmod|mv|rm) ' &&
  no_call '^systemctl (daemon-reload|enable|restart|set-property)'; }
nothing_mutated() { only_via_sudo && no_call '^sudo '; }
refused() { # pattern: rc 64, prefixed message, no mutation at all
  [[ $RC -eq 64 ]] && out_has 'brokkr agent account:' && out_has "$1" && nothing_mutated
}
expect_refusal() { # description pattern script-args...
  local desc=$1 pattern=$2
  shift 2
  run "$@"
  check "$desc" refused "$pattern"
}

AUTH="$ROOT_DIR/home/agent-dev/.ssh/authorized_keys"
SLICE="$ROOT_DIR/etc/systemd/system/user-1001.slice.d/70-brokkr-agent-account.conf"
NFT="$ROOT_DIR/etc/brokkr/agent-account/agent-dev.nft"
UNIT="$ROOT_DIR/etc/systemd/system/brokkr-agent-egress-agent-dev.service"
MARK="$ROOT_DIR/var/lib/brokkr/agent-account/agent-dev.managed"
T=$'\t'
SSH_FROM='100.64.0.0/10,fd7a:115c:a1e0::/48'
BASE=(--user agent-dev --pubkey "$PUB" --ssh-from "$SSH_FROM")

EXPECT_SLICE=$'[Slice]\nCPUQuota=2000%\nCPUWeight=20\nIOWeight=20\nMemoryHigh=20G\nMemoryMax=24G\nMemorySwapMax=0\nTasksMax=4096'
expected_nft() { # allowlist
  printf '%s\n' '#!/usr/sbin/nft -f' \
    'table inet brokkr_agent_agent_dev' \
    'delete table inet brokkr_agent_agent_dev' \
    'table inet brokkr_agent_agent_dev {' \
    "${T}chain output {" \
    "${T}${T}type filter hook output priority filter; policy accept;" \
    "${T}${T}meta skuid 1001 fib daddr type local udp dport 53 accept" \
    "${T}${T}meta skuid 1001 fib daddr type local tcp dport 53 accept" \
    "${T}${T}meta skuid 1001 fib daddr type local tcp dport { $1 } accept" \
    "${T}${T}meta skuid 1001 fib daddr type local counter reject" \
    "${T}${T}meta skuid 1001 ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } counter reject" \
    "${T}${T}meta skuid 1001 ip6 daddr { fc00::/7, fe80::/10 } counter reject" \
    "${T}}" '}'
}
EXPECT_UNIT=$'[Unit]\nDescription=Brokkr egress isolation for agent account agent-dev\nBefore=user@1001.service systemd-user-sessions.service\nDefaultDependencies=no\nAfter=local-fs.target nftables.service\nPartOf=nftables.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f /etc/brokkr/agent-account/agent-dev.nft\nExecReload=/usr/sbin/nft -f /etc/brokkr/agent-account/agent-dev.nft\nExecStop=/usr/sbin/nft delete table inet brokkr_agent_agent_dev\n\n[Install]\nWantedBy=multi-user.target'
EXPECT_AUTH="from=\"$SSH_FROM\",no-agent-forwarding,no-X11-forwarding ssh-ed25519 $B64 brokkr-agent-account"

seed_user() { # name uid groups [marker-uid]
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$2" "$2" "$1" >>"$STATE/passwd"
  printf '%s\n' "$3" >"$STATE/groups/$1"
  mkdir -p "$ROOT_DIR/home/$1"
  if [[ -n ${4:-} ]]; then
    mkdir -p "$ROOT_DIR/var/lib/brokkr/agent-account"
    printf '%s\n' "$4" >"$ROOT_DIR/var/lib/brokkr/agent-account/$1.managed"
  fi
}

echo provision-agent-account.test.sh

# 1. dry-run -------------------------------------------------------------------------------------
reset_host
NOBIND=1 run "${BASE[@]}"
check 'dry-run succeeds without a deploy-source binding' rc_is 0
check 'dry-run says nothing is changed' out_has 'DRY-RUN'
check 'dry-run prints the useradd plan' out_has 'would run: sudo useradd --create-home --home-dir /home/agent-dev --shell /bin/bash --user-group agent-dev'
check 'dry-run renders the slice drop-in' out_has 'MemoryMax=24G'
check 'dry-run renders the nft table with a uid placeholder' out_has 'table inet brokkr_agent_agent_dev'
check 'dry-run renders the authorized_keys line' out_has "from=\"$SSH_FROM\",no-agent-forwarding,no-X11-forwarding ssh-ed25519 $B64 brokkr-agent-account"
check 'dry-run notes the missing hidepid mount' out_has 'without hidepid'
check 'dry-run writes nothing under the root' test "$(files_under_root)" = 0
check 'dry-run runs no mutating command' nothing_mutated
STUB_PROC_OPTS=rw,relatime,hidepid=2 run "${BASE[@]}"
check 'dry-run recognises hidepid' out_has 'mounted with hidepid'
run --help
check '--help exits 0 with usage' out_has 'Usage:'

# 2. apply on a fresh host -----------------------------------------------------------------------
reset_host
run --apply "${BASE[@]}"
check 'apply on a fresh host succeeds' rc_is 0
check 'useradd uses the pinned arguments' has_call 'sudo useradd --create-home --home-dir /home/agent-dev --shell /bin/bash --user-group agent-dev'
check 'password is unusable but not locked' has_call 'sudo usermod -p * agent-dev'
check 'home is 0700' mode_is "$ROOT_DIR/home/agent-dev" 700
check 'managed marker holds the uid' same_content "$MARK" 1001
check 'managed marker is 0644 root' meta_has "$MARK 0644 root root"
check 'slice drop-in is exact' same_content "$SLICE" "$EXPECT_SLICE"
check 'slice drop-in is 0644 root' meta_has "$SLICE 0644 root root"
check 'nft ruleset is exact' same_content "$NFT" "$(expected_nft '1420, 4173, 5173, 32768-60999')"
check 'nft ruleset is staged then validated root-owned' meta_has "$NFT.new 0644 root root"
check 'nft ruleset is 0644' mode_is "$NFT" 644
check 'no staged ruleset is left behind' absent "$NFT.new"
check 'egress unit is exact' same_content "$UNIT" "$EXPECT_UNIT"
check 'egress unit is 0644 root' meta_has "$UNIT 0644 root root"
check 'authorized_keys is exactly one restricted key line without the comment' same_content "$AUTH" "$EXPECT_AUTH"
check 'authorized_keys is 0600 owned by the agent' meta_has "$AUTH 0600 agent-dev agent-dev"
check 'authorized_keys mode on disk is 600' mode_is "$AUTH" 600
check '.ssh is 0700 owned by the agent' meta_has "$ROOT_DIR/home/agent-dev/.ssh 0700 agent-dev agent-dev"
check 'linger is enabled' has_call 'sudo loginctl enable-linger agent-dev'
check 'inactive slice gets no runtime set-property' no_call 'set-property'
check 'every mutation went through sudo' only_via_sudo
check 'the egress unit is enabled and started' has_call 'sudo systemctl enable --now brokkr-agent-egress-agent-dev.service'
check 'a first install does not restart or reload the unit' no_call 'systemctl (restart|reload) '
check 'nft -c precedes enable --now' before 'sudo nft -c -f' 'sudo systemctl enable --now'
check 'enable --now precedes the table readback' before 'sudo systemctl enable --now' 'sudo nft list table inet brokkr_agent_agent_dev'
check 'the table readback precedes authorized_keys' before 'sudo nft list table inet brokkr_agent_agent_dev' '/dev/stdin '"$AUTH"
check 'authorized_keys precedes linger' before '/dev/stdin '"$AUTH" 'sudo loginctl enable-linger'
check 'the account is denied cron' same_content "$ROOT_DIR/etc/cron.deny" 'agent-dev'
check 'cron is denied before authorized_keys' before 'sudo tee -a '"$ROOT_DIR"'/etc/cron.deny' '/dev/stdin '"$AUTH"
check 'nft -c precedes linger' before 'sudo nft -c -f' 'sudo loginctl enable-linger'
check 'useradd precedes the egress unit' before 'sudo useradd' 'sudo systemctl enable --now'
check 'output points at the docs' out_has 'docs/agent-account.md'

# 3. idempotent re-run ---------------------------------------------------------------------------
SNAP1=$(snapshot)
run --apply "${BASE[@]}"
check 're-run succeeds' rc_is 0
check 're-run creates no second account' test "$(call_count 'useradd')" = 0
check 're-run converges on identical files' test "$SNAP1" = "$(snapshot)"
check 're-run keeps a single key line' test "$(wc -l <"$AUTH" | tr -d ' ')" = 1
check 're-run lists the account in cron.deny once' test "$(grep -cx agent-dev "$ROOT_DIR/etc/cron.deny")" = 1
check 're-run re-enables a possibly revoked account' has_call 'sudo usermod -p * --expiredate  agent-dev'
check 're-run reloads the active egress unit atomically' has_call 'sudo systemctl reload brokkr-agent-egress-agent-dev.service'
check 're-run never restarts the egress unit' no_call 'systemctl restart '
run --apply "${BASE[@]}" --cpu-quota 400% --memory-high 6G --memory-max 8G --tasks-max 1024 --allow-local-tcp '3000,40000-40100'
check 'changed limits re-run succeeds' rc_is 0
check 'slice drop-in follows the new limits' same_content "$SLICE" $'[Slice]\nCPUQuota=400%\nCPUWeight=20\nIOWeight=20\nMemoryHigh=6G\nMemoryMax=8G\nMemorySwapMax=0\nTasksMax=1024'
check 'nft ruleset follows the new allowlist' same_content "$NFT" "$(expected_nft '3000, 40000-40100')"
check 'reload loaded the changed ruleset' same_content "$STATE/loaded.nft" "$(expected_nft '3000, 40000-40100')"
run --apply "${BASE[@]}" --allow-local-tcp '0080,443-443'
check 'ports are rendered as normalised decimals' same_content "$NFT" "$(expected_nft '80, 443')"

# 3b. dry-run against an existing managed account uses its real uid ------------------------------
run "${BASE[@]}"
check 'dry-run on a managed account succeeds' rc_is 0
check 'dry-run on a managed account renders the real uid' out_has 'meta skuid 1001 fib daddr type local counter reject'
check 'dry-run on a managed account mutates nothing' nothing_mutated

# 3c. runtime properties for an already-active slice ---------------------------------------------
reset_host
echo user-1001.slice >"$STATE/active"
run --apply "${BASE[@]}"
check 'an active slice receives runtime properties' has_call 'sudo systemctl set-property --runtime user-1001.slice CPUQuota=2000% CPUWeight=20 IOWeight=20 MemoryHigh=20G MemoryMax=24G MemorySwapMax=0 TasksMax=4096'

# 4. refusals ------------------------------------------------------------------------------------
reset_host
echo 0 >"$STATE/euid"
expect_refusal 'refuses to run as root' 'refusing to run as root' "${BASE[@]}"
echo 1000 >"$STATE/euid"
expect_refusal 'refuses the invoking user' 'invoking operator' --user operator --pubkey "$PUB" --ssh-from "$SSH_FROM"
expect_refusal 'refuses root as the account' 'must not be root' --user root --pubkey "$PUB" --ssh-from "$SSH_FROM"
for name in Agent a 1agent agent_x 'agent;id' 'agent dev' abcdefghijklmnopqrstuvwxyz0123456789; do
  expect_refusal "refuses invalid user name '$name'" '--user must match' --user "$name" --pubkey "$PUB" --ssh-from "$SSH_FROM"
done
expect_refusal 'requires --user' '--user is required' --pubkey "$PUB" --ssh-from "$SSH_FROM"
expect_refusal 'requires --pubkey' '--pubkey is required' --user agent-dev --ssh-from "$SSH_FROM"
expect_refusal 'requires --ssh-from' '--ssh-from is required' --user agent-dev --pubkey "$PUB"
expect_refusal 'rejects unknown arguments' 'unknown argument' "${BASE[@]}" --bogus
expect_refusal 'rejects a missing option value' 'requires a value' --user
for key in two rsa garbage options comment empty link; do
  expect_refusal "rejects pubkey fixture '$key'" '--pubkey' --user agent-dev --pubkey "$KEYS/$key.pub" --ssh-from "$SSH_FROM"
done
expect_refusal 'rejects a missing pubkey file' '--pubkey' --user agent-dev --pubkey "$KEYS/absent.pub" --ssh-from "$SSH_FROM"
expect_refusal 'rejects a pubkey directory' '--pubkey' --user agent-dev --pubkey "$KEYS" --ssh-from "$SSH_FROM"
for cidr in 10.0.0.0 '10.0.0.0/8,' ',10.0.0.0/8' '10.0.0.0/8,,192.168.0.0/16' foo/8 10.0.0.0/33 300.0.0.0/8 010.0.0.0/8 ::1 fe80::/129 'fe80::/10 ' 'a"b/8' 12345::/16; do
  expect_refusal "rejects --ssh-from '$cidr'" '--ssh-from' --user agent-dev --pubkey "$PUB" --ssh-from "$cidr"
done
expect_refusal 'rejects a bare memory-high' '--memory-high' "${BASE[@]}" --memory-high 20
expect_refusal 'rejects a memory-max with a bad unit' '--memory-max' "${BASE[@]}" --memory-max 20GB
expect_refusal 'rejects a zero memory-high' '--memory-high' "${BASE[@]}" --memory-high 0G
expect_refusal 'rejects a cpu quota without percent' '--cpu-quota' "${BASE[@]}" --cpu-quota 200
expect_refusal 'rejects a zero cpu quota' '--cpu-quota' "${BASE[@]}" --cpu-quota 0%
expect_refusal 'rejects a non-numeric tasks-max' '--tasks-max' "${BASE[@]}" --tasks-max abc
expect_refusal 'rejects a zero tasks-max' '--tasks-max' "${BASE[@]}" --tasks-max 0
for ports in 70000 0 100-50 abc '80,' '' 1-2-3 '1000-2000,1500' '80,80' 65536-65537; do
  expect_refusal "rejects --allow-local-tcp '$ports'" '--allow-local-tcp' "${BASE[@]}" --allow-local-tcp "$ports"
done
NOBIND=1 run --apply "${BASE[@]}"
check 'apply without a source binding is refused before any mutation' refused 'binding'

reset_host
seed_user agent-dev 1500 agent-dev
expect_refusal 'refuses to adopt an existing account without a marker' 'not managed by this script' "${BASE[@]}"
expect_refusal 'refuses to adopt an existing account on apply' 'not managed by this script' --apply "${BASE[@]}"
reset_host
seed_user agent-dev 1500 agent-dev 1600
expect_refusal 'refuses a marker for a different uid' 'does not match' "${BASE[@]}"
reset_host
seed_user agent-dev 500 agent-dev 500
expect_refusal 'refuses a managed account below uid 1000' '< 1000' "${BASE[@]}"
reset_host
seed_user agent-dev 1500 'agent-dev sudo' 1500
expect_refusal 'refuses a managed account with a supplementary group' 'only to its own group' "${BASE[@]}"
expect_refusal 'refuses the supplementary group on apply before any mutation' 'sudo' --apply "${BASE[@]}"
check 'no authorized_keys for the supplementary-group account' absent "$ROOT_DIR/home/agent-dev/.ssh/authorized_keys"
reset_host
printf 'agent-dev:x:1700:\n' >>"$STATE/group"
expect_refusal 'refuses a leftover group without an account' 'group agent-dev already exists' "${BASE[@]}"

reset_host
STUB_EXTRA_GROUP=sudo run --apply "${BASE[@]}"
check 'the group check fails closed with exit 64' rc_is 64
check 'the group check names the problem' out_has 'only to its own group'
check 'authorized_keys is not written when the group check fails' absent "$AUTH"
check 'linger is not enabled when the group check fails' no_call 'enable-linger'
check 'egress is not started when the group check fails' no_call 'enable --now'
check 'the managed marker survives so a re-run does not strand the account' test -f "$MARK"

# 5. nft -c failure ------------------------------------------------------------------------------
reset_host
STUB_NFT_CHECK_FAIL=1 run --apply "${BASE[@]}"
check 'nft -c failure aborts non-zero' rc_is 1
check 'nft -c failure names the cause' out_has 'nft rejected the ruleset'
check 'nft -c failure writes no authorized_keys' absent "$AUTH"
check 'nft -c failure enables no linger' no_call 'enable-linger'
check 'nft -c failure starts no egress unit' no_call 'enable --now'
check 'nft -c failure installs no ruleset' absent "$NFT"
check 'nft -c failure removes the staged ruleset' absent "$NFT.new"
reset_host
STUB_FAIL=enable run --apply "${BASE[@]}"
check 'a failing egress start aborts before the key and linger' test "$RC" -ne 0
check 'a failing egress start writes no authorized_keys' absent "$AUTH"
check 'a failing egress start enables no linger' no_call 'enable-linger'

# 6. revoke --------------------------------------------------------------------------------------
reset_host
expect_refusal 'revoke of an unknown account is refused' 'does not exist' --revoke --user agent-dev
seed_user agent-dev 1500 agent-dev
expect_refusal 'revoke requires the marker' 'not managed by this script' --revoke --user agent-dev
expect_refusal 'revoke accepts no provisioning options' '--revoke accepts only' --revoke --user agent-dev --pubkey "$PUB"

reset_host
run --apply "${BASE[@]}"
SNAP2=$(snapshot)
run --revoke --user agent-dev
check 'revoke dry-run succeeds' rc_is 0
check 'revoke dry-run plans the lock' out_has 'would run: sudo usermod --lock --expiredate 1 agent-dev'
check 'revoke dry-run prints the manual removal commands' out_has 'sudo userdel -r agent-dev'
check 'revoke dry-run mutates nothing' nothing_mutated
check 'revoke dry-run leaves the files untouched' test "$SNAP2" = "$(snapshot)"
echo 'agent-dev sudo' >"$STATE/groups/agent-dev"
run --revoke --apply --user agent-dev
check 'revoke apply succeeds even if the account has extra groups' rc_is 0
check 'revoke empties authorized_keys' test -f "$AUTH" -a ! -s "$AUTH"
check 'revoke keeps authorized_keys 0600' mode_is "$AUTH" 600
check 'revoke disables linger' has_call 'sudo loginctl disable-linger agent-dev'
check 'revoke locks and expires the account' has_call 'sudo usermod --lock --expiredate 1 agent-dev'
check 'revoke terminates sessions' has_call 'sudo loginctl terminate-user agent-dev'
check 'revoke never deletes the user' no_call 'userdel'
check 'revoke keeps the egress unit, ruleset, slice and marker' test -f "$UNIT" -a -f "$NFT" -a -f "$SLICE" -a -f "$MARK"
check 'revoke keeps the home directory' test -d "$ROOT_DIR/home/agent-dev"
check 'revoke does not stop the egress unit' no_call 'systemctl (disable|stop)'
check 'revoke removes no files' no_call '^(sudo )?rm '
check 'revoke goes through sudo only' only_via_sudo
STUB_TERMINATE=notloggedin run --revoke --apply --user agent-dev
check 'revoke ignores a not-logged-in terminate failure' rc_is 0
STUB_TERMINATE=error run --revoke --apply --user agent-dev
check 'revoke surfaces any other terminate failure' test "$RC" -ne 0
check 'revoke has already locked the account when terminate fails' has_call 'sudo usermod --lock --expiredate 1 agent-dev'
NOBIND=1 run --revoke --apply --user agent-dev
check 'revoke apply needs the source binding' refused 'binding'

echo agent-dev >"$STATE/groups/agent-dev"
run --apply "${BASE[@]}"
check 're-provisioning after a revoke succeeds' rc_is 0
check 're-provisioning unlocks and un-expires the account' has_call 'sudo usermod -p * --expiredate  agent-dev'
check 're-provisioning restores the key' same_content "$AUTH" "$EXPECT_AUTH"

# 7. missing tools -------------------------------------------------------------------------------
MISSING="$TMP/bin-missing"
mkdir -p "$MISSING"
for f in "$STUBS"/*; do [[ ${f##*/} == nft ]] || ln -s "$f" "$MISSING/${f##*/}"; done
[[ -e "$MISSING/ssh-keygen" ]] || ln -s "$(command -v ssh-keygen)" "$MISSING/ssh-keygen"
ln -s "$(command -v dirname)" "$MISSING/dirname"
reset_host
OUT=$(cd "$FIXTURE" && PATH="$MISSING" STUB_CALLS="$CALLS" STUB_STATE="$STATE" BROKKR_AGENT_ROOT="$ROOT_DIR" \
  BROKKR_AGENT_SBIN='' "$(command -v bash)" scripts/provision-agent-account.sh "${BASE[@]}" 2>&1)
RC=$?
check 'a missing required tool fails early with exit 64' rc_is 64
check 'a missing required tool is named' out_has 'required tool(s) missing: nft'
check 'a missing tool prevents any command from running' nothing_mutated

if (( FAIL )); then
  printf '%s passed, %s failed\n' "$PASS" "$FAIL" >&2
  exit 1
fi
printf '%s passed\n' "$PASS"
