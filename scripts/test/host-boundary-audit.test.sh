#!/usr/bin/env bash
# Hermetic tests for host-boundary-audit.py and root-at-rest-inventory.py.
# ss, sshd, testparm, systemctl, lsblk and findmnt are fakes on a private PATH. No host, service,
# network or key file is touched. All names and addresses are reserved example values.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../host-boundary-audit.py"
INVENTORY="$HERE/../root-at-rest-inventory.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PYTHON="$(python3 -c 'import sys; print(sys.executable)')"
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
PASS=0
FAIL=0

check() { # name, condition-result
  if [ "$2" = ok ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; fi
}
jq_py() { "$PYTHON" -I -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub ss 'case "$*" in *-lun*) cat "${MOCK_SS_UDP:-/dev/null}";; *) cat "$MOCK_SS";; esac'
stub sshd 'if [[ "$*" == *"-C"* ]]; then case "$*" in *user=alice*) cat "$MOCK_SSHD_MATCH";; *) cat "$MOCK_SSHD_GLOBAL";; esac; else cat "$MOCK_SSHD_GLOBAL"; fi'
stub testparm 'cat "$MOCK_TESTPARM"'
stub systemctl 'case "$1" in is-active) echo "${MOCK_ACTIVE:-inactive}";; is-enabled) echo "${MOCK_ENABLED:-disabled}";; esac'
stub lsblk 'cat "$MOCK_LSBLK"'
stub findmnt 'printf "%s\n" "${@: -1}"'

cat >"$TMP/ss-open" <<'X'
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=1,fd=4))
LISTEN 0 50 0.0.0.0:445 0.0.0.0:* users:(("smbd",pid=2,fd=5))
LISTEN 0 50 0.0.0.0:139 0.0.0.0:* users:(("smbd",pid=2,fd=6))
LISTEN 0 128 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=3,fd=4))
LISTEN 0 5 0.0.0.0:5900 0.0.0.0:* users:(("wayvnc",pid=4,fd=3))
LISTEN 0 5 0.0.0.0:8080 0.0.0.0:*
LISTEN 0 5 127.0.0.1:8081 0.0.0.0:*
X
cat >"$TMP/ss-closed" <<'X'
LISTEN 0 128 192.0.2.10:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 127.0.0.1:445 0.0.0.0:* users:(("smbd",pid=2,fd=5))
X
cat >"$TMP/sshd-open" <<'X'
passwordauthentication yes
kbdinteractiveauthentication no
pubkeyauthentication yes
permitrootlogin without-password
allowtcpforwarding yes
allowagentforwarding yes
x11forwarding no
gatewayports no
allowstreamlocalforwarding yes
permittunnel no
port 22
listenaddress 0.0.0.0:22
X
cat >"$TMP/sshd-closed" <<'X'
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
permitrootlogin no
allowtcpforwarding no
allowagentforwarding no
x11forwarding no
gatewayports no
allowstreamlocalforwarding no
permittunnel no
maxauthtries 6
port 22
listenaddress 192.0.2.10:22
allowusers alice
X
cat >"$TMP/smb-open" <<'X'
[global]
	map to guest = Bad User
[share]
	guest ok = yes
X
cat >"$TMP/smb-closed" <<'X'
[global]
	bind interfaces only = Yes
	interfaces = 192.0.2.10/24
	server smb encrypt = required
[share]
	read only = no
X

run_audit() { PATH="$STUBS:$PATH" MOCK_SS="$1" MOCK_SSHD_GLOBAL="$2" MOCK_SSHD_MATCH="$3" MOCK_TESTPARM="$4" "$PYTHON" -I "$AUDIT" "${@:5}"; }

out="$(run_audit "$TMP/ss-open" "$TMP/sshd-open" "$TMP/sshd-open" "$TMP/smb-open" --role nas --context alice@192.0.2.50 2>"$TMP/err")"
check "open: no stderr" "$([ ! -s "$TMP/err" ] && echo ok)"
for code in ssh_listens_on_wildcard ssh_password_or_interactive_auth_possible ssh_root_login_not_disabled ssh_forwarding_enabled ssh_unmatched_peer_may_use_password smb_listens_on_wildcard smb_not_bound_to_interfaces smb_guest_access_possible rpcbind_listening_non_loopback vnc_listens_on_wildcard other_wildcard_listeners_present; do
  check "open: $code" "$(printf '%s' "$out" | jq_py "'$code' in d['findings']" | grep -q True && echo ok)"
done
check "open: wildcard other count 1" "$(printf '%s' "$out" | jq_py "d['other_wildcard_listener_count']" | grep -qx 1 && echo ok)"
check "open: vnc process class" "$(printf '%s' "$out" | jq_py "d['tcp_listeners']['5900']['process']" | grep -qx vnc && echo ok)"
check "content blind" "$(printf '%s' "$out" | grep -Eq '192\.0\.2|alice|\[share\]' && echo bad || echo ok)"

run_audit "$TMP/ss-open" "$TMP/sshd-open" "$TMP/sshd-open" "$TMP/smb-open" --role nas --fail-on-findings >/dev/null 2>&1
check "fail-on-findings exits 3" "$([ $? -eq 3 ] && echo ok)"

# Match rule: global open, but alice context is key-only -> differs_from_global, no password for context.
out="$(run_audit "$TMP/ss-closed" "$TMP/sshd-open" "$TMP/sshd-closed" "$TMP/smb-closed" --role control-node --context alice@192.0.2.50)"
check "match differs" "$(printf '%s' "$out" | jq_py "d['ssh']['contexts']['context_1']['differs_from_global']" | grep -q True && echo ok)"
check "match closes password" "$(printf '%s' "$out" | jq_py "d['ssh']['contexts']['context_1']['password_auth']" | grep -q False && echo ok)"
check "stranger still password" "$(printf '%s' "$out" | jq_py "d['ssh']['contexts']['stranger']['password_auth']" | grep -q True && echo ok)"

out="$(run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --role nas --context alice@192.0.2.50 --fail-on-findings)"
check "closed: clean and exit 0" "$([ $? -eq 0 ] && printf '%s' "$out" | jq_py "d['result']" | grep -qx clean && echo ok)"

run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --role nas --context 'bad ctx' >/dev/null 2>&1
check "invalid context exits 1" "$([ $? -eq 1 ] && echo ok)"
run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --role 'Bad Role' >/dev/null 2>&1
check "invalid role exits 1" "$([ $? -eq 1 ] && echo ok)"

# ------------------------------------------------------------- root-at-rest inventory
cat >"$TMP/lsblk" <<'X'
{"blockdevices":[
 {"name":"mmcblk0","type":"disk","tran":null,"mountpoints":[null],"children":[
   {"name":"mmcblk0p1","type":"part","tran":null,"mountpoints":["/boot"]},
   {"name":"mmcblk0p2","type":"part","tran":null,"mountpoints":["/"]}]},
 {"name":"sda","type":"disk","tran":"usb","mountpoints":[null],"children":[
   {"name":"sda1","type":"part","tran":null,"mountpoints":[null],"children":[
     {"name":"data","type":"crypt","tran":null,"mountpoints":["/srv/data"]}]}]}]}
X
inv="$(PATH="$STUBS:$PATH" MOCK_LSBLK="$TMP/lsblk" "$PYTHON" -I "$INVENTORY" --role nas --store data=/srv/data --store boot=/boot 2>"$TMP/err")"
check "inventory: no stderr" "$([ ! -s "$TMP/err" ] && echo ok)"
check "inventory: root absent" "$(printf '%s' "$inv" | jq_py "d['stores']['root']['block_layer']" | grep -qx absent && echo ok)"
check "inventory: root medium sd" "$(printf '%s' "$inv" | jq_py "d['stores']['root']['medium']" | grep -qx sd && echo ok)"
check "inventory: data encrypted" "$(printf '%s' "$inv" | jq_py "d['stores']['data']['block_layer']" | grep -qx encrypted && echo ok)"
check "inventory: data medium usb" "$(printf '%s' "$inv" | jq_py "d['stores']['data']['medium']" | grep -qx usb && echo ok)"
check "inventory: boot shares root disk" "$(printf '%s' "$inv" | jq_py "d['stores']['boot']['same_stack_as_root']" | grep -q True && echo ok)"
check "inventory: data not root disk" "$(printf '%s' "$inv" | jq_py "d['stores']['data']['same_stack_as_root']" | grep -q False && echo ok)"
check "inventory: content blind" "$(printf '%s' "$inv" | grep -Eq 'mmcblk|sda|srv' && echo bad || echo ok)"
PATH="$STUBS:$PATH" MOCK_LSBLK="$TMP/lsblk" "$PYTHON" -I "$INVENTORY" --role nas --store 'x=relative' >/dev/null 2>&1
check "inventory: relative path rejected" "$([ $? -eq 1 ] && echo ok)"
PATH="$STUBS:$PATH" MOCK_LSBLK="$TMP/lsblk" "$PYTHON" -I "$INVENTORY" --role nas --store 'root=/srv/data' >/dev/null 2>&1
check "inventory: root label reserved" "$([ $? -eq 1 ] && echo ok)"


# UDP, tunnel-only forwarding and context file
cat >"$TMP/ss-udp" <<'X'
UNCONN 0 0 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=3,fd=5))
UNCONN 0 0 192.0.2.10:137 0.0.0.0:*
X
out="$(MOCK_SS_UDP="$TMP/ss-udp" run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --role nas)"
check "udp rpcbind finding" "$(printf '%s' "$out" | jq_py "'rpcbind_listening_non_loopback' in d['findings'] and 'netbios_udp_listening' in d['findings']" | grep -q True && echo ok)"
sed 's/^allowtcpforwarding no/allowtcpforwarding local\npermitopen 127.0.0.1:5900/' "$TMP/sshd-closed" >"$TMP/sshd-tunnel"
out="$(run_audit "$TMP/ss-closed" "$TMP/sshd-tunnel" "$TMP/sshd-tunnel" "$TMP/smb-closed" --role nas)"
check "tunnel-only forwarding is not a finding" "$(printf '%s' "$out" | jq_py "'ssh_forwarding_enabled' not in d['findings'] and d['ssh']['global']['forwarding_restricted_tunnel']" | grep -q True && echo ok)"
printf 'alice@192.0.2.50\n' >"$TMP/ctx"; chmod 600 "$TMP/ctx"
out="$(run_audit "$TMP/ss-closed" "$TMP/sshd-open" "$TMP/sshd-closed" "$TMP/smb-closed" --role nas --context-file "$TMP/ctx")"
check "context file used" "$(printf '%s' "$out" | jq_py "d['ssh']['contexts']['context_1']['differs_from_global']" | grep -q True && echo ok)"
chmod 644 "$TMP/ctx"
run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --role nas --context-file "$TMP/ctx" >/dev/null 2>&1
check "group-readable context file rejected" "$([ $? -eq 1 ] && echo ok)"
run_audit "$TMP/ss-closed" "$TMP/sshd-closed" "$TMP/sshd-closed" "$TMP/smb-closed" --bogus >"$TMP/o" 2>"$TMP/e"
check "usage error exits 1 with empty stderr" "$([ $? -eq 1 ] && [ ! -s "$TMP/e" ] && echo ok)"

echo "host-boundary-audit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
