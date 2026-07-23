#!/usr/bin/env bash
# Hermetic acceptance tests for location/network/storage profile preflight.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/mount"

cat > "$TMP/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'DEVICE,TYPE,STATE'*) printf '%s\n' "${MOCK_CONNECTIONS:-eth0:ethernet:connected}" ;;
  *'IN-USE,SSID,SIGNAL,RATE'*) printf '%s\n' "${MOCK_WIFI:-*:example-house-1:80:100 Mbit/s}" ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
[ "${MOCK_MOUNT:-present}" = present ] || exit 1
printf '%s\n' "${MOCK_FILESYSTEM:-ext4}"
EOF
cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock 1000 %s 200 %s%% /mock\n' "${MOCK_USED:-40}" "${MOCK_USED:-40}"
EOF
cat > "$TMP/bin/ethtool" <<'EOF'
#!/usr/bin/env bash
printf 'Speed: %sMb/s\n' "${MOCK_ETHERNET_MBPS:-100}"
EOF
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"Self":{"DNSName":"nas.example.ts.net."}}'
EOF
chmod +x "$TMP/bin"/*

PROFILE="$TMP/profile.json"
OVERLAY="$TMP/overlay.json"
cat > "$PROFILE" <<'EOF'
{
  "schema_version": 1,
  "locations": {
    "house-1": {
      "tailnet_identity": "nas.example.ts.net",
      "network": {"wifi": {"required": true, "min_signal_percent": 70, "min_throughput_mbps": 1}},
      "storage": {"backup-primary": {"filesystem": "ext4", "max_used_percent": 85, "requires_write": true}},
      "backup_roles": [{"logical_storage_id": "backup-primary", "producer": "photo-export", "consumer": "encrypted-offsite", "bytes": 7500000000, "window_minutes": 30}]
    },
    "house-2": {
      "tailnet_identity": "nas.example.ts.net",
      "network": {"wifi": {"required": true, "min_signal_percent": 70, "min_throughput_mbps": 1}},
      "storage": {"backup-primary": {"filesystem": "ext4", "max_used_percent": 85, "requires_write": true}},
      "backup_roles": [{"logical_storage_id": "backup-primary", "producer": "photo-export", "consumer": "encrypted-offsite", "bytes": 7500000000, "window_minutes": 30}]
    }
  }
}
EOF
cat > "$OVERLAY" <<EOF
{"schema_version": 1, "location": "house-1", "wifi": {"ssid": "example-house-1", "credentials_file": "$TMP/wifi.secret"}, "storage": {"backup-primary": {"mount": "$TMP/mount"}}}
EOF
printf 'credential-placeholder\n' > "$TMP/wifi.secret"
chmod 600 "$TMP/wifi.secret" "$OVERLAY"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() { OUT="$(PATH="$TMP/bin:$PATH" python3 "$ROOT/profiles/preflight.py" --profile "$PROFILE" --overlay "$OVERLAY" 2>&1)"; RC=$?; }

echo "location-profile-preflight.test.sh"
run
check "house-1 profile passes without printing overlay SSID or credential path" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile house-1 preflight passed" ]] && [[ "$OUT" != *example-house-1* && "$OUT" != *wifi.secret* ]]'

sed 's/"location": "house-1"/"location": "house-2"/; s/example-house-1/example-house-2/' "$OVERLAY" > "$TMP/house-2.json"
chmod 600 "$TMP/house-2.json"
# shellcheck disable=SC2034 # Values are consumed by the assertion expression below.
OUT="$(PATH="$TMP/bin:$PATH" MOCK_CONNECTIONS='eth0:ethernet:connected' python3 "$ROOT/profiles/preflight.py" --profile "$PROFILE" --overlay "$TMP/house-2.json" 2>&1)"
# shellcheck disable=SC2034 # Values are consumed by the assertion expression below.
RC=$?
check "house-2 is represented by the same public profile contract" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile house-2 preflight passed" ]]'

export MOCK_CONNECTIONS=$'eth0:ethernet:disconnected\nwlan0:wifi:connected'
run
check "Ethernet to Wi-Fi failover passes with adequate evidence" '[[ "$RC" -eq 0 && "$OUT" == *passed* ]]'

export MOCK_CONNECTIONS='wlan0:wifi:connected' MOCK_WIFI='*:example-other:80:100 Mbit/s'
run
check "different SSID fails closed without revealing it" '[[ "$RC" -ne 0 && "$OUT" == *"Wi-Fi association does not match owner overlay"* && "$OUT" != *example-other* && "$OUT" != *example-house-1* ]]'

rm "$TMP/wifi.secret"
run
check "missing Wi-Fi credentials fail closed without path output" '[[ "$RC" -ne 0 && "$OUT" == *"Wi-Fi credentials are unavailable"* && "$OUT" != *wifi.secret* ]]'
printf 'credential-placeholder\n' > "$TMP/wifi.secret"; chmod 600 "$TMP/wifi.secret"

export MOCK_WIFI='*:example-house-1:20:100 Mbit/s'
run
check "inadequate Wi-Fi signal fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"Wi-Fi signal is below profile minimum"* ]]'
export MOCK_WIFI='*:example-house-1:80:1 Mbit/s'
run
check "insufficient transfer window fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"backup transfer window is insufficient"* ]]'
export MOCK_MOUNT=absent
run
check "absent mount fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"logical storage backup-primary is not mounted"* ]]'
export MOCK_MOUNT=present MOCK_USED=95
run
check "capacity breach fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"logical storage backup-primary exceeds capacity threshold"* ]]'

mkdir "$TMP/readonly"
sed "s#$TMP/mount#$TMP/readonly#" "$OVERLAY" > "$TMP/readonly-overlay.json"
chmod 600 "$TMP/readonly-overlay.json"
chmod 500 "$TMP/readonly"
export MOCK_USED=40 MOCK_WIFI='*:example-house-1:80:100 Mbit/s'
# shellcheck disable=SC2034 # Values are consumed by the assertion expression below.
OUT="$(PATH="$TMP/bin:$PATH" python3 "$ROOT/profiles/preflight.py" --profile "$PROFILE" --overlay "$TMP/readonly-overlay.json" 2>&1)"
# shellcheck disable=SC2034 # Values are consumed by the assertion expression below.
RC=$?
check "read-only logical storage fails closed" '[[ "$RC" -ne 0 && "$OUT" == *"logical storage backup-primary is not writable"* ]]'
chmod 700 "$TMP/readonly"

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
