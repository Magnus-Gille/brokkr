#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/m5-network-profile.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-m5-network-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
  local name=$1
  shift
  if "$@"; then
    printf '  [PASS] %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  [FAIL] %s\n' "$name"
    fail=$((fail + 1))
  fi
}

mkdir -p "$TMP/etc/ssh/sshd_config.d" "$TMP/etc/samba" "$TMP/etc/ufw" "$TMP/etc/default" \
  "$TMP/state" "$TMP/run" "$TMP/bin"
chmod 0700 "$TMP/state"
printf 'IPV6=yes\n' >"$TMP/etc/default/ufw"
printf '[global]\n   workgroup = EXAMPLE\n   map to guest = Bad User\n   usershare allow guests = yes\n   load printers = yes\n\n[TimeMachine]\n   path = /srv/example\n' >"$TMP/etc/samba/smb.conf"
printf 'fixture ufw\n' >"$TMP/etc/ufw/user.rules"

CONFIG="$TMP/profile.conf"
printf '%s\n' \
  'operator_user=operator' \
  'management_interface=tailscale0' \
  'ssh_port=22' \
  'tailscale_transport=eth0|41641' \
  'samba_rule=eth0|192.0.2.0/24' \
  'samba_rule=tailscale0|198.51.100.0/24' \
  'listener=whisper|tcp|8092|management' \
  'listener=gateway|tcp|8080|management' \
  'listener=llama|tcp|8091|loopback' \
  'retain_netbios=false' \
  'ssh_agent_forwarding=false' \
  'ssh_tcp_forwarding=false' \
  'ssh_x11_forwarding=false' \
  'rollback_seconds=120' >"$CONFIG"
chmod 0600 "$CONFIG"

render="$TMP/render.out"
if "$SCRIPT" render --config "$CONFIG" >"$render" 2>&1; then
  render_rc=0
else
  render_rc=$?
fi
check "valid profile renders" test "$render_rc" -eq 0
check "render defaults incoming and routed traffic to deny" \
  grep -Fq 'ufw default deny incoming' "$render"
check "render permits the explicit configurable Tailscale transport" \
  grep -Fq 'ufw allow in on eth0 to any port 41641 proto udp' "$render"
check "SSH and management listeners are gated before Tailscale INPUT acceptance" \
  grep -Fq 'iifname "tailscale0" tcp dport { 22, 8080, 8092 } accept' "$render"
check "Samba is source-and-interface scoped" \
  bash -c 'grep -Fq "ufw allow in on eth0 from 192.0.2.0/24 to any port 445 proto tcp" "$1" && grep -Fq "iifname \"tailscale0\" ip saddr 198.51.100.0/24 tcp dport 445 accept" "$1"' _ "$render"
check "render contains no ineffective UFW allowance on tailscale0" \
  bash -c '! grep -Eq "^ufw allow in on tailscale0" "$1"' _ "$render"
check "NetBIOS is absent by default" \
  bash -c '! grep -Eq "port (137|138|139)" "$1"' _ "$render"
check "SSH password, root, keyboard-interactive, X11, agent, and TCP forwarding are disabled" \
  bash -c 'for line in "PermitRootLogin no" "PasswordAuthentication no" "KbdInteractiveAuthentication no" "X11Forwarding no" "AllowAgentForwarding no" "AllowTcpForwarding no"; do grep -Fq "$line" "$1" || exit 1; done' _ "$render"
check "Samba guest, usershare, printing, and wildcard binding are disabled" \
  bash -c 'for line in "map to guest = Never" "guest ok = no" "restrict anonymous = 2" "server min protocol = SMB3_00" "smb encrypt = required" "usershare allow guests = no" "usershare max shares = 0" "load printers = no" "bind interfaces only = yes" "smb ports = 445"; do grep -Fq "$line" "$1" || exit 1; done' _ "$render"
check "Samba uses allow-list-only semantics instead of a conflicting catch-all deny" \
  bash -c '! grep -Fq "hosts deny" "$1"' _ "$render"
check "loopback inference listener is represented without an inbound allow" \
  bash -c 'grep -Fq "listener llama tcp 8091 loopback" "$1" && ! grep -Eq "ufw allow .*port 8091" "$1"' _ "$render"

BAD_MANAGEMENT_INTERFACE="$TMP/bad-management-interface.conf"
sed 's/management_interface=tailscale0/management_interface=eth0/' "$CONFIG" >"$BAD_MANAGEMENT_INTERFACE"
chmod 0600 "$BAD_MANAGEMENT_INTERFACE"
if "$SCRIPT" render --config "$BAD_MANAGEMENT_INTERFACE" >"$TMP/bad-management-interface.out" 2>&1; then bad_management_rc=0; else bad_management_rc=$?; fi
check "a physical interface cannot be misconfigured as the management plane" test "$bad_management_rc" -ne 0

for collision in 'listener=bad-ssh|tcp|22|management' 'listener=bad-smb|tcp|445|management' 'listener=bad-netbios|udp|137|management'; do
  COLLISION_CONFIG="$TMP/collision.conf"
  printf '%s\n' "$collision" >"$COLLISION_CONFIG"
  cat "$CONFIG" >>"$COLLISION_CONFIG"
  chmod 0600 "$COLLISION_CONFIG"
  if "$SCRIPT" render --config "$COLLISION_CONFIG" >"$TMP/collision.out" 2>&1; then collision_rc=0; else collision_rc=$?; fi
  check "managed listener collision is rejected: ${collision#listener=}" test "$collision_rc" -ne 0
done

BAD="$TMP/bad.conf"
cp "$CONFIG" "$BAD"
printf 'ssh_tcp_forwarding=true\n' >>"$BAD"
chmod 0600 "$BAD"
if "$SCRIPT" render --config "$BAD" >"$TMP/bad.out" 2>&1; then bad_rc=0; else bad_rc=$?; fi
check "forwarding exceptions fail closed without a reviewed reason" test "$bad_rc" -ne 0

# Exercise the effective-policy verifier and the apply/confirmation transaction
# with hermetic command doubles.  No developer-machine firewall or daemon is
# touched by this test.
CALLS="$TMP/calls"
SERVICE_STATE="$TMP/service-state"
FILTER_SERVICE_STATE="$TMP/filter-service-state"
NFT_TABLE_STATE="$TMP/nft-table-state"
UFW_STATE="$TMP/ufw-state"
printf 'nmbd=active-enabled\n' >"$SERVICE_STATE"
printf 'inactive-disabled\n' >"$FILTER_SERVICE_STATE"
printf 'absent\n' >"$NFT_TABLE_STATE"
printf 'inactive\n' >"$UFW_STATE"
: >"$CALLS"
export MOCK_CALLS="$CALLS" MOCK_SERVICE_STATE="$SERVICE_STATE" MOCK_FILTER_SERVICE_STATE="$FILTER_SERVICE_STATE" MOCK_NFT_TABLE_STATE="$NFT_TABLE_STATE" MOCK_UFW_STATE="$UFW_STATE"

cat >"$TMP/bin/ufw" <<'EOF'
#!/usr/bin/env bash
printf 'ufw %s\n' "$*" >>"$MOCK_CALLS"
case "$*" in
  version) echo 'ufw 0.36';;
  status) if grep -qx active "$MOCK_UFW_STATE"; then echo 'Status: active'; else echo 'Status: inactive'; fi;;
  'status verbose')
    printf 'Status: active\nDefault: deny (incoming), allow (outgoing), deny (routed)\n'
    ;;
  'show added')
    cat <<'RULES'
ufw allow in on eth0 to any port 41641 proto udp comment 'brokkr tailscale transport'
ufw allow in on eth0 from 192.0.2.0/24 to any port 445 proto tcp comment 'brokkr samba'
RULES
    [[ "${MOCK_EXTRA_UFW_RULE:-}" != 1 ]] || printf "ufw allow in on eth0 to any port 9999 proto tcp comment 'unexpected'\n"
    [[ "${MOCK_EXTRA_UFW_NONALLOW:-}" != 1 ]] || printf "ufw route allow in on eth0 to any port 9998 proto tcp comment 'unexpected-route'\n"
    ;;
  '--force enable'|'--force reload') printf 'active\n' >"$MOCK_UFW_STATE";;
  '--force disable') [[ "${MOCK_FAIL_UFW_DISABLE:-}" != 1 ]] || exit 1; printf 'inactive\n' >"$MOCK_UFW_STATE";;
esac
EOF
cat >"$TMP/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$MOCK_CALLS"
if [[ "$1" == -T ]]; then
  cat <<'POLICY'
permitrootlogin no
pubkeyauthentication yes
port 22
passwordauthentication no
kbdinteractiveauthentication no
authenticationmethods publickey
x11forwarding no
allowagentforwarding no
allowtcpforwarding no
allowstreamlocalforwarding no
gatewayports no
permittunnel no
permituserenvironment no
POLICY
fi
EOF
cat >"$TMP/bin/testparm" <<'EOF'
#!/usr/bin/env bash
printf 'testparm %s\n' "$*" >>"$MOCK_CALLS"
cat <<'POLICY'
[global]
bind interfaces only = Yes
interfaces = lo eth0 tailscale0
hosts allow = 127.0.0.1 ::1 192.0.2.0/24 198.51.100.0/24
map to guest = Never
guest ok = No
restrict anonymous = 2
server min protocol = SMB3_00
smb encrypt = required
usershare allow guests = No
usershare max shares = 0
load printers = No
disable spoolss = Yes
smb ports = 445
[TimeMachine]
path = /srv/example
POLICY
if [[ "${MOCK_WEAK_SHARE:-}" == 1 ]]; then
  printf '[LegacyShare]\nguest ok = Yes\npublic = Yes\n'
fi
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_CALLS"
case "$*" in
  'is-active tailscaled') exit 0;;
  is-active\ brokkr-m5-network-rollback-*.timer) exit 1;;
  'is-active brokkr-m5-tailnet-filter.service') grep -qx 'active-enabled' "$MOCK_FILTER_SERVICE_STATE"; exit $?;;
  'is-enabled brokkr-m5-tailnet-filter.service') grep -qx 'active-enabled' "$MOCK_FILTER_SERVICE_STATE"; exit $?;;
  'enable --now brokkr-m5-tailnet-filter.service'|'enable brokkr-m5-tailnet-filter.service'|'start brokkr-m5-tailnet-filter.service') printf 'active-enabled\n' >"$MOCK_FILTER_SERVICE_STATE";;
  'disable --now brokkr-m5-tailnet-filter.service'|'disable brokkr-m5-tailnet-filter.service'|'stop brokkr-m5-tailnet-filter.service') printf 'inactive-disabled\n' >"$MOCK_FILTER_SERVICE_STATE";;
  'is-active nmbd.service') grep -qx 'nmbd=active-enabled' "$MOCK_SERVICE_STATE"; exit $?;;
  'is-enabled nmbd.service') grep -qx 'nmbd=active-enabled' "$MOCK_SERVICE_STATE"; exit $?;;
  'disable --now nmbd.service') printf 'nmbd=inactive-disabled\n' >"$MOCK_SERVICE_STATE";;
  'enable --now nmbd.service'|'enable nmbd.service'|'start nmbd.service') printf 'nmbd=active-enabled\n' >"$MOCK_SERVICE_STATE";;
  'disable nmbd.service'|'stop nmbd.service') printf 'nmbd=inactive-disabled\n' >"$MOCK_SERVICE_STATE";;
esac
exit 0
EOF
cat >"$TMP/bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-analyze %s\n' "$*" >>"$MOCK_CALLS"
exit 0
EOF
cat >"$TMP/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$MOCK_CALLS"
[[ "${1:-}" == --version ]] && echo 'systemd 999'
[[ "${1:-}" == --version || "${MOCK_FAIL_SCHEDULE:-}" != 1 ]] || exit 1
exit 0
EOF
cat >"$TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >>"$MOCK_CALLS"
if [[ "$1 $2" == 'route get' ]]; then echo "$3 dev tailscale0 src 198.51.100.10"; fi
EOF
cat >"$TMP/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'ss %s\n' "$*" >>"$MOCK_CALLS"
case "$*" in
  '-H -lnt')
    printf 'LISTEN 0 128 0.0.0.0:8092 0.0.0.0:*\n'
    printf 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*\n'
    printf 'LISTEN 0 128 127.0.0.1:8091 0.0.0.0:*\n'
    ;;
  '-H -lnup')
    printf 'UNCONN 0 0 0.0.0.0:41641 0.0.0.0:* users:(("tailscaled",pid=42,fd=7))\n'
    ;;
esac
EOF
cat >"$TMP/bin/nft" <<'EOF'
#!/usr/bin/env bash
printf 'nft %s\n' "$*" >>"$MOCK_CALLS"
case "$*" in
  '--check -f -') cat >/dev/null; exit 0;;
  '--check -f '*) exit 0;;
  '-f '*) printf 'present\n' >"$MOCK_NFT_TABLE_STATE"; exit 0;;
  'destroy table inet brokkr_m5_tailnet') printf 'absent\n' >"$MOCK_NFT_TABLE_STATE"; exit 0;;
  'list table inet brokkr_m5_tailnet')
    grep -qx present "$MOCK_NFT_TABLE_STATE" || exit 1
    printf 'table inet brokkr_m5_tailnet { chain tailnet_prerouting { type filter hook prerouting priority filter; policy accept; } }\n'
    ;;
  '-j -nn list chain inet brokkr_m5_tailnet tailnet_prerouting')
    [[ "${MOCK_NFT_FILTER_MISSING:-}" != 1 ]] || exit 1
    grep -qx present "$MOCK_NFT_TABLE_STATE" || exit 1
    printf '{"nftables":[{"chain":{"family":"inet","table":"brokkr_m5_tailnet","name":"tailnet_prerouting"}}'
    for _ in 1 2 3 4 5 6; do
      printf ',{"rule":{"family":"inet","table":"brokkr_m5_tailnet","chain":"tailnet_prerouting"}}'
    done
    if [[ "${MOCK_NFT_EXTRA_RULE:-}" == 1 ]]; then
      printf ',{"rule":{"family":"inet","table":"brokkr_m5_tailnet","chain":"tailnet_prerouting"}}'
    fi
    printf ']}\n'
    ;;
  '-nn list chain inet brokkr_m5_tailnet tailnet_prerouting')
    [[ "${MOCK_NFT_FILTER_MISSING:-}" != 1 ]] || exit 1
    grep -qx present "$MOCK_NFT_TABLE_STATE" || exit 1
    cat <<'RULES'
table inet brokkr_m5_tailnet {
 chain tailnet_prerouting {
  type filter hook prerouting priority filter; policy accept;
  iifname != "tailscale0" accept comment "brokkr:non-tailnet:continue"
  iifname "tailscale0" ct state established,related accept comment "brokkr:tailnet:established"
  iifname "tailscale0" meta l4proto { icmp, ipv6-icmp } accept comment "brokkr:tailnet:icmp"
  iifname "tailscale0" tcp dport { 22, 8080, 8092 } accept comment "brokkr:tailnet:management:tcp"
  iifname "tailscale0" ip saddr 198.51.100.0/24 tcp dport 445 accept comment "brokkr:tailnet:samba:0"
  iifname "tailscale0" drop comment "brokkr:tailnet:default-drop"
 }
}
RULES
    [[ "${MOCK_NFT_EXTRA_RULE:-}" != 1 ]] || printf '  iifname "tailscale0" accept\n'
    ;;
  'list ruleset') printf 'table ip filter { chain INPUT { jump ts-input; jump ufw-before-input; } chain ts-input { iifname "tailscale0" accept; } chain ufw-user-input {} }\n';;
esac
EOF
cat >"$TMP/bin/iptables" <<'EOF'
#!/usr/bin/env bash
printf 'iptables %s\n' "$*" >>"$MOCK_CALLS"
printf '%s\n' '-P INPUT DROP' '-A INPUT -j ts-input' '-A INPUT -j ufw-before-input' '-A INPUT -j ufw-reject-input'
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH"
export BROKKR_NETWORK_ETC_ROOT="$TMP/etc"
export BROKKR_NETWORK_STATE_ROOT="$TMP/state"
export BROKKR_NETWORK_RUN_ROOT="$TMP/run"
export BROKKR_NETWORK_TEST_SSH_CLIENT='198.51.100.20'

if "$SCRIPT" preflight --config "$CONFIG" >"$TMP/preflight.out" 2>&1; then preflight_rc=0; else preflight_rc=$?; fi
check "preflight validates the management route and current public-key capability" test "$preflight_rc" -eq 0
WRONG_PORT="$TMP/wrong-port.conf"
sed 's/tailscale_transport=eth0|41641/tailscale_transport=eth0|41642/' "$CONFIG" >"$WRONG_PORT"
chmod 0600 "$WRONG_PORT"
if "$SCRIPT" preflight --config "$WRONG_PORT" >"$TMP/wrong-port.out" 2>&1; then wrong_port_rc=0; else wrong_port_rc=$?; fi
check "preflight rejects a configured transport port not owned by active tailscaled" test "$wrong_port_rc" -ne 0

if MOCK_FAIL_SCHEDULE=1 "$SCRIPT" apply --config "$CONFIG" >"$TMP/schedule-fail.out" 2>&1; then schedule_fail_rc=0; else schedule_fail_rc=$?; fi
check "rollback scheduling failure refuses before mutation" test "$schedule_fail_rc" -ne 0
check "pre-mutation scheduling failure leaves a terminal aborted receipt" \
  python3 -c 'import json,pathlib,sys; states=[json.load(open(p))["status"] for p in pathlib.Path(sys.argv[1]).glob("*/transaction.json")]; assert states==["aborted_before_mutation"]' "$TMP/state/transactions"

if "$SCRIPT" apply --config "$CONFIG" >"$TMP/apply.out" 2>&1; then apply_rc=0; else apply_rc=$?; fi
if [[ "$apply_rc" -ne 0 ]]; then cat "$TMP/apply.out"; fi
check "hermetic apply passes the post-apply verifier" test "$apply_rc" -eq 0
TXID="$(sed -n 's/^transaction=//p' "$TMP/apply.out")"
check "apply returns an opaque transaction identifier" test -n "$TXID"
check "timed rollback is armed before SSH reload and firewall mutation" \
  bash -c 'schedule=$(grep -n "^systemd-run --unit=.*--on-active=120s" "$1" | head -1 | cut -d: -f1); reload=$(grep -n "^systemctl reload ssh.service" "$1" | head -1 | cut -d: -f1); reset=$(grep -n "^ufw --force reset" "$1" | head -1 | cut -d: -f1); [[ -n "$schedule" && "$schedule" -lt "$reload" && "$schedule" -lt "$reset" ]]' _ "$CALLS"
check "candidate sshd include sorts before vendor and cloud policy" \
  grep -Fq 'AuthenticationMethods publickey' "$TMP/etc/ssh/sshd_config.d/00-brokkr-m5-network.conf"
check "pre-INPUT tailnet policy and persistence unit were installed" \
  bash -c 'grep -Fq "hook prerouting priority filter" "$1" && grep -Fq "Before=tailscaled.service" "$2"' _ "$TMP/etc/nftables.d/brokkr-m5-tailnet.nft" "$TMP/etc/systemd/system/brokkr-m5-tailnet-filter.service"
check "Samba hardening include is last in global scope after weak legacy values" \
  bash -c 'weak=$(grep -n "map to guest = Bad User" "$1" | cut -d: -f1); include=$(grep -n "^include = .*brokkr-network.conf$" "$1" | cut -d: -f1); share=$(grep -n "^\[TimeMachine\]" "$1" | cut -d: -f1); [[ "$weak" -lt "$include" && "$include" -lt "$share" ]]' _ "$TMP/etc/samba/smb.conf"
check "default rollout disables nmbd" grep -qx 'nmbd=inactive-disabled' "$SERVICE_STATE"
check "tailnet prerouting filter is active and enabled" grep -qx 'active-enabled' "$FILTER_SERVICE_STATE"
if MOCK_NFT_FILTER_MISSING=1 "$SCRIPT" verify --config "$CONFIG" >"$TMP/early-accept-bypass.out" 2>&1; then early_accept_rc=0; else early_accept_rc=$?; fi
check "verifier rejects early ts-input acceptance without the owned prerouting gate" test "$early_accept_rc" -ne 0
if MOCK_NFT_EXTRA_RULE=1 "$SCRIPT" verify --config "$CONFIG" >"$TMP/uncommented-nft-accept.out" 2>&1; then extra_nft_rc=0; else extra_nft_rc=$?; fi
check "verifier rejects an extra un-commented accept in the owned tailnet chain" test "$extra_nft_rc" -ne 0

if "$SCRIPT" confirm --transaction "$TXID" >"$TMP/confirm-refuse.out" 2>&1; then confirm_refuse=0; else confirm_refuse=$?; fi
check "confirmation refuses without every external probe attestation" test "$confirm_refuse" -ne 0
if "$SCRIPT" confirm --transaction "$TXID" --authorized-probes-pass --disallowed-probes-rejected --timemachine-pass >"$TMP/same-session.out" 2>&1; then same_session_rc=0; else same_session_rc=$?; fi
check "the applying SSH session cannot self-confirm" test "$same_session_rc" -ne 0
export BROKKR_NETWORK_TEST_SSH_CLIENT='198.51.100.21'
if "$SCRIPT" confirm --transaction "$TXID" --authorized-probes-pass --disallowed-probes-rejected --timemachine-pass >"$TMP/confirm.out" 2>&1; then confirm_rc=0; else confirm_rc=$?; fi
check "distinct-session fully-attested confirmation disarms rollback" test "$confirm_rc" -eq 0
check "confirmation receipt records all three probe classes" \
  python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x["status"]=="confirmed"; assert set(x["external_probes"].values())=={"pass","rejected"}' "$TMP/state/transactions/$TXID/transaction.json"
if MOCK_WEAK_SHARE=1 "$SCRIPT" verify --config "$CONFIG" >"$TMP/weak-share.out" 2>&1; then weak_share_rc=0; else weak_share_rc=$?; fi
check "post-apply verifier rejects a share-level guest/public override" test "$weak_share_rc" -ne 0

# Exercise an explicit rollback from a second transaction and prove that a
# pending watchdog transaction fences concurrent applies.
printf '# rollback-sentinel\n' >"$TMP/etc/ssh/sshd_config.d/00-brokkr-m5-network.conf"
rm -f "$TMP/etc/samba/brokkr-network.conf"
printf '[global]\n   workgroup = ROLLBACK\n   map to guest = Bad User\n\n[TimeMachine]\n   path = /srv/example\n' >"$TMP/etc/samba/smb.conf"
printf 'inactive\n' >"$UFW_STATE"
printf 'nmbd=active-enabled\n' >"$SERVICE_STATE"
export BROKKR_NETWORK_TEST_SSH_CLIENT='198.51.100.22'
if "$SCRIPT" apply --config "$CONFIG" >"$TMP/apply-two.out" 2>&1; then apply_two_rc=0; else apply_two_rc=$?; fi
TXID_TWO="$(sed -n 's/^transaction=//p' "$TMP/apply-two.out")"
check "second hermetic transaction arms successfully" test "$apply_two_rc" -eq 0
if "$SCRIPT" apply --config "$CONFIG" >"$TMP/concurrent.out" 2>&1; then concurrent_rc=0; else concurrent_rc=$?; fi
check "an armed transaction fences a concurrent apply" test "$concurrent_rc" -ne 0
if "$SCRIPT" rollback --transaction "$TXID_TWO" >"$TMP/rollback.out" 2>&1; then rollback_rc=0; else rollback_rc=$?; fi
check "explicit rollback succeeds" test "$rollback_rc" -eq 0
check "rollback restores the prior SSH file exactly" grep -qx '# rollback-sentinel' "$TMP/etc/ssh/sshd_config.d/00-brokkr-m5-network.conf"
check "rollback removes a Samba include file that was previously absent" test ! -e "$TMP/etc/samba/brokkr-network.conf"
check "rollback restores the prior inactive UFW state" grep -qx inactive "$UFW_STATE"
check "rollback restores prior nmbd enable/active state" grep -qx 'nmbd=active-enabled' "$SERVICE_STATE"
check "rollback restores prior tailnet table and persistence-unit state" \
  bash -c 'grep -qx present "$1" && grep -qx active-enabled "$2"' _ "$NFT_TABLE_STATE" "$FILTER_SERVICE_STATE"
check "rollback emits a durable receipt" \
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"]=="rolled_back"' "$TMP/state/transactions/$TXID_TWO/transaction.json"

export BROKKR_NETWORK_TEST_SSH_CLIENT='198.51.100.23'
if "$SCRIPT" apply --config "$CONFIG" >"$TMP/apply-three.out" 2>&1; then apply_three_rc=0; else apply_three_rc=$?; fi
TXID_THREE="$(sed -n 's/^transaction=//p' "$TMP/apply-three.out")"
check "third hermetic transaction arms for rollback-failure coverage" test "$apply_three_rc" -eq 0
if MOCK_FAIL_UFW_DISABLE=1 "$SCRIPT" rollback --transaction "$TXID_THREE" >"$TMP/rollback-failed.out" 2>&1; then rollback_failed_rc=0; else rollback_failed_rc=$?; fi
check "incomplete rollback never reports success" test "$rollback_failed_rc" -ne 0
check "incomplete rollback preserves a failure receipt instead of false rolled-back state" \
  python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x["status"]=="rollback_failed" and x["rollback_failures"]' "$TMP/state/transactions/$TXID_THREE/transaction.json"

# An extra active allow must make the verifier fail closed instead of accepting
# token fragments spread over unrelated rules.
if MOCK_EXTRA_UFW_RULE=1 "$SCRIPT" verify --config "$CONFIG" >"$TMP/extra-rule.out" 2>&1; then extra_rule_rc=0; else extra_rule_rc=$?; fi
check "post-apply verifier rejects an unexpected inbound allowance" test "$extra_rule_rc" -ne 0
if MOCK_EXTRA_UFW_NONALLOW=1 "$SCRIPT" verify --config "$CONFIG" >"$TMP/extra-route-rule.out" 2>&1; then extra_route_rc=0; else extra_route_rc=$?; fi
check "post-apply verifier rejects an unexpected non-allow UFW command" test "$extra_route_rc" -ne 0

printf '\n==== %d passed, %d failed ====\n' "$pass" "$fail"
test "$fail" -eq 0
