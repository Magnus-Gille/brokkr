#!/usr/bin/env bash
# Hermetic CLI/preflight coverage for the Brokkr #51 provisioner.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
CALLS="$TMP/calls"

git clone -q "$SOURCE_REPO" "$FIXTURE"
for file in \
  scripts/provision-heimdall-storage-probe.sh \
  scripts/heimdall-storage-probe.sh \
  scripts/heimdall-storage-probe.sshd.conf \
  scripts/lib/heimdall-storage-probe-reconcile.sh \
  scripts/lib/deploy-source.sh; do
  mkdir -p "$FIXTURE/$(dirname "$file")"
  cp "$SOURCE_REPO/$file" "$FIXTURE/$file"
done
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" config user.email test@example.invalid
git -C "$FIXTURE" add scripts
git -C "$FIXTURE" commit -qm 'fixture Brokkr storage probe'

mkdir -p "$TMP/bin" "$TMP/private"
: >"$CALLS"
cat >"$TMP/bin/scp" <<'EOF'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >>"$MOCK_CALLS"
EOF
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$MOCK_CALLS"
if [[ "$*" == *"sudo env"* ]]; then
  cat >/dev/null
  printf 'key_fingerprint=SHA256:fixture probe_sha256=%s config_sha256=%s sshd_config_sha256=%s\n' \
    "$MOCK_PROBE_SHA256" "$MOCK_CONFIG_SHA256" "$MOCK_SSHD_CONFIG_SHA256"
  exit 0
fi
if [[ "$*" == *"heimdall-storage-probe@"* ]]; then
  printf 'first\n'
  for _ in {1..18}; do printf '%s\n' '---'; done
  exit 0
fi
exit 0
EOF
cat >"$TMP/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf '256 SHA256:fixture fixture (ED25519)\n'
EOF
chmod +x "$TMP/bin/"*

printf 'host-key-fixture\n' >"$TMP/private/known_hosts"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyPublicKey\n' >"$TMP/private/probe.pub"
printf 'fixture-private-key\n' >"$TMP/private/probe"
printf '%s\n' \
  'TM_SNAPSHOT_PATH=/x' \
  'TM_ROOT=/x' \
  'MUNIN_BACKUP_DIR=/x' \
  'MIMIR_LOG=/x' \
  'MIMIR_SYNC_STAMP=/x' \
  'MIMIR_SYNC_DIR=/x' >"$TMP/private/probe.conf"
chmod 600 "$TMP/private/"*

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() {
  : >"$CALLS"
  local head
  head=$(git -C "$FIXTURE" rev-parse HEAD)
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  OUT="$(
    cd "$FIXTURE" &&
      PATH="$TMP/bin:$PATH" \
      MOCK_CALLS="$CALLS" \
      MOCK_PROBE_SHA256="$(shasum -a 256 scripts/heimdall-storage-probe.sh | awk '{print $1}')" \
      MOCK_CONFIG_SHA256="$(shasum -a 256 "$TMP/private/probe.conf" | awk '{print $1}')" \
      MOCK_SSHD_CONFIG_SHA256="$(shasum -a 256 scripts/heimdall-storage-probe.sshd.conf | awk '{print $1}')" \
      BROKKR_EXPECTED_SOURCE="$FIXTURE" \
      BROKKR_EXPECTED_COMMIT="$head" \
      BROKKR_HEIMDALL_STORAGE_KNOWN_HOSTS="$TMP/private/known_hosts" \
      BROKKR_HEIMDALL_STORAGE_PROBE_PUBLIC_KEY_FILE="$TMP/private/probe.pub" \
      BROKKR_HEIMDALL_STORAGE_SSH_KEY="$TMP/private/probe" \
      BROKKR_HEIMDALL_STORAGE_PROBE_CONFIG="$TMP/private/probe.conf" \
      bash scripts/provision-heimdall-storage-probe.sh "$@" 2>&1
  )"
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  RC=$?
}

echo provision-heimdall-storage-probe-cli.test.sh
run apply operator@nas.example.test
check 'apply emits only content-blind receipt metadata after source preflight' \
  '[[ $RC -eq 0 && "$OUT" == *"key_fingerprint=SHA256:fixture"* && "$OUT" == *"config_bound=true"* && "$OUT" == *"sections=19"* && "$OUT" != *"FixtureOnlyPublicKey"* && "$OUT" != *"config_sha256="* ]]'
check 'all SSH/SCP paths pin host identity' \
  '[[ $(grep -c "StrictHostKeyChecking=yes" "$CALLS") -ge 3 && $(grep -c "UserKnownHostsFile=$TMP/private/known_hosts" "$CALLS") -ge 3 ]]'
check 'readback disables fallback identities and password prompts' \
  'grep -q "IdentitiesOnly=yes.*PasswordAuthentication=no.*KbdInteractiveAuthentication=no.*heimdall-storage-probe@nas.example.test" "$CALLS"'

run apply -oProxyCommand
check 'option-like target fails before network use' \
  '[[ $RC -ne 0 && "$OUT" == *"unsupported characters"* && ! -s "$CALLS" ]]'

chmod 644 "$TMP/private/known_hosts"
run apply operator@nas.example.test
check 'unsafe known-hosts permissions fail before network use' \
  '[[ $RC -ne 0 && "$OUT" == *"protected non-symlink"* && ! -s "$CALLS" ]]'
chmod 600 "$TMP/private/known_hosts"

printf 'UNKNOWN_PATH=/x\n' >"$TMP/private/probe.conf"
run apply operator@nas.example.test
check 'invalid path config fails before staging' \
  '[[ $RC -ne 0 && "$OUT" == *"configuration is invalid"* && ! -s "$CALLS" ]]'

printf '%s\n' \
  'TM_SNAPSHOT_PATH=/x' \
  'TM_ROOT=/x/../private' \
  'MUNIN_BACKUP_DIR=/x' \
  'MIMIR_LOG=/x' \
  'MIMIR_SYNC_STAMP=/x' \
  'MIMIR_SYNC_DIR=/x' >"$TMP/private/probe.conf"
run apply operator@nas.example.test
check 'traversal-shaped config path fails before staging' \
  '[[ $RC -ne 0 && "$OUT" == *"configuration is invalid"* && ! -s "$CALLS" ]]'

if (( FAIL )); then exit 1; fi
printf '%s passed\n' "$PASS"
