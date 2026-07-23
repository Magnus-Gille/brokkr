#!/usr/bin/env bash
# Hermetic acceptance tests for location/network/storage profile preflight.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/mount"

cat > "$TMP/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'DEVICE,TYPE,STATE'*) printf '%s\n' "${MOCK_CONNECTIONS:-eth0:ethernet:connected}" ;;
  *'IN-USE,SSID,SIGNAL,RATE'*) printf '%s\n' "${MOCK_WIFI:-*:example-house-1:80:100 Mbit/s}" ;;
  *'NAME,TYPE,AUTOCONNECT'*) printf '%s\n' "${MOCK_PROFILES:-house wifi:802-11-wireless:yes}" ;;
  *'802-11-wireless.ssid'*) printf '802-11-wireless.ssid:%s\n' "${MOCK_PROFILE_SSID:-example-house-1}" ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
[ "${MOCK_MOUNT:-present}" = present ] || exit 1
target="${@: -1}"
printf '{"filesystems":[{"target":"%s","fstype":"%s","options":"%s"}]}\n' \
  "${MOCK_MOUNT_TARGET:-$target}" "${MOCK_FILESYSTEM:-ext4}" "${MOCK_MOUNT_OPTIONS:-rw,relatime}"
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
if [ -n "${MOCK_TAILSCALE_SLEEP:-}" ]; then sleep "$MOCK_TAILSCALE_SLEEP"; fi
if [ -n "${MOCK_TAILSCALE_JSON:-}" ]; then
  printf '%s\n' "$MOCK_TAILSCALE_JSON"
else
  printf '%s\n' '{"BackendState":"Running","Self":{"DNSName":"nas.example.ts.net.","Online":true}}'
fi
EOF
chmod +x "$TMP/bin"/*

PROFILE="$TMP/profile.json"
OVERLAY="$TMP/overlay.json"
cat > "$PROFILE" <<'EOF'
{
  "schema_version": 1,
  "locations": {
    "house-1": {
      "tailnet": {"required": true},
      "network": {
        "wifi": {"required": true, "min_signal_percent": 70, "min_throughput_mbps": 1},
        "ethernet": {"min_throughput_mbps": 10}
      },
      "storage": {"backup-primary": {"filesystem": "ext4", "max_used_percent": 85, "requires_write": true}},
      "backup_roles": [{"logical_storage_id": "backup-primary", "producer": "photo-export", "consumer": "encrypted-offsite", "bytes": 7500000000, "window_minutes": 30}]
    },
    "house-2": {
      "tailnet": {"required": true},
      "network": {
        "wifi": {"required": true, "min_signal_percent": 70, "min_throughput_mbps": 1},
        "ethernet": {"min_throughput_mbps": 10}
      },
      "storage": {"backup-primary": {"filesystem": "ext4", "max_used_percent": 85, "requires_write": true}},
      "backup_roles": [{"logical_storage_id": "backup-primary", "producer": "photo-export", "consumer": "encrypted-offsite", "bytes": 7500000000, "window_minutes": 30}]
    }
  }
}
EOF
cat > "$OVERLAY" <<EOF
{"schema_version": 1, "location": "house-1", "tailnet_identity": "nas.example.ts.net", "wifi": {"ssid": "example-house-1", "credentials_file": "$TMP/wifi.secret"}, "storage": {"backup-primary": {"mount": "$TMP/mount"}}}
EOF
printf 'credential-placeholder\n' > "$TMP/wifi.secret"
chmod 600 "$TMP/wifi.secret" "$OVERLAY"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# preflight <profile> <overlay> [VAR=value ...] — every run also proves no traceback leaks.
preflight() {
  local profile="$1" overlay="$2"
  shift 2
  # shellcheck disable=SC2034 # OUT/RC are consumed by the assertion expressions.
  OUT="$(PATH="$TMP/bin:$PATH" env "$@" python3 "$ROOT/profiles/preflight.py" \
        ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --profile "$profile" --overlay "$overlay" 2>&1)"
  # shellcheck disable=SC2034 # RC is consumed by the assertion expressions.
  RC=$?
  [[ "$OUT" != *Traceback* ]] || bad "no traceback is ever printed"
}
EXTRA_ARGS=()

echo "location-profile-preflight.test.sh"
preflight "$PROFILE" "$OVERLAY"
check "house-1 profile passes without printing overlay SSID or credential path" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile house-1 preflight passed" ]] && [[ "$OUT" != *example-house-1* && "$OUT" != *wifi.secret* ]]'
check "preflight leaves the mounted storage untouched" '[ -z "$(ls -A "$TMP/mount")" ]'

sed 's/"location": "house-1"/"location": "house-2"/; s/example-house-1/example-house-2/' "$OVERLAY" > "$TMP/house-2.json"
chmod 600 "$TMP/house-2.json"
preflight "$PROFILE" "$TMP/house-2.json" MOCK_PROFILE_SSID='example-house-2'
check "house-2 is represented by the same public profile contract" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile house-2 preflight passed" ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_CONNECTIONS=$'eth0:ethernet:disconnected\nwlan0:wifi:connected'
check "Ethernet to Wi-Fi failover passes with adequate evidence" '[[ "$RC" -eq 0 && "$OUT" == *passed* ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_CONNECTIONS='wlan0:wifi:connected' MOCK_WIFI='*:example-other:80:100 Mbit/s'
check "different SSID fails closed without revealing it" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi association does not match owner overlay"* && "$OUT" != *example-other* && "$OUT" != *example-house-1* ]]'

cat > "$TMP/escaped.json" <<EOF
{"schema_version": 1, "location": "house-1", "tailnet_identity": "nas.example.ts.net", "wifi": {"ssid": "example:house\\\\1", "credentials_file": "$TMP/wifi.secret"}, "storage": {"backup-primary": {"mount": "$TMP/mount"}}}
EOF
chmod 600 "$TMP/escaped.json"
preflight "$PROFILE" "$TMP/escaped.json" MOCK_CONNECTIONS='wlan0:wifi:connected' \
  MOCK_WIFI='*:example\:house\\1:80:100 Mbit/s' MOCK_PROFILE_SSID='example\:house\\1'
check "reserved SSID containing colon and backslash is parsed from escaped nmcli fields" '[[ "$RC" -eq 0 && "$OUT" == *passed* ]]'
preflight "$PROFILE" "$TMP/escaped.json" MOCK_CONNECTIONS='wlan0:wifi:connected' \
  MOCK_WIFI='*:example:house\\1:80:100 Mbit/s' MOCK_PROFILE_SSID='example\:house\\1'
check "unescaped colon in the association SSID is not mistaken for a match" '[[ "$RC" -eq 2 ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_PROFILE_SSID='example-other'
check "missing expected Wi-Fi profile fails closed even while Ethernet is active" '[[ "$RC" -eq 2 && "$OUT" == *"expected Wi-Fi profile is not configured"* && "$OUT" != *example-house-1* ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_PROFILES='house wifi:802-11-wireless:no'
check "disabled Wi-Fi autoconnect fails closed even while Ethernet is active" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi profile autoconnect is disabled"* ]]'

rm "$TMP/wifi.secret"
preflight "$PROFILE" "$OVERLAY"
check "missing Wi-Fi credentials fail closed without path output" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi credentials are unavailable"* && "$OUT" != *wifi.secret* ]]'
printf 'credential-placeholder\n' > "$TMP/wifi.secret"; chmod 600 "$TMP/wifi.secret"

preflight "$PROFILE" "$OVERLAY" MOCK_CONNECTIONS='wlan0:wifi:connected' MOCK_WIFI='*:example-house-1:20:100 Mbit/s'
check "inadequate Wi-Fi signal fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi signal is below profile minimum"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_CONNECTIONS='wlan0:wifi:connected' MOCK_WIFI='*:example-house-1:80:0 Mbit/s'
check "inadequate Wi-Fi throughput fails closed against the Wi-Fi threshold" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi throughput is below profile minimum"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_ETHERNET_MBPS=5
check "inadequate Ethernet throughput fails closed against the Ethernet threshold" '[[ "$RC" -eq 2 && "$OUT" == *"Ethernet throughput is below profile minimum"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_CONNECTIONS='wlan0:wifi:connected' MOCK_WIFI='*:example-house-1:80:1 Mbit/s'
check "insufficient transfer window fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"backup transfer window is insufficient"* ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_MOUNT=absent
check "absent mount fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary is not mounted"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_USED=95
check "capacity breach fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary exceeds capacity threshold"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_MOUNT_OPTIONS='ro,relatime'
check "read-only mount options fail closed without a write probe" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary is mounted read-only"* ]]'

preflight "$PROFILE" "$OVERLAY" MOCK_MOUNT_TARGET="$TMP"
check "a parent filesystem selected through a storage subdirectory is rejected" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary mount target does not match profile"* && "$OUT" != *"$TMP"* ]]'

ln -s "$TMP/mount" "$TMP/mount-alias"
sed "s#$TMP/mount#$TMP/mount-alias#" "$OVERLAY" > "$TMP/symlink-overlay.json"
chmod 600 "$TMP/symlink-overlay.json"
preflight "$PROFILE" "$TMP/symlink-overlay.json"
check "a symlinked storage path is rejected without exposing either path" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary mount path is not canonical"* && "$OUT" != *mount-alias* && "$OUT" != *"$TMP"* ]]'

if [ "$(id -u)" -ne 0 ]; then
  mkdir "$TMP/readonly"
  sed "s#$TMP/mount#$TMP/readonly#" "$OVERLAY" > "$TMP/readonly-overlay.json"
  chmod 600 "$TMP/readonly-overlay.json"
  chmod 500 "$TMP/readonly"
  preflight "$PROFILE" "$TMP/readonly-overlay.json"
  check "unwritable logical storage fails closed on permission evidence" '[[ "$RC" -eq 2 && "$OUT" == *"logical storage backup-primary is not writable"* ]]'
  chmod 700 "$TMP/readonly"
fi

preflight "$PROFILE" "$OVERLAY" MOCK_TAILSCALE_JSON='{"BackendState":"Stopped","Self":{"DNSName":"nas.example.ts.net.","Online":false}}'
check "stopped tailnet fails closed even with a matching DNS name" '[[ "$RC" -eq 2 && "$OUT" == *"tailnet is not running and online"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_TAILSCALE_JSON='{"BackendState":"Running","Self":{"DNSName":"nas.example.ts.net.","Online":false}}'
check "offline tailnet self node fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"tailnet is not running and online"* ]]'
preflight "$PROFILE" "$OVERLAY" MOCK_TAILSCALE_JSON='not json at all'
check "malformed tailnet evidence fails closed without traceback" '[[ "$RC" -eq 2 && "$OUT" == *"tailnet evidence is invalid"* ]]'

EXTRA_ARGS=(--command-timeout 1)
preflight "$PROFILE" "$OVERLAY" MOCK_TAILSCALE_SLEEP=3
check "hung external command times out and fails closed" '[[ "$RC" -eq 2 && "$OUT" == *"tailnet evidence is unavailable"* ]]'
EXTRA_ARGS=()

python3 - "$PROFILE" "$TMP/unknown-profile.json" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1]))
value["locations"]["house-1"]["surprise_locator"] = "10.0.0.99"
json.dump(value, open(sys.argv[2], "w"))
EOF
preflight "$TMP/unknown-profile.json" "$OVERLAY"
check "unknown public profile field is rejected without echoing it" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported field"* && "$OUT" != *surprise_locator* && "$OUT" != *10.0.0.99* ]]'

python3 - "$PROFILE" "$TMP/mistyped-profile.json" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1]))
value["locations"]["house-1"]["network"]["wifi"]["min_signal_percent"] = "seventy"
json.dump(value, open(sys.argv[2], "w"))
EOF
preflight "$TMP/mistyped-profile.json" "$OVERLAY"
check "mistyped public profile field is rejected without echoing its value" '[[ "$RC" -eq 2 && "$OUT" == *"min_signal_percent must be an integer"* && "$OUT" != *seventy* ]]'

python3 - "$PROFILE" "$TMP/range-profile.json" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1]))
value["locations"]["house-1"]["network"]["wifi"]["min_signal_percent"] = 150
json.dump(value, open(sys.argv[2], "w"))
EOF
preflight "$TMP/range-profile.json" "$OVERLAY"
check "out-of-range public profile field is rejected" '[[ "$RC" -eq 2 && "$OUT" == *"min_signal_percent is out of range"* ]]'

printf '{"schema_version": 1, "location": "house-1"' > "$TMP/truncated.json"
chmod 600 "$TMP/truncated.json"
preflight "$PROFILE" "$TMP/truncated.json"
check "malformed owner overlay JSON is rejected without traceback" '[[ "$RC" -eq 2 && "$OUT" == *"owner overlay is invalid"* ]]'

sed 's/"wifi":/"stray_secret": "hunter2-value", "wifi":/' "$OVERLAY" > "$TMP/unknown-overlay.json"
chmod 600 "$TMP/unknown-overlay.json"
preflight "$PROFILE" "$TMP/unknown-overlay.json"
check "unknown owner overlay field is rejected without echoing key or value" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported field"* && "$OUT" != *stray_secret* && "$OUT" != *hunter2-value* ]]'

check "tracked public and owner-overlay Draft 2020-12 schema artifacts exist" '[[ -f "$ROOT/profiles/location-network-storage.schema.json" && -f "$ROOT/profiles/location-network-storage.overlay.schema.json" ]]'

python3 - "$ROOT/profiles/location-network-storage.schema.json" "$TMP/strict-profile.schema.json" <<'EOF'
import json, sys
schema = json.load(open(sys.argv[1]))
location = schema["properties"]["locations"]["additionalProperties"]
storage = location["properties"]["storage"]["additionalProperties"]
storage["properties"]["max_used_percent"]["maximum"] = 50
json.dump(schema, open(sys.argv[2], "w"))
EOF
EXTRA_ARGS=(--profile-schema "$TMP/strict-profile.schema.json")
preflight "$PROFILE" "$OVERLAY"
check "runtime consumes a tracked schema constraint instead of a duplicate Python checker" '[[ "$RC" -eq 2 && "$OUT" == *"max_used_percent is out of range"* ]]'

python3 - "$ROOT/profiles/location-network-storage.schema.json" "$TMP/unsupported-profile.schema.json" <<'EOF'
import json, sys
schema = json.load(open(sys.argv[1]))
schema["$ref"] = "https://example.invalid/not-supported"
json.dump(schema, open(sys.argv[2], "w"))
EOF
EXTRA_ARGS=(--profile-schema "$TMP/unsupported-profile.schema.json")
preflight "$PROFILE" "$OVERLAY"
check "unsupported Draft 2020-12 keywords fail closed instead of silently drifting" '[[ "$RC" -eq 2 && "$OUT" == *"public profile schema uses an unsupported schema keyword"* ]]'
EXTRA_ARGS=()

python3 - "$PROFILE" "$TMP/wired-profile.json" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1]))
value["locations"] = {
    "wired": {
        "tailnet": {"required": False},
        "network": {
            "wifi": {"required": False, "min_signal_percent": 70, "min_throughput_mbps": 1},
            "ethernet": {"min_throughput_mbps": 10},
        },
        "storage": value["locations"]["house-1"]["storage"],
        "backup_roles": [],
    }
}
json.dump(value, open(sys.argv[2], "w"))
EOF
cat > "$TMP/wired-overlay.json" <<EOF
{"schema_version": 1, "location": "wired", "storage": {"backup-primary": {"mount": "$TMP/mount"}}}
EOF
chmod 600 "$TMP/wired-overlay.json"
preflight "$TMP/wired-profile.json" "$TMP/wired-overlay.json"
check "minimal wired no-tailnet overlay needs no Wi-Fi credential or identity placeholders" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile wired preflight passed" ]]'

cat > "$TMP/wired-optional-overlay.json" <<EOF
{"schema_version": 1, "location": "wired", "tailnet_identity": "nas.example.ts.net", "wifi": {"ssid": "example-house-1", "credentials_file": "$TMP/wifi.secret"}, "storage": {"backup-primary": {"mount": "$TMP/mount"}}}
EOF
chmod 600 "$TMP/wired-optional-overlay.json"
preflight "$TMP/wired-profile.json" "$TMP/wired-optional-overlay.json"
check "optional tailnet and Wi-Fi overlay evidence validates when supplied" '[[ "$RC" -eq 0 && "$OUT" == "OK: location profile wired preflight passed" ]]'

python3 - "$OVERLAY" "$TMP/no-tailnet-overlay.json" "$TMP/no-wifi-overlay.json" <<'EOF'
import json, sys
value = json.load(open(sys.argv[1]))
without_tailnet = dict(value)
del without_tailnet["tailnet_identity"]
json.dump(without_tailnet, open(sys.argv[2], "w"))
without_wifi = dict(value)
del without_wifi["wifi"]
json.dump(without_wifi, open(sys.argv[3], "w"))
EOF
chmod 600 "$TMP/no-tailnet-overlay.json" "$TMP/no-wifi-overlay.json"
preflight "$PROFILE" "$TMP/no-tailnet-overlay.json"
check "tailnet identity is required when the selected public location requires it" '[[ "$RC" -eq 2 && "$OUT" == *"owner overlay tailnet identity is required by location"* ]]'
preflight "$PROFILE" "$TMP/no-wifi-overlay.json"
check "Wi-Fi evidence is required when the selected public location requires it" '[[ "$RC" -eq 2 && "$OUT" == *"owner overlay Wi-Fi evidence is required by location"* ]]'

cp "$ROOT/profiles/location-network-storage.example.json" "$TMP/shipped-profile.json"
cp "$ROOT/profiles/location-network-storage.overlay.example.json" "$TMP/shipped-overlay.json"
chmod 600 "$TMP/shipped-overlay.json"
preflight "$TMP/shipped-profile.json" "$TMP/shipped-overlay.json"
check "shipped example profile and overlay satisfy the closed schema" '[[ "$RC" -eq 2 && "$OUT" == *"Wi-Fi credentials are unavailable"* ]]'

sed 's/"schema_version": 1/"schema_version": 2/' "$OVERLAY" > "$TMP/future.json"
chmod 600 "$TMP/future.json"
preflight "$PROFILE" "$TMP/future.json"
check "unsupported overlay schema version is rejected" '[[ "$RC" -eq 2 && "$OUT" == *"unsupported schema version"* ]]'

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
