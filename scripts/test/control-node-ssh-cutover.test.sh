#!/usr/bin/env bash
# Hermetic tests for the read-only control-node SSH cutover preflight.
#
# tailscale, ssh, sshd, and systemctl are fakes on a private PATH. ssh-keygen is the
# real binary run against temp known_hosts files and generated fixture keys. No host,
# network, service, or real home directory is touched. All names and addresses are
# reserved example values.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../control-node-ssh-cutover.py"
TMP="$(mktemp -d)"
KEYBASE=''
cleanup() {
  rm -rf "$TMP"
  if [ -n "$KEYBASE" ]; then rm -rf "$KEYBASE"; fi
}
trap cleanup EXIT

command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required for this test" >&2; exit 1; }
# Resolve the real interpreter once: version-manager shims need the caller's PATH.
PYTHON="$(python3 -c 'import sys; print(sys.executable)')"

# Host-role authorized_keys fixtures need OpenSSH-style safe ancestors (no directory up to
# / may be group- or world-writable), which a world-writable /tmp is not. Use the first
# candidate base whose whole realpath chain is owned by root or this user and not
# group/world-writable. Real key files are never read.
SAFE_CHAIN='
import os
import sys

path = os.path.realpath(sys.argv[1])
uid = os.getuid()
while True:
    info = os.stat(path)
    if info.st_uid not in (0, uid) or info.st_mode & 0o022:
        sys.exit(1)
    parent = os.path.dirname(path)
    if parent == path:
        break
    path = parent
'
for key_base_candidate in "${RUNNER_TEMP:-}" "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-/tmp}" "${HOME:-}"; do
  if [ -z "$key_base_candidate" ] || [ ! -d "$key_base_candidate" ]; then continue; fi
  if "$PYTHON" -I -c "$SAFE_CHAIN" "$key_base_candidate" 2>/dev/null; then
    if KEYBASE="$(mktemp -d "$key_base_candidate/brokkr-cutover.XXXXXX" 2>/dev/null)"; then break; fi
    KEYBASE=''
  fi
done

# ---------------------------------------------------------------- fakes on PATH
STUBS="$TMP/stubs"
mkdir -p "$STUBS" "$TMP/stubs-badkeygen" "$TMP/stubs-garblekeygen"
cat >"$STUBS/tailscale" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" != "status --json" ]]; then
  echo "unexpected tailscale arguments" >&2
  exit 64
fi
if [ -n "${MOCK_TAILSCALE_SLEEP:-}" ]; then exec sleep "$MOCK_TAILSCALE_SLEEP"; fi
if [ "${MOCK_TAILSCALE_RC:-0}" -ne 0 ]; then exit "$MOCK_TAILSCALE_RC"; fi
printf '%s\n' "${MOCK_TAILSCALE_JSON:-}"
EOF
cat >"$STUBS/ssh" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 2 ] || [ "$1" != "-G" ] || [ "$2" != "ctl1-alias" ]; then
  echo "unexpected ssh arguments" >&2
  exit 64
fi
if [ "${MOCK_SSH_RC:-0}" -ne 0 ]; then exit "$MOCK_SSH_RC"; fi
cat "$MOCK_SSH_G_FILE"
EOF
cat >"$STUBS/sshd" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 3 ] || [ "$1" != "-T" ] || [ "$2" != "-C" ]; then
  echo "unexpected sshd arguments" >&2
  exit 64
fi
printf '%s\n' "$*" >>"$MOCK_SSHD_ARGV_FILE"
if [[ "$3" == *user=root,* ]]; then
  if [ "${MOCK_SSHD_ROOT_RC:-0}" -ne 0 ]; then exit "$MOCK_SSHD_ROOT_RC"; fi
  if [ -n "${MOCK_SSHD_ROOT_CONFIG+x}" ]; then
    printf '%s' "$MOCK_SSHD_ROOT_CONFIG"
    exit 0
  fi
fi
if [ "${MOCK_SSHD_RC:-0}" -ne 0 ]; then exit "$MOCK_SSHD_RC"; fi
cat "$MOCK_SSHD_FILE"
EOF
cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 3 ] || [ "$1" != "is-active" ] || [ "$2" != "--quiet" ]; then
  echo "unexpected systemctl arguments" >&2
  exit 64
fi
read -r -a units <<<"${MOCK_ACTIVE_UNITS:-}"
for unit in "${units[@]}"; do
  if [ "$unit" = "$3" ]; then exit 0; fi
done
exit 3
EOF
cat >"$TMP/stubs-badkeygen/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
cat >"$TMP/stubs-garblekeygen/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'unparseable.example ssh-ed25519 !!!not-base64!!!\n'
EOF
chmod +x "$STUBS"/* "$TMP"/stubs-badkeygen/* "$TMP"/stubs-garblekeygen/*

# mkpath NAME CMD...: a PATH directory of symlinks. A command resolves to a fake in
# $EXTRA_STUBS or $STUBS when present, otherwise to the real binary.
mkpath() {
  local dir="$TMP/path-$1" cmd src
  shift
  mkdir -p "$dir"
  for cmd in "$@"; do
    if [ -n "${EXTRA_STUBS:-}" ] && [ -x "$EXTRA_STUBS/$cmd" ]; then
      src="$EXTRA_STUBS/$cmd"
    elif [ -x "$STUBS/$cmd" ]; then
      src="$STUBS/$cmd"
    else
      src="$(command -v "$cmd")"
    fi
    ln -sf "$src" "$dir/$cmd"
  done
}
mkpath all tailscale ssh sshd systemctl ssh-keygen bash cat sleep
mkpath no-tailscale ssh sshd systemctl ssh-keygen bash cat sleep
mkpath no-ssh tailscale sshd systemctl ssh-keygen bash cat sleep
mkpath no-systemctl tailscale ssh sshd ssh-keygen bash cat sleep
EXTRA_STUBS="$TMP/stubs-badkeygen" mkpath badkeygen tailscale ssh sshd systemctl ssh-keygen bash cat sleep
EXTRA_STUBS="$TMP/stubs-garblekeygen" mkpath garblekeygen tailscale ssh sshd systemctl ssh-keygen bash cat sleep
TOOL_PATH="$TMP/path-all"

export MOCK_SSH_G_FILE="$TMP/ssh-g.txt"
export MOCK_SSHD_FILE="$TMP/sshd-T.txt"
export MOCK_SSHD_ARGV_FILE="$TMP/sshd-argv.txt"
: >"$MOCK_SSHD_ARGV_FILE"

# ------------------------------------------------------------------- fixtures
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$TMP/hostkey"
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$TMP/otherkey"
BLOB="$(awk '{print $2}' "$TMP/hostkey.pub")"
OBLOB="$(awk '{print $2}' "$TMP/otherkey.pub")"
FP="$(ssh-keygen -lf "$TMP/hostkey.pub" | awk '{print $2}')"
OFP="$(ssh-keygen -lf "$TMP/otherkey.pub" | awk '{print $2}')"
USERNAME="$(id -un)"
# Documentation-range operator workstation addresses for the host role's --client-address.
CLIENT4='198.51.100.7'
CLIENT6='2001:db8::7'

# Substrings that must never appear in tool output.
LEAK=(ctl1 example 192.0.2 198.51.100 2001:db8 "$CLIENT4" "$CLIENT6" "$FP" "${FP#SHA256:}" "$OFP" "${OFP#SHA256:}"
  "$BLOB" "$OBLOB" "$TMP" keyalias nosuchuser not-an-ip fe80 eth0)
if [ -n "$KEYBASE" ]; then LEAK+=("$KEYBASE"); fi
PRIMARY_GROUP="$(id -gn 2>/dev/null || true)"
NO_SUCH_GROUP='nosuchgroup-zz9'
LEAK+=("$NO_SUCH_GROUP")
LEAK_WORDS=(ops "$USERNAME")
if [ -n "$PRIMARY_GROUP" ]; then LEAK_WORDS+=("$PRIMARY_GROUP"); fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

cat >"$TMP/assert.py" <<'EOF'
import json
import re
import sys

path, role, phase, outcome, reasons, warnings, expr = sys.argv[1:8]


def fail(message):
    print(message)
    sys.exit(1)


raw = open(path, encoding="utf-8").read()
if raw.count("\n") != 1 or not raw.endswith("\n"):
    fail("stdout is not exactly one line")
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    fail("stdout is not JSON")
want_keys = ["schema_version", "role", "phase", "outcome", "checks", "reasons", "warnings", "counts"]
if list(d) != want_keys:
    fail("unexpected key set or order")
if d["schema_version"] != "v1":
    fail("schema_version")
if d["role"] != (None if role == "null" else role):
    fail("role is %r" % (d["role"],))
if d["phase"] != (None if phase == "null" else phase):
    fail("phase is %r" % (d["phase"],))
if d["outcome"] != outcome:
    fail("outcome is %r, want %r; reasons=%r" % (d["outcome"], outcome, d["reasons"]))
for name in ("reasons", "warnings"):
    items = d[name]
    if items != sorted(set(items)):
        fail("%s not sorted/unique" % name)
    for item in items:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", item):
            fail("%s has a non-code entry" % name)
if d["reasons"] != [r for r in reasons.split(",") if r]:
    fail("reasons are %r, want %r" % (d["reasons"], reasons))
if d["warnings"] != [w for w in warnings.split(",") if w]:
    fail("warnings are %r, want %r" % (d["warnings"], warnings))
if not all(isinstance(v, bool) for v in d["checks"].values()):
    fail("checks must be booleans")
if not all(type(v) is int for v in d["counts"].values()):
    fail("counts must be integers")
if (outcome == "pass") != (not d["reasons"]):
    fail("pass must hold iff reasons is empty")
if outcome == "error" and len(d["reasons"]) != 1:
    fail("error must carry exactly one reason")
# expr is a literal assertion written in this test file, never external input.
if expr and not eval(expr, {"d": d}):
    fail("expression false: %s; output=%s" % (expr, raw.strip()))
EOF

# run_raw EXPECTED_ROLE EXPECTED_PHASE ARGS...  (use "null" for an absent role/phase)
run_raw() {
  EXP_ROLE="$1" EXP_PHASE="$2"
  shift 2
  env PATH="$TOOL_PATH" "$PYTHON" "$CHECK" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
}

# expect DESC RC OUTCOME REASONS WARNINGS [PY-EXPR over d]
expect() {
  local desc="$1" want_rc="$2" outcome="$3" reasons="$4" warnings="$5" expr="${6:-}" msg s
  if [ "$RC" -ne "$want_rc" ]; then
    bad "$desc (rc=$RC, want $want_rc; out=$(head -c 400 "$TMP/out"); err=$(head -c 200 "$TMP/err"))"
    return
  fi
  if [ -s "$TMP/err" ]; then bad "$desc (stderr is not empty)"; return; fi
  if grep -Fq 'Traceback' "$TMP/out" "$TMP/err"; then bad "$desc (traceback leaked)"; return; fi
  for s in "${LEAK[@]}"; do
    if grep -Fq -- "$s" "$TMP/out"; then bad "$desc (output leaks a fixture value)"; return; fi
  done
  for s in "${LEAK_WORDS[@]}"; do
    if grep -Fwq -- "$s" "$TMP/out"; then bad "$desc (output leaks a fixture word)"; return; fi
  done
  if ! msg="$("$PYTHON" "$TMP/assert.py" "$TMP/out" "$EXP_ROLE" "$EXP_PHASE" "$outcome" "$reasons" "$warnings" "$expr")"; then
    bad "$desc ($msg)"
    return
  fi
  ok "$desc"
}

# ------------------------------------------------------- operator-role fixtures
write_known_hosts() {
  printf 'ctl1.example.ts.net,ctl1,192.0.2.50 ssh-ed25519 %s\n' "$1" >"$TMP/known_hosts"
}

build_status() {
  local keys=''
  if [ -n "$T_KEYS" ]; then keys=",\"sshHostKeys\":$T_KEYS"; fi
  export MOCK_TAILSCALE_JSON="{\"BackendState\":\"Running\",\"TailscaleIPs\":[\"192.0.2.1\"],\"Self\":{\"Online\":true,\"DNSName\":\"op.example.ts.net.\",\"TailscaleIPs\":[\"192.0.2.1\"]${SELF_EXTRA}},\"Peer\":{\"nodekey:aaa\":{\"DNSName\":\"${T_DNS}\",\"Online\":${T_ONLINE},\"TailscaleIPs\":[\"192.0.2.50\",\"2001:db8::50\"]${keys}}${EXTRA_PEERS}}}"
}

build_ssh_g() {
  {
    printf 'user %s\nhostname %s\nport %s\n' "$G_USER" "$G_HOST" "$G_PORT"
    if [ -n "$G_STRICT" ]; then printf 'stricthostkeychecking %s\n' "$G_STRICT"; fi
    printf 'userknownhostsfile %s/known_hosts %s/known_hosts2\n' "$TMP" "$TMP"
    printf 'globalknownhostsfile %s/global_known_hosts\n' "$TMP"
    printf '%s' "$G_EXTRA"
  } >"$MOCK_SSH_G_FILE"
}

reset_operator() {
  T_ONLINE=true
  T_KEYS="[\"ssh-ed25519 $BLOB fixture\"]"
  T_DNS='Ctl1.Example.ts.net.'
  SELF_EXTRA=''
  EXTRA_PEERS=''
  G_HOST='ctl1.example.ts.net' G_PORT=22 G_USER=ops G_STRICT=ask G_EXTRA=''
  TARGET_ARG='ctl1.example.ts.net'
  ALIAS_ARG='ctl1-alias'
  FP_ARG="$FP"
  TOOL_PATH="$TMP/path-all"
  rm -f "$TMP/known_hosts" "$TMP/known_hosts2" "$TMP/global_known_hosts" "$TMP/known_hosts.old"
  write_known_hosts "$BLOB"
  unset MOCK_TAILSCALE_RC MOCK_TAILSCALE_SLEEP MOCK_SSH_RC BROKKR_CUTOVER_TIMEOUT_SECS
}

# run_op_keep PHASE: run with the current MOCK_TAILSCALE_JSON and ssh -G fixture.
run_op_keep() {
  run_raw operator "$1" operator --phase "$1" --target-dns-name "$TARGET_ARG" \
    --ssh-host "$ALIAS_ARG" --expected-host-key-fingerprint "$FP_ARG"
}

# run_op PHASE: rebuild both fixtures from the current variables, then run.
run_op() {
  build_status
  build_ssh_g
  run_op_keep "$1"
}

echo "control-node-ssh-cutover.test.sh"
echo "-- operator role"

reset_operator; run_op before
expect "operator before: pass" 0 pass "" "" \
  'all(d["checks"].values()) and d["counts"]=={"other_tailscale_ssh_nodes":0,"known_hosts_entries":1}'

reset_operator; T_KEYS=''; run_op after
expect "operator after: pass" 0 pass "" "" \
  'd["checks"]["target_advertises_tailscale_ssh"] is False and "tailscale_ssh_presents_expected_key" not in d["checks"]'

reset_operator; T_KEYS="[\"ssh-rsa $OBLOB\",\"ssh-ed25519 $BLOB\"]"; run_op before
expect "operator before: advertised key without comment among several passes" 0 pass "" ""

reset_operator; TARGET_ARG='missing.example.ts.net'; run_op before
expect "operator: unknown target is blocked" 2 blocked target_not_found ""

reset_operator
EXTRA_PEERS=",\"nodekey:bbb\":{\"DNSName\":\"CTL1.example.ts.net\",\"Online\":true,\"sshHostKeys\":[\"ssh-ed25519 $OBLOB\"]}"
run_op before
expect "operator: ambiguous target is blocked" 2 blocked target_ambiguous ""

reset_operator; T_ONLINE=false; run_op before
expect "operator: offline target is blocked" 2 blocked target_offline "" \
  'd["checks"]["target_online"] is False'

reset_operator; T_KEYS=''; run_op before
expect "operator before: Tailscale SSH not advertised" 2 blocked tailscale_ssh_not_advertised tailscale_ssh_host_key_differs

reset_operator; T_KEYS='[]'; run_op before
expect "operator before: empty sshHostKeys is not advertised" 2 blocked tailscale_ssh_not_advertised tailscale_ssh_host_key_differs

reset_operator; run_op after
expect "operator after: Tailscale SSH still advertised" 2 blocked tailscale_ssh_still_advertised ""

reset_operator; G_HOST='198.51.100.7'; run_op before
expect "operator: non-tailnet ssh route" 2 blocked known_hosts_missing_expected_key,ssh_route_not_tailnet "" \
  'd["checks"]["ssh_route_tailnet"] is False'

reset_operator; G_HOST='ctl1.example.org'; run_op before
expect "operator: first label of a different domain is not tailnet" 2 blocked known_hosts_missing_expected_key,ssh_route_not_tailnet ""

reset_operator; G_HOST='192.0.2.50'; run_op before
expect "operator: hostname equal to a TailscaleIP passes" 0 pass "" ""

reset_operator; G_HOST='ctl1'; run_op before
expect "operator: first-label short name passes" 0 pass "" ""

reset_operator; G_EXTRA=$'proxyjump jump.example\n'; run_op before
expect "operator: ProxyJump is rejected" 2 blocked ssh_route_proxied ""

reset_operator; G_EXTRA=$'proxycommand nc %h %p\n'; run_op before
expect "operator: ProxyCommand is rejected" 2 blocked ssh_route_proxied ""

reset_operator; G_EXTRA=$'proxyjump none\nproxycommand none\n'; run_op before
expect "operator: explicit proxy none passes" 0 pass "" ""

reset_operator; G_PORT=2222; run_op before
expect "operator: non-22 port" 2 blocked ssh_port_not_22 ""

reset_operator; G_USER=root; run_op before
expect "operator: root ssh user" 2 blocked ssh_user_root ""

for mode in false no off accept-new unexpected; do
  reset_operator; G_STRICT="$mode"; run_op before
  expect "operator: StrictHostKeyChecking $mode is weak" 2 blocked strict_host_key_checking_weak ""
done

reset_operator; G_STRICT=''; run_op before
expect "operator: missing StrictHostKeyChecking fails closed" 2 blocked strict_host_key_checking_weak "" \
  'd["checks"]["strict_host_key_checking_enforced"] is False'
for mode in ask true yes; do
  reset_operator; G_STRICT="$mode"; run_op before
  expect "operator: StrictHostKeyChecking $mode passes" 0 pass "" ""
done

reset_operator; write_known_hosts "$OBLOB"; run_op before
expect "operator: known_hosts lacks the expected key" 2 blocked known_hosts_missing_expected_key "" \
  'd["counts"]["known_hosts_entries"]==1 and d["checks"]["known_hosts_has_expected_key"] is False'

reset_operator; rm -f "$TMP/known_hosts"; run_op before
expect "operator: no known_hosts file at all" 2 blocked known_hosts_missing_expected_key "" \
  'd["counts"]["known_hosts_entries"]==0'

reset_operator
printf '%s\n' "ctl1.example.ts.net,ctl1 ssh-ed25519 $BLOB" "@revoked ctl1.example.ts.net,ctl1 ssh-ed25519 $BLOB" >"$TMP/known_hosts"
run_op before
expect "operator: revoked expected key" 2 blocked expected_host_key_revoked "" \
  'd["checks"]["known_hosts_has_expected_key"] is False'

reset_operator
printf '%s\n' "ctl1.example.ts.net,ctl1 ssh-ed25519 $BLOB" "@revoked ctl1.example.ts.net,ctl1 ssh-ed25519 $OBLOB" >"$TMP/known_hosts"
run_op before
expect "operator: revocation of a different key does not block" 0 pass "" "" \
  'd["counts"]["known_hosts_entries"]==1'

reset_operator
printf '%s\n' "@cert-authority *.example.ts.net ssh-ed25519 $BLOB" >"$TMP/known_hosts"
run_op before
expect "operator: cert-authority entries are ignored" 2 blocked known_hosts_missing_expected_key "" \
  'd["counts"]["known_hosts_entries"]==0'

reset_operator
ssh-keygen -H -f "$TMP/known_hosts" >/dev/null 2>&1
rm -f "$TMP/known_hosts.old"
if grep -q '^|1|' "$TMP/known_hosts"; then
  run_op before
  expect "operator: hashed known_hosts entry still matches" 0 pass "" "" \
    'd["counts"]["known_hosts_entries"]==1'
else
  bad "operator: hashed known_hosts fixture was not hashed"
fi

reset_operator
printf 'keyalias.example ssh-ed25519 %s\n' "$BLOB" >"$TMP/known_hosts"
G_EXTRA=$'hostkeyalias keyalias.example\n'; run_op before
expect "operator: HostKeyAlias is the known_hosts lookup name" 0 pass "" ""

reset_operator
G_EXTRA=$'hostkeyalias none\n'; run_op before
expect "operator: HostKeyAlias none falls back to hostname" 0 pass "" ""

reset_operator
printf 'keyalias.example ssh-ed25519 %s\n' "$BLOB" >"$TMP/known_hosts"
G_EXTRA=$'hostkeyalias other-alias.example\n'; run_op before
expect "operator: HostKeyAlias hides a hostname-keyed entry" 2 blocked known_hosts_missing_expected_key ""

reset_operator
rm -f "$TMP/known_hosts"
printf 'ctl1.example.ts.net ssh-ed25519 %s\n' "$BLOB" >"$TMP/global_known_hosts"
run_op before
expect "operator: global known_hosts file is consulted" 0 pass "" ""

reset_operator
EXTRA_PEERS=",\"nodekey:bbb\":{\"DNSName\":\"other.example.ts.net.\",\"Online\":true,\"sshHostKeys\":[\"ssh-ed25519 AAAA\"]},\"nodekey:ccc\":{\"DNSName\":\"quiet.example.ts.net.\",\"Online\":true,\"sshHostKeys\":[]},\"nodekey:ddd\":{\"DNSName\":\"plain.example.ts.net.\",\"Online\":false}"
SELF_EXTRA=',"sshHostKeys":["ssh-ed25519 AAAA"]'
run_op before
expect "operator: other Tailscale SSH nodes are a warning with a count" 0 pass "" other_tailscale_ssh_nodes_present \
  'd["counts"]["other_tailscale_ssh_nodes"]==2'

reset_operator; T_KEYS="[\"ssh-ed25519 $OBLOB fixture\"]"; run_op before
expect "operator before: different advertised host key is a warning" 0 pass "" tailscale_ssh_host_key_differs \
  'd["checks"]["tailscale_ssh_presents_expected_key"] is False'

reset_operator; FP_ARG="$OFP"; run_op before
expect "operator before: expected key absent from known_hosts and Tailscale" 2 blocked known_hosts_missing_expected_key tailscale_ssh_host_key_differs

echo "-- operator role: errors and blocked backend"

reset_operator; FP_ARG='SHA256:tooshort'; run_op before
expect "operator: invalid fingerprint is an error" 1 error invalid_arguments ""

reset_operator; FP_ARG="MD5:${FP#SHA256:}"; run_op before
expect "operator: wrong fingerprint algorithm is an error" 1 error invalid_arguments ""

reset_operator; TARGET_ARG='ctl1'; run_op before
expect "operator: dotless target name is an error" 1 error invalid_arguments ""

reset_operator; TARGET_ARG='ctl1.example.ts.net/x'; run_op before
expect "operator: malformed target name is an error" 1 error invalid_arguments ""

reset_operator; ALIAS_ARG='bad alias'; run_op before
expect "operator: ssh alias with a space is an error" 1 error invalid_arguments ""

run_raw operator before operator --phase before --target-dns-name ctl1.example.ts.net --ssh-host=-oProxyCommand=x \
  --expected-host-key-fingerprint "$FP"
expect "operator: ssh alias starting with a dash is an error" 1 error invalid_arguments ""

run_raw operator null operator --phase during --target-dns-name ctl1.example.ts.net --ssh-host ctl1-alias \
  --expected-host-key-fingerprint "$FP"
expect "operator: invalid phase is an error" 1 error invalid_arguments ""

run_raw operator before operator --phase before --target-dns-name ctl1.example.ts.net
expect "operator: missing arguments are an error" 1 error invalid_arguments ""

run_raw operator after operator --phase after --target-dns-name ctl1.example.ts.net --ssh-host ctl1-alias \
  --expected-host-key-fingerprint "$FP" --bogus
expect "operator: unknown option is an error" 1 error invalid_arguments ""

run_raw null null
expect "no arguments is an error" 1 error invalid_arguments ""

run_raw null before bogus --phase before
expect "unknown role is an error" 1 error invalid_arguments ""

run_raw null null --help
expect "--help does not print usage text" 1 error invalid_arguments ""

run_raw operator null operator -h
expect "operator -h does not print usage text" 1 error invalid_arguments ""

for bad_timeout in 0 -1 abc 1.5 ''; do
  reset_operator; build_status; build_ssh_g
  BROKKR_CUTOVER_TIMEOUT_SECS="$bad_timeout"; export BROKKR_CUTOVER_TIMEOUT_SECS
  run_op_keep before
  expect "operator: invalid timeout '$bad_timeout' is an error" 1 error invalid_arguments ""
done
unset BROKKR_CUTOVER_TIMEOUT_SECS

reset_operator; export MOCK_TAILSCALE_RC=7; run_op before
expect "operator: tailscale exit non-zero is an error" 1 error tailscale_status_failed ""

reset_operator; export MOCK_TAILSCALE_SLEEP=5 BROKKR_CUTOVER_TIMEOUT_SECS=1; run_op before
expect "operator: hung tailscale times out" 1 error tailscale_status_timeout ""

reset_operator; TOOL_PATH="$TMP/path-no-tailscale"; run_op before
expect "operator: missing tailscale binary is an error" 1 error tailscale_status_unavailable ""

reset_operator; build_ssh_g; export MOCK_TAILSCALE_JSON='not json'
run_op_keep before
expect "operator: unparseable tailscale output is an error" 1 error tailscale_status_invalid ""

export MOCK_TAILSCALE_JSON='[]'
run_op_keep before
expect "operator: non-object tailscale output is an error" 1 error tailscale_status_invalid ""

MOCK_TAILSCALE_JSON="$(head -c 50000 /dev/zero | tr '\0' '[')"
export MOCK_TAILSCALE_JSON
run_op_keep before
expect "operator: deeply nested tailscale output is an error, not a traceback" 1 error tailscale_status_invalid ""

reset_operator; EXTRA_PEERS=',"nodekey:bad":"not-an-object"'; run_op before
expect "operator: non-object peer is an error" 1 error tailscale_status_invalid ""

reset_operator; T_KEYS='["ssh-ed25519 !!!not-base64!!!"]'; run_op before
expect "operator before: malformed advertised host key is an error" 1 error tailscale_status_invalid ""

reset_operator; build_ssh_g; export MOCK_TAILSCALE_JSON='{"BackendState":"Stopped"}'
run_op_keep before
expect "operator: stopped Tailscale is blocked" 2 blocked tailscale_not_running ""

reset_operator; build_ssh_g; export MOCK_TAILSCALE_JSON='{"BackendState":"Running"}'
run_op_keep after
expect "operator: no peers at all means target_not_found" 2 blocked target_not_found ""

reset_operator; export MOCK_SSH_RC=255; run_op before
expect "operator: ssh -G failure is an error" 1 error ssh_config_unavailable ""

reset_operator; build_status; printf 'user ops\nport 22\n' >"$MOCK_SSH_G_FILE"
run_op_keep before
expect "operator: ssh -G output without a hostname is an error" 1 error ssh_config_unavailable ""

reset_operator; TOOL_PATH="$TMP/path-no-ssh"; run_op before
expect "operator: missing ssh binary is an error" 1 error ssh_config_unavailable ""

reset_operator; TOOL_PATH="$TMP/path-badkeygen"; run_op before
expect "operator: failing ssh-keygen is an error" 1 error known_hosts_lookup_failed ""

reset_operator; TOOL_PATH="$TMP/path-garblekeygen"; run_op before
expect "operator: unparseable ssh-keygen output is an error" 1 error known_hosts_lookup_failed ""

# ----------------------------------------------------------- host-role fixtures
echo "-- host role"

HOST_USER_OK=1
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$USERNAME" = root ]; then
  HOST_USER_OK=0
  echo "  NOTE  host-role cases skipped: the current user name is not usable as the --ssh-user fixture"
fi
if [ -z "$KEYBASE" ]; then
  HOST_USER_OK=0
  echo "  NOTE  host-role cases skipped: no temp base with a root/user-owned, non-writable ancestor chain"
fi

ssh-keygen -q -t ecdsa -b 256 -N '' -C fixture -f "$TMP/ecdsakey"
EBLOB="$(awk '{print $2}' "$TMP/ecdsakey.pub")"
cat >"$TMP/skblob.py" <<'EOF'
import base64
import struct

key_type = b"sk-ssh-ed25519@openssh.com"
print(base64.b64encode(struct.pack(">I", len(key_type)) + key_type + b"fixture").decode())
EOF
SKBLOB="$("$PYTHON" "$TMP/skblob.py")"

reset_host() {
  H_STATE=Running H_SELF_ONLINE=true H_IPS='"192.0.2.50","2001:db8::50"'
  S_PUBKEY=yes S_PASSWORD=no S_KBD=no S_CR='' S_ROOT=no S_USEDNS=no S_PORTS=22
  S_LISTEN='0.0.0.0:22 [::]:22' S_ALLOW='' S_DENY='' S_ALLOWG='' S_DENYG='' S_AKC=none S_EXTRA=''
  S_AKF="$KEYBASE/keys/%u/authorized_keys"
  R_ON=0 R_ROOT=no R_PASSWORD=no
  H_USER="$USERNAME" H_CLIENT="$CLIENT4"
  MOCK_ACTIVE_UNITS='ssh.service'
  TOOL_PATH="$TMP/path-all"
  chmod 700 "$KEYBASE"
  rm -rf "$KEYBASE/keys" "$KEYBASE/unsafe" "$KEYBASE/safe"
  mkdir -p "$KEYBASE/keys/$USERNAME"
  chmod 755 "$KEYBASE/keys" "$KEYBASE/keys/$USERNAME"
  write_keys '# operator key' '' "ssh-ed25519 $BLOB one" "ssh-ed25519 $OBLOB two"
  unset MOCK_TAILSCALE_RC MOCK_TAILSCALE_SLEEP MOCK_SSHD_RC MOCK_SSHD_ROOT_RC MOCK_SSHD_ROOT_CONFIG BROKKR_CUTOVER_TIMEOUT_SECS
  export MOCK_ACTIVE_UNITS
}

# write_keys LINE...: replace the operator's authorized_keys with LINEs (mode 0644).
write_keys() {
  printf '%s\n' "$@" >"$KEYBASE/keys/$USERNAME/authorized_keys"
  chmod 644 "$KEYBASE/keys/$USERNAME/authorized_keys"
}

# render_sshd: print a fake `sshd -T` configuration from the current S_* variables.
render_sshd() {
  local item
  set -f # the AllowUsers/DenyUsers/group fixtures contain literal wildcards
  {
    for item in $S_PORTS; do printf 'port %s\n' "$item"; done
    for item in $S_LISTEN; do printf 'listenaddress %s\n' "$item"; done
    if [ -n "$S_PUBKEY" ]; then printf 'pubkeyauthentication %s\n' "$S_PUBKEY"; fi
    if [ -n "$S_PASSWORD" ]; then printf 'passwordauthentication %s\n' "$S_PASSWORD"; fi
    if [ -n "$S_KBD" ]; then printf 'kbdinteractiveauthentication %s\n' "$S_KBD"; fi
    if [ -n "$S_CR" ]; then printf 'challengeresponseauthentication %s\n' "$S_CR"; fi
    if [ -n "$S_ROOT" ]; then printf 'permitrootlogin %s\n' "$S_ROOT"; fi
    if [ -n "$S_USEDNS" ]; then printf 'usedns %s\n' "$S_USEDNS"; fi
    for item in $S_ALLOW; do printf 'allowusers %s\n' "$item"; done
    for item in $S_DENY; do printf 'denyusers %s\n' "$item"; done
    for item in $S_ALLOWG; do printf 'allowgroups %s\n' "$item"; done
    for item in $S_DENYG; do printf 'denygroups %s\n' "$item"; done
    printf 'authorizedkeysfile %s\n' "$S_AKF"
    printf 'authorizedkeyscommand %s\n' "$S_AKC"
    printf '%s' "$S_EXTRA"
  }
  set +f
}

# build_host: write the tailscale status and the operator-context sshd -T output. When
# R_ON=1 the root-context output differs by R_ROOT and R_PASSWORD (as a Match block
# would); otherwise the root context falls back to the operator output.
build_host() {
  local root_config
  export MOCK_TAILSCALE_JSON="{\"BackendState\":\"${H_STATE}\",\"TailscaleIPs\":[${H_IPS}],\"Self\":{\"Online\":${H_SELF_ONLINE},\"DNSName\":\"ctl1.example.ts.net.\"}}"
  render_sshd >"$MOCK_SSHD_FILE"
  : >"$MOCK_SSHD_ARGV_FILE"
  if [ "$R_ON" -eq 1 ]; then
    root_config="$(S_ROOT="$R_ROOT" S_PASSWORD="$R_PASSWORD" render_sshd)"
    export MOCK_SSHD_ROOT_CONFIG="$root_config"
  else
    unset MOCK_SSHD_ROOT_CONFIG
  fi
}

# run_host_keep PHASE: run with the current tailscale/sshd fixtures.
run_host_keep() {
  run_raw host "$1" host --phase "$1" --ssh-user "$H_USER" --client-address "$H_CLIENT"
}

# run_host PHASE: rebuild both fixtures from the current variables, then run.
run_host() {
  build_host
  run_host_keep "$1"
}

# expect_sshd_argv DESC LINE...: the recorded sshd invocations equal LINE... exactly.
expect_sshd_argv() {
  local desc="$1" want got
  shift
  want="$(printf '%s\n' "$@")"
  got="$(cat "$MOCK_SSHD_ARGV_FILE")"
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (recorded: $got)"; fi
}

if [ "$HOST_USER_OK" -eq 1 ]; then
  reset_host; run_host before
  expect "host before: pass" 0 pass "" "" \
    'all(d["checks"].values()) and d["counts"]=={"operator_authorized_keys":2}'

  reset_host; run_host after
  expect "host after: pass" 0 pass "" "" 'd["phase"]=="after"'

  reset_host; S_PUBKEY=no; run_host before
  expect "host: public key authentication disabled" 2 blocked pubkey_auth_disabled ""

  reset_host; S_PUBKEY=''; run_host before
  expect "host: missing pubkeyauthentication fails closed" 2 blocked pubkey_auth_disabled ""

  reset_host; S_PASSWORD=yes; run_host before
  expect "host: password authentication enabled" 2 blocked password_auth_enabled ""

  reset_host; S_PASSWORD=''; run_host before
  expect "host: missing passwordauthentication fails closed" 2 blocked password_auth_enabled ""

  reset_host; S_KBD=yes; run_host before
  expect "host: keyboard-interactive enabled" 2 blocked kbd_interactive_auth_enabled ""

  reset_host; S_KBD=''; S_CR=yes; run_host before
  expect "host: legacy challengeresponseauthentication yes is honoured" 2 blocked kbd_interactive_auth_enabled ""

  reset_host; S_KBD=''; S_CR=no; run_host before
  expect "host: legacy challengeresponseauthentication no passes" 0 pass "" ""

  reset_host; S_KBD=''; S_CR=''; run_host before
  expect "host: neither kbd option present is treated as enabled" 2 blocked kbd_interactive_auth_enabled ""

  # UseDNS: hostname-based Match/AllowUsers semantics cannot be evaluated from an address.
  reset_host; S_USEDNS=yes; run_host before
  expect "host: UseDNS yes is blocked" 2 blocked usedns_enabled "" \
    'd["checks"]["usedns_disabled"] is False'

  reset_host; S_USEDNS=''; run_host before
  expect "host: missing usedns fails closed" 2 blocked usedns_enabled ""

  # PermitRootLogin must be exactly "no" in the root connection context. The key-based
  # values stay blocked because AuthorizedKeysCommand, TrustedUserCAKeys or principals
  # can authorize root without any local key file.
  reset_host; S_ROOT=yes; run_host before
  expect "host: PermitRootLogin yes" 2 blocked root_login_permitted ""

  reset_host; S_ROOT=forced-commands-only; run_host before
  expect "host: PermitRootLogin forced-commands-only" 2 blocked root_login_permitted ""

  reset_host; S_ROOT=''; run_host before
  expect "host: missing permitrootlogin fails closed" 2 blocked root_login_permitted ""

  reset_host; S_ROOT=prohibit-password; run_host before
  expect "host: prohibit-password is blocked even with no root key file" 2 blocked root_key_login_possible "" \
    'd["checks"]["root_login_safe"] is False and set(d["counts"])=={"operator_authorized_keys"}'

  reset_host; S_ROOT=without-password; run_host before
  expect "host: without-password is blocked even with no root key file" 2 blocked root_key_login_possible ""

  reset_host; S_PORTS='2222 22'; run_host before
  expect "host: port 22 among several ports passes" 0 pass "" ""

  reset_host; S_PORTS=2222 S_LISTEN='0.0.0.0:2222'; run_host before
  expect "host: sshd not on port 22" 2 blocked sshd_not_listening_on_tailnet,sshd_port_not_22 ""

  # Listener: exactly laddr, or the unspecified address of laddr's own family.
  reset_host; S_LISTEN='0.0.0.0:22'; run_host before
  expect "host: IPv4 wildcard listener passes for an IPv4 client" 0 pass "" ""

  reset_host; S_LISTEN='[::]:22'; run_host before
  expect "host: IPv6 wildcard alone does not serve an IPv4 client" 2 blocked sshd_not_listening_on_tailnet "" \
    'd["checks"]["sshd_listens_on_tailnet"] is False'

  reset_host; S_LISTEN='[2001:db8::50]:22'; run_host before
  expect "host: IPv6 tailnet address alone does not serve an IPv4 client" 2 blocked sshd_not_listening_on_tailnet ""

  reset_host; S_LISTEN='[::]:22'; H_CLIENT="$CLIENT6"; run_host before
  expect "host: IPv6 wildcard listener passes for an IPv6 client" 0 pass "" ""

  reset_host; S_LISTEN='0.0.0.0:22'; H_CLIENT="$CLIENT6"; run_host before
  expect "host: IPv4 wildcard alone does not serve an IPv6 client" 2 blocked sshd_not_listening_on_tailnet ""

  reset_host; S_LISTEN='192.0.2.50:22'; run_host before
  expect "host: exact IPv4 laddr listener warns" 0 pass "" sshd_bound_to_tailnet_address_only \
    'd["checks"]["sshd_listens_on_tailnet"] is True'

  reset_host; S_LISTEN='192.0.2.50:22 [::]:22'; run_host before
  expect "host: exact laddr with only a foreign-family wildcard still warns" 0 pass "" sshd_bound_to_tailnet_address_only

  reset_host; S_LISTEN='192.0.2.50:22 0.0.0.0:22'; run_host before
  expect "host: same-family wildcard beside an exact laddr does not warn" 0 pass "" ""

  reset_host; S_LISTEN='[2001:db8:0:0:0:0:0:50]:22'; H_CLIENT="$CLIENT6"; run_host before
  expect "host: exact IPv6 laddr is normalised and warns" 0 pass "" sshd_bound_to_tailnet_address_only

  reset_host; S_LISTEN='192.0.2.60:22'; run_host before
  expect "host: a different address than laddr is not enough" 2 blocked sshd_not_listening_on_tailnet ""

  reset_host; S_LISTEN='198.51.100.9:22 192.0.2.50:2222'; run_host before
  expect "host: no listen address reaches the tailnet" 2 blocked sshd_not_listening_on_tailnet ""

  reset_host; S_LISTEN=''; run_host before
  expect "host: no listen address at all" 2 blocked sshd_not_listening_on_tailnet ""

  # AllowUsers / DenyUsers (user@source patterns are evaluated against the client address).
  reset_host; S_ALLOW='someone-else'; run_host before
  expect "host: AllowUsers excludes the operator user" 2 blocked operator_user_not_allowed "" \
    'd["checks"]["operator_user_permitted"] is False'

  reset_host; S_ALLOW="someone-else ${USERNAME}@${CLIENT4}"; run_host before
  expect "host: AllowUsers user@address matches the client" 0 pass "" ""

  reset_host; S_ALLOW="${USERNAME}@198.51.100.0/24"; run_host before
  expect "host: AllowUsers user@network containing the client matches" 0 pass "" ""

  reset_host; S_ALLOW="${USERNAME}@192.0.2.0/24"; run_host before
  expect "host: AllowUsers user@network excluding the client is blocked" 2 blocked operator_user_not_allowed ""

  reset_host; S_ALLOW="${USERNAME}@198.51.*"; run_host before
  expect "host: AllowUsers user@wildcard matching the client address" 0 pass "" ""

  reset_host; S_ALLOW="${USERNAME}@192.0.*"; run_host before
  expect "host: AllowUsers user@wildcard not matching the client address" 2 blocked operator_user_not_allowed ""

  reset_host; S_ALLOW="${USERNAME}@2001:db8::/32"; H_CLIENT="$CLIENT6"; run_host before
  expect "host: AllowUsers user@IPv6 network containing the client" 0 pass "" ""

  reset_host; S_ALLOW="${USERNAME}@198.51.100.0/24"; H_CLIENT="$CLIENT6"; run_host before
  expect "host: AllowUsers IPv4 network never contains an IPv6 client" 2 blocked operator_user_not_allowed ""

  reset_host; S_ALLOW="${USERNAME}@!192.0.2.1"; run_host before
  expect "host: AllowUsers host negation is not evaluated" 2 blocked access_filter_not_evaluated ""

  reset_host; S_ALLOW="${USERNAME}@${CLIENT4},192.0.2.1"; run_host before
  expect "host: AllowUsers host list is not evaluated" 2 blocked access_filter_not_evaluated ""

  reset_host; S_ALLOW="!${USERNAME}"; run_host before
  expect "host: AllowUsers negated user is not evaluated" 2 blocked access_filter_not_evaluated ""

  reset_host; S_ALLOW="someone-else@!192.0.2.1 ${USERNAME}"; run_host before
  expect "host: an unevaluable pattern for another user does not matter" 0 pass "" ""

  reset_host; S_ALLOW='*'; run_host before
  expect "host: AllowUsers wildcard matches" 0 pass "" ""

  reset_host; S_DENY="$USERNAME"; run_host before
  expect "host: DenyUsers names the operator user" 2 blocked operator_user_denied ""

  reset_host; S_DENY='*'; run_host before
  expect "host: DenyUsers wildcard denies" 2 blocked operator_user_denied ""

  reset_host; S_DENY="${USERNAME}@198.51.100.0/24"; run_host before
  expect "host: DenyUsers user@network containing the client denies" 2 blocked operator_user_denied ""

  reset_host; S_DENY="${USERNAME}@192.0.2.0/24"; run_host before
  expect "host: DenyUsers user@network excluding the client passes" 0 pass "" ""

  reset_host; S_DENY="${USERNAME}@!192.0.2.1"; run_host before
  expect "host: DenyUsers host negation is not evaluated" 2 blocked access_filter_not_evaluated ""

  reset_host; S_DENY='someone-else'; run_host before
  expect "host: DenyUsers for another user passes" 0 pass "" ""

  reset_host; S_DENY="$USERNAME" S_ALLOW='someone-else'; run_host before
  expect "host: denied and not allowed are both reported" 2 blocked operator_user_denied,operator_user_not_allowed ""

  # AllowGroups / DenyGroups use the user's real primary group (and getgrouplist groups).
  if [ -n "$PRIMARY_GROUP" ]; then
    reset_host; S_DENYG="$PRIMARY_GROUP"; run_host before
    expect "host: DenyGroups names the primary group" 2 blocked operator_group_denied "" \
      'd["checks"]["operator_user_permitted"] is False'

    reset_host; S_DENYG="$NO_SUCH_GROUP"; run_host before
    expect "host: DenyGroups for a non-existent group passes" 0 pass "" ""

    reset_host; S_DENYG='*'; run_host before
    expect "host: DenyGroups wildcard denies" 2 blocked operator_group_denied ""

    reset_host; S_ALLOWG="$PRIMARY_GROUP"; run_host before
    expect "host: AllowGroups names the primary group" 0 pass "" ""

    reset_host; S_ALLOWG="$NO_SUCH_GROUP"; run_host before
    expect "host: AllowGroups without a matching group is blocked" 2 blocked operator_group_not_allowed ""

    reset_host; S_ALLOWG="$NO_SUCH_GROUP $PRIMARY_GROUP"; run_host before
    expect "host: AllowGroups with one matching entry passes" 0 pass "" ""

    reset_host; S_ALLOWG="${PRIMARY_GROUP:0:1}*"; run_host before
    expect "host: AllowGroups wildcard matches the primary group" 0 pass "" ""

    reset_host; S_ALLOWG="!$PRIMARY_GROUP"; run_host before
    expect "host: AllowGroups negation is not evaluated" 2 blocked access_filter_not_evaluated ""

    reset_host; S_DENYG="!$NO_SUCH_GROUP"; run_host before
    expect "host: DenyGroups negation is not evaluated" 2 blocked access_filter_not_evaluated ""
  else
    echo "  NOTE  group-filter cases skipped: id -gn gave no primary group name"
  fi

  reset_host; S_AKC=/usr/local/bin/lookup-keys; run_host before
  expect "host: AuthorizedKeysCommand is a warning" 0 pass "" authorized_keys_command_not_evaluated

  # Authorized keys: only well-formed keys count, unsafe files contribute nothing.
  reset_host; rm -f "$KEYBASE/keys/$USERNAME/authorized_keys"; run_host before
  expect "host: no authorized_keys file" 2 blocked operator_authorized_keys_missing "" \
    'd["counts"]["operator_authorized_keys"]==0'

  reset_host; write_keys '# nothing here' '' '   '; run_host before
  expect "host: authorized_keys with no key lines" 2 blocked operator_authorized_keys_missing ""

  reset_host; build_host
  sed -i.bak 's/^authorizedkeysfile .*/authorizedkeysfile none/' "$MOCK_SSHD_FILE"
  rm -f "$MOCK_SSHD_FILE.bak"
  run_host_keep before
  expect "host: AuthorizedKeysFile none means no key files" 2 blocked operator_authorized_keys_missing ""

  reset_host; write_keys 'not a public key'; run_host before
  expect "host: a non-key line is invalid and counts nothing" 2 blocked operator_authorized_keys_missing authorized_keys_invalid_lines \
    'd["counts"]["operator_authorized_keys"]==0'

  reset_host; write_keys "ssh-rsa $BLOB wrong-type"; run_host before
  expect "host: a key type with a blob of another type is invalid" 2 blocked operator_authorized_keys_missing authorized_keys_invalid_lines

  reset_host; write_keys 'ssh-ed25519 !!!not-base64!!!'; run_host before
  expect "host: a key type with a non-base64 blob is invalid" 2 blocked operator_authorized_keys_missing authorized_keys_invalid_lines

  reset_host; write_keys 'ssh-ed25519'; run_host before
  expect "host: a key type without a blob is invalid" 2 blocked operator_authorized_keys_missing authorized_keys_invalid_lines

  reset_host; write_keys "from=\"198.51.100.0/24\" ssh-ed25519 $BLOB options"; run_host before
  expect "host: an options-prefixed key does not count and warns" 2 blocked operator_authorized_keys_missing authorized_keys_options_not_evaluated \
    'd["counts"]["operator_authorized_keys"]==0'

  reset_host; write_keys "ssh-ed25519 $BLOB one" 'garbage line'; run_host before
  expect "host: a valid key beside an invalid line passes with a warning" 0 pass "" authorized_keys_invalid_lines \
    'd["counts"]["operator_authorized_keys"]==1'

  reset_host; write_keys "ssh-ed25519 $BLOB one" "command=\"true\" ssh-ed25519 $OBLOB two"; run_host before
  expect "host: a valid key beside an options-prefixed key passes with a warning" 0 pass "" authorized_keys_options_not_evaluated \
    'd["counts"]["operator_authorized_keys"]==1'

  reset_host; write_keys "ecdsa-sha2-nistp256 $EBLOB ecdsa" "sk-ssh-ed25519@openssh.com $SKBLOB sk"; run_host before
  expect "host: ecdsa and sk key types are usable keys" 0 pass "" "" \
    'd["counts"]["operator_authorized_keys"]==2'

  reset_host; chmod 664 "$KEYBASE/keys/$USERNAME/authorized_keys"; run_host before
  expect "host: group-writable authorized_keys is unsafe and counts nothing" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing "" \
    'd["checks"]["authorized_keys_safe"] is False and d["counts"]["operator_authorized_keys"]==0'

  reset_host; chmod 646 "$KEYBASE/keys/$USERNAME/authorized_keys"; run_host before
  expect "host: world-writable authorized_keys is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host; chmod 775 "$KEYBASE/keys/$USERNAME"; run_host before
  expect "host: group-writable parent directory is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host; chmod 775 "$KEYBASE/keys"; run_host before
  expect "host: group-writable ancestor directory is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host; chmod 770 "$KEYBASE"; run_host before
  expect "host: group-writable distant ancestor is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host
  mkdir "$KEYBASE/unsafe"
  chmod 775 "$KEYBASE/unsafe"
  rm -f "$KEYBASE/keys/$USERNAME/authorized_keys"
  printf 'ssh-ed25519 %s linked\n' "$BLOB" >"$KEYBASE/unsafe/real_keys"
  chmod 644 "$KEYBASE/unsafe/real_keys"
  ln -s "$KEYBASE/unsafe/real_keys" "$KEYBASE/keys/$USERNAME/authorized_keys"
  run_host before
  expect "host: a key file symlinked into an unsafe directory is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host
  mkdir "$KEYBASE/safe"
  chmod 755 "$KEYBASE/safe"
  rm -f "$KEYBASE/keys/$USERNAME/authorized_keys"
  printf 'ssh-ed25519 %s linked\n' "$BLOB" >"$KEYBASE/safe/real_keys"
  chmod 644 "$KEYBASE/safe/real_keys"
  ln -s "$KEYBASE/safe/real_keys" "$KEYBASE/keys/$USERNAME/authorized_keys"
  run_host before
  expect "host: a key file symlinked into a safe directory passes" 0 pass "" "" \
    'd["counts"]["operator_authorized_keys"]==1'

  reset_host; rm -f "$KEYBASE/keys/$USERNAME/authorized_keys"; mkdir "$KEYBASE/keys/$USERNAME/authorized_keys"; run_host before
  expect "host: authorized_keys that is a directory is unsafe" 2 blocked authorized_keys_unsafe_permissions,operator_authorized_keys_missing ""

  reset_host; build_host; export MOCK_SSHD_RC=255
  run_host_keep before
  expect "host: sshd -T failure is an error" 1 error sshd_config_unavailable ""

  reset_host; build_host; : >"$MOCK_SSHD_FILE"
  run_host_keep before
  expect "host: empty sshd -T output is an error" 1 error sshd_config_unavailable ""

  reset_host; MOCK_ACTIVE_UNITS=''; export MOCK_ACTIVE_UNITS; run_host before
  expect "host: sshd inactive" 2 blocked sshd_inactive ""

  reset_host; MOCK_ACTIVE_UNITS='ssh.socket'; export MOCK_ACTIVE_UNITS; run_host before
  expect "host: active ssh.socket counts" 0 pass "" ""

  reset_host; MOCK_ACTIVE_UNITS='sshd.service'; export MOCK_ACTIVE_UNITS; run_host before
  expect "host: active sshd.service counts" 0 pass "" ""

  reset_host; TOOL_PATH="$TMP/path-no-systemctl"; run_host before
  expect "host: missing systemctl is an error" 1 error systemctl_unavailable ""

  reset_host; H_USER=root; run_host before
  expect "host: root as --ssh-user is an error" 1 error invalid_arguments ""

  reset_host; H_USER='Bad User'; run_host before
  expect "host: malformed --ssh-user is an error" 1 error invalid_arguments ""

  reset_host; H_USER='nosuchuser-zz9'; run_host before
  expect "host: unknown --ssh-user is blocked" 2 blocked operator_user_missing ""

  reset_host; H_STATE=Stopped; run_host before
  expect "host: stopped Tailscale is blocked" 2 blocked tailscale_not_running ""

  reset_host; H_SELF_ONLINE=false; run_host before
  expect "host: offline self node" 2 blocked self_offline ""

  reset_host; H_IPS='"not-an-address"'; run_host before
  expect "host: invalid TailscaleIPs is an error" 1 error tailscale_status_invalid ""

  reset_host; build_host; export MOCK_TAILSCALE_RC=1
  run_host_keep before
  expect "host: tailscale exit non-zero is an error" 1 error tailscale_status_failed ""

  reset_host; build_host; export MOCK_TAILSCALE_SLEEP=5 BROKKR_CUTOVER_TIMEOUT_SECS=1
  run_host_keep before
  expect "host: hung tailscale times out" 1 error tailscale_status_timeout ""

  reset_host; build_host
  run_raw host null host --phase sometimes --ssh-user "$H_USER" --client-address "$H_CLIENT"
  expect "host: invalid phase is an error" 1 error invalid_arguments ""

  run_raw host before host --phase before --client-address "$H_CLIENT"
  expect "host: missing --ssh-user is an error" 1 error invalid_arguments ""

  run_raw host before host --phase before --ssh-user "$H_USER"
  expect "host: missing --client-address is an error" 1 error invalid_arguments ""

  for bad_client in not-an-ip 198.51.100.7/24 'fe80::1%eth0' 198.51.100.256 ''; do
    reset_host; H_CLIENT="$bad_client"; run_host before
    expect "host: invalid --client-address '$bad_client' is an error" 1 error invalid_arguments ""
  done

  echo "-- host role: sshd connection contexts (Match blocks)"

  reset_host; run_host before
  expect "host: pass for the connection context" 0 pass "" ""
  expect_sshd_argv "host: sshd -T -C is run for the operator and then the root context" \
    "-T -C user=$USERNAME,host=$CLIENT4,addr=$CLIENT4,laddr=192.0.2.50,lport=22" \
    "-T -C user=root,host=$CLIENT4,addr=$CLIENT4,laddr=192.0.2.50,lport=22"

  reset_host; H_CLIENT="$CLIENT6"; run_host before
  expect "host: IPv6 client address passes" 0 pass "" ""
  expect_sshd_argv "host: IPv6 client uses the IPv6 tailnet address as laddr" \
    "-T -C user=$USERNAME,host=$CLIENT6,addr=$CLIENT6,laddr=2001:db8::50,lport=22" \
    "-T -C user=root,host=$CLIENT6,addr=$CLIENT6,laddr=2001:db8::50,lport=22"

  reset_host; H_IPS='"2001:db8::50","192.0.2.60","192.0.2.50"'; S_LISTEN='192.0.2.60:22 0.0.0.0:22'; run_host before
  expect "host: tailnet addresses in mixed order pass" 0 pass "" ""
  expect_sshd_argv "host: laddr is the first tailnet address of the client's family" \
    "-T -C user=$USERNAME,host=$CLIENT4,addr=$CLIENT4,laddr=192.0.2.60,lport=22" \
    "-T -C user=root,host=$CLIENT4,addr=$CLIENT4,laddr=192.0.2.60,lport=22"

  reset_host; H_IPS='"192.0.2.50"'; H_CLIENT="$CLIENT6"; run_host before
  expect "host: IPv6 client with only IPv4 tailnet addresses is blocked" 2 blocked client_address_family_unavailable "" \
    'd["checks"]["client_address_family_available"] is False'

  reset_host; H_IPS='"2001:db8::50"'; run_host before
  expect "host: IPv4 client with only IPv6 tailnet addresses is blocked" 2 blocked client_address_family_unavailable ""

  reset_host; H_IPS=''; run_host before
  expect "host: no tailnet addresses at all is blocked" 2 blocked client_address_family_unavailable ""

  reset_host; S_PASSWORD=yes R_ON=1 R_PASSWORD=no; run_host before
  expect "host: Match-style password loosening in the operator context" 2 blocked password_auth_enabled ""

  reset_host; S_PASSWORD=no R_ON=1 R_PASSWORD=yes; run_host before
  expect "host: the root context is not used for password authentication" 0 pass "" ""

  reset_host; S_ROOT=no R_ON=1 R_ROOT=yes; run_host before
  expect "host: root context permits root login while the operator context does not" 2 blocked root_login_permitted ""

  reset_host; S_ROOT=yes R_ON=1 R_ROOT=no; run_host before
  expect "host: root login is judged from the root context only" 0 pass "" ""

  reset_host; S_ROOT=no R_ON=1 R_ROOT=prohibit-password; run_host before
  expect "host: root context prohibit-password is blocked" 2 blocked root_key_login_possible ""

  reset_host; build_host; export MOCK_SSHD_ROOT_RC=255
  run_host_keep before
  expect "host: root-context sshd -T failure is an error" 1 error sshd_config_unavailable ""

  reset_host; build_host; export MOCK_SSHD_ROOT_CONFIG=''
  run_host_keep before
  expect "host: empty root-context sshd -T output is an error" 1 error sshd_config_unavailable ""
fi

# --------------------------------------------------------------- unit: helpers
echo "-- unit: helper functions"
cat >"$TMP/unit.py" <<'EOF'
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
section, check_path, keybase, blob = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("cutover", check_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
failures = []


def expect(name, got, want):
    if got != want:
        failures.append((name, got, want))


if section == "expand":
    expand = module.expand_authorized_keys_path
    cases = [
        (("%h/.ssh/ak", "/h", "u", 7), "/h/.ssh/ak"),
        ((".ssh/ak", "/h", "u", 7), "/h/.ssh/ak"),
        (("/etc/keys/%u", "/h", "u", 7), "/etc/keys/u"),
        (("/etc/keys/%U", "/h", "u", 7), "/etc/keys/7"),
        (("/etc/%%u/%u", "/h", "u", 7), "/etc/%u/u"),
    ]
    for args, want in cases:
        expect(args, expand(*args), want)

elif section == "groups":
    class Entry:
        def __init__(self, name, members):
            self.gr_name = name
            self.gr_mem = members

    names = {5: "primary", 10: "wheel"}

    def fake_getgrgid(gid):
        if gid in names:
            return Entry(names[gid], [])
        raise KeyError(gid)

    def fake_getgrouplist(name, gid):
        if name == "u":
            return [gid, 10, 99]
        raise OSError("lookup failed")

    module.grp.getgrgid = fake_getgrgid
    module.os.getgrouplist = fake_getgrouplist
    expect("getgrouplist groups with names; unnamed gids skipped", module.account_groups(module.Account("u", 1000, "/h", 5)), {"primary", "wheel"})
    expect("a failed getgrouplist fails the lookup", module.account_groups(module.Account("v", 1000, "/h", 5)), None)

elif section == "safe_path":
    base = os.path.join(keybase, "unit")
    home = os.path.join(base, "home")
    ssh_dir = os.path.join(home, ".ssh")
    key_file = os.path.join(ssh_dir, "authorized_keys")
    os.makedirs(ssh_dir)
    with open(key_file, "w", encoding="utf-8") as handle:
        handle.write("ssh-ed25519 %s one\n" % blob)
    account = module.Account("u", os.getuid(), home, os.getgid())

    def scan():
        result = module.authorized_keys_state([".ssh/authorized_keys"], account)
        return result.count, result.unsafe

    os.chmod(key_file, 0o600)
    os.chmod(ssh_dir, 0o700)
    os.chmod(home, 0o755)
    os.chmod(base, 0o770)  # group-writable above the home directory must not matter
    expect("walk stops at the home directory", scan(), (1, False))
    os.chmod(home, 0o775)
    expect("group-writable home directory is unsafe", scan(), (0, True))
    os.chmod(home, 0o755)
    os.chmod(ssh_dir, 0o770)
    expect("group-writable .ssh is unsafe", scan(), (0, True))
    os.chmod(ssh_dir, 0o700)
    os.chmod(key_file, 0o660)
    expect("group-writable key file is unsafe", scan(), (0, True))
    os.chmod(key_file, 0o600)
    expect("restored permissions are safe again", scan(), (1, False))

if failures:
    for failure in failures:
        print(failure)
    sys.exit(1)
EOF
unit_case() { # unit_case DESC SECTION
  local out
  if out="$("$PYTHON" "$TMP/unit.py" "$2" "$CHECK" "$KEYBASE" "$BLOB" 2>&1)"; then
    ok "$1"
  else
    bad "$1 ($out)"
  fi
}
unit_case "AuthorizedKeysFile token expansion" expand
unit_case "group resolution via getgrouplist" groups
if [ -n "$KEYBASE" ]; then
  unit_case "authorized_keys safe_path walk stops at the home directory" safe_path
else
  echo "  NOTE  safe_path unit case skipped: no safe temp base"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
