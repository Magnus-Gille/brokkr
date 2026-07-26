#!/usr/bin/env bash
# Execute the root reconciler against a hermetic filesystem (brokkr#51).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RECONCILER="$REPO/scripts/lib/heimdall-storage-probe-reconcile.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/stage" "$TMP/etc/brokkr" "$TMP/etc/ssh/sshd_config.d" \
  "$TMP/usr/local/lib/brokkr" "$TMP/var/lib/brokkr"
: >"$TMP/calls"

cat >"$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-gn" ]]; then
  printf '%s\n' "${2:-}"
fi
exit 0
EOF
cat >"$TMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf 'probe:x:999:999::%s/var/lib/heimdall-storage-probe:/bin/sh\n' "$BROKKR_STORAGE_TEST_ROOT"
EOF
cat >"$TMP/bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$TEST_CALLS"
EOF
cat >"$TMP/bin/chpasswd" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'chpasswd %s\n' "$*" >>"$TEST_CALLS"
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TEST_CALLS"
if [[ "$*" == 'is-active --quiet ssh.service' || "$*" == 'reload ssh.service' ]]; then
  exit 0
fi
exit 1
EOF
cat >"$TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "rand -base64 48" ]]; then
  printf 'private-random-material\n'
elif [[ "$*" == "passwd -6 -stdin" ]]; then
  cat >/dev/null
  printf '$6$fixture$noninteractive-only\n'
else
  exit 64
fi
EOF
cat >"$TMP/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$TEST_CALLS"
if [[ "$*" == *"-T"* ]]; then
  if [[ "${TEST_SSHD_POLICY:-safe}" == unsafe ]]; then
    printf '%s\n' 'passwordauthentication yes'
    exit 0
  fi
  cat <<'POLICY'
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
permittty no
allowtcpforwarding no
allowagentforwarding no
gatewayports no
x11forwarding no
permittunnel no
permituserrc no
POLICY
  if [[ "${TEST_SSHD_POLICY:-safe}" == streamlocal ]]; then
    printf '%s\n' 'allowstreamlocalforwarding yes'
  else
    printf '%s\n' 'allowstreamlocalforwarding no'
  fi
  printf 'forcecommand %s\n' "$BROKKR_STORAGE_PROBE_PATH"
fi
EOF
cat >"$TMP/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >>"$TEST_CALLS"
EOF
cat >"$TMP/bin/install" <<'EOF'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >>"$TEST_CALLS"
mode=
directory=0
args=("$@")
index=0
while (( index < ${#args[@]} )); do
  case "${args[$index]}" in
    -d) directory=1; index=$((index + 1)) ;;
    -m) mode=${args[$((index + 1))]}; index=$((index + 2)) ;;
    -o|-g) index=$((index + 2)) ;;
    -*) index=$((index + 1)) ;;
    *) break ;;
  esac
done
if (( directory )); then
  while (( index < ${#args[@]} )); do
    mkdir -p "${args[$index]}"
    [[ -z "$mode" ]] || chmod "$mode" "${args[$index]}"
    index=$((index + 1))
  done
else
  source_path=${args[$((${#args[@]} - 2))]}
  destination=${args[$((${#args[@]} - 1))]}
  [[ "${TEST_FAIL_INSTALL_DEST:-}" != "$destination" ]] || exit 70
  cp "$source_path" "$destination"
  [[ -z "$mode" ]] || chmod "$mode" "$destination"
fi
EOF
chmod +x "$TMP/bin/"*

write_probe() {
  {
    echo '#!/usr/bin/env bash'
    echo '[[ "${1:-}" == "--validate-config" ]] && exit 0'
    for _ in {1..18}; do echo 'echo ---'; done
  } >"$TMP/stage/probe"
}
write_config() {
  printf '%s\n' \
    'TM_SNAPSHOT_PATH=/x' \
    'TM_ROOT=/x' \
    'MUNIN_BACKUP_DIR=/x' \
    'MIMIR_LOG=/x' \
    'MIMIR_SYNC_STAMP=/x' \
    'MIMIR_SYNC_DIR=/x' >"$TMP/stage/config"
}
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run() {
  local mode=$1
  local probe_sha=${EXPECTED_PROBE_OVERRIDE:-} config_sha=${EXPECTED_CONFIG_OVERRIDE:-} sshd_config_sha
  if [[ "$mode" == apply ]]; then
    cp "$REPO/scripts/heimdall-storage-probe.sshd.conf" "$TMP/stage/sshd"
  fi
  if [[ -z "$probe_sha" && -f "$TMP/stage/probe" ]]; then probe_sha=$(sha256 "$TMP/stage/probe"); fi
  if [[ -z "$config_sha" && -f "$TMP/stage/config" ]]; then config_sha=$(sha256 "$TMP/stage/config"); fi
  sshd_config_sha=$(sha256 "$TMP/stage/sshd")
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  OUT="$(
    PATH="$TMP/bin:$PATH" \
      TEST_CALLS="$TMP/calls" \
      BROKKR_STORAGE_TEST_ROOT="$TMP/root" \
      BROKKR_STORAGE_MODE="$mode" \
      BROKKR_STORAGE_USER=heimdall-storage-probe \
      BROKKR_STORAGE_PROBE_PATH="$TMP/usr/local/lib/brokkr/probe" \
      BROKKR_STORAGE_CONFIG_PATH="$TMP/etc/brokkr/probe.conf" \
      BROKKR_STORAGE_SSHD_CONFIG_PATH="$TMP/etc/ssh/sshd_config.d/probe.conf" \
      BROKKR_STORAGE_MARKER="$TMP/var/lib/brokkr/marker" \
      BROKKR_STORAGE_AUTH_OPTIONS='command="/usr/local/lib/brokkr/probe",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty' \
      BROKKR_STORAGE_STAGE_PROBE="$TMP/stage/probe" \
      BROKKR_STORAGE_STAGE_CONFIG="$TMP/stage/config" \
      BROKKR_STORAGE_STAGE_SSHD_CONFIG="$TMP/stage/sshd" \
      BROKKR_STORAGE_PUBKEY='ssh-ed25519 AAAAfixture' \
      BROKKR_STORAGE_FINGERPRINT='SHA256:fixture' \
      BROKKR_STORAGE_EXPECTED_PROBE_SHA256="$probe_sha" \
      BROKKR_STORAGE_EXPECTED_CONFIG_SHA256="$config_sha" \
      BROKKR_STORAGE_EXPECTED_SSHD_CONFIG_SHA256="$sshd_config_sha" \
      TEST_SSHD_POLICY="${TEST_SSHD_POLICY:-safe}" \
      bash "$RECONCILER" 2>&1
  )"
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  RC=$?
}
run_first_apply_with_install_failure() {
  local sandbox="$TMP/rollback"
  write_probe
  write_config
  cp "$REPO/scripts/heimdall-storage-probe.sshd.conf" "$TMP/stage/sshd"
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  OUT="$(
    PATH="$TMP/bin:$PATH" \
      TEST_CALLS="$TMP/calls" \
      TEST_FAIL_INSTALL_DEST="$sandbox/usr/local/lib/brokkr/probe" \
      BROKKR_STORAGE_TEST_ROOT="$sandbox/root" \
      BROKKR_STORAGE_MODE=apply \
      BROKKR_STORAGE_USER=heimdall-storage-probe \
      BROKKR_STORAGE_PROBE_PATH="$sandbox/usr/local/lib/brokkr/probe" \
      BROKKR_STORAGE_CONFIG_PATH="$sandbox/etc/brokkr/probe.conf" \
      BROKKR_STORAGE_SSHD_CONFIG_PATH="$sandbox/etc/ssh/sshd_config.d/probe.conf" \
      BROKKR_STORAGE_MARKER="$sandbox/var/lib/brokkr/marker" \
      BROKKR_STORAGE_AUTH_OPTIONS='command="/usr/local/lib/brokkr/probe",restrict,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty' \
      BROKKR_STORAGE_STAGE_PROBE="$TMP/stage/probe" \
      BROKKR_STORAGE_STAGE_CONFIG="$TMP/stage/config" \
      BROKKR_STORAGE_STAGE_SSHD_CONFIG="$TMP/stage/sshd" \
      BROKKR_STORAGE_PUBKEY='ssh-ed25519 AAAAfixture' \
      BROKKR_STORAGE_FINGERPRINT='SHA256:fixture' \
      BROKKR_STORAGE_EXPECTED_PROBE_SHA256="$(sha256 "$TMP/stage/probe")" \
      BROKKR_STORAGE_EXPECTED_CONFIG_SHA256="$(sha256 "$TMP/stage/config")" \
      BROKKR_STORAGE_EXPECTED_SSHD_CONFIG_SHA256="$(sha256 "$TMP/stage/sshd")" \
      bash "$RECONCILER" 2>&1
  )"
  # shellcheck disable=SC2034 # OUT and RC are consumed by the eval-based checks below.
  RC=$?
}

echo provision-heimdall-storage-probe.test.sh
write_probe
write_config
cp "$REPO/scripts/heimdall-storage-probe.sshd.conf" "$TMP/stage/sshd"

touch "$TMP/usr/local/lib/brokkr/probe"
run apply
check 'unmarked artifact refuses before overwrite' \
  '[[ $RC -ne 0 && "$OUT" == *"unmanaged or drifted"* ]]'
rm -f "$TMP/usr/local/lib/brokkr/probe"

EXPECTED_PROBE_OVERRIDE=$(printf '0%.0s' {1..64})
run apply
check 'staged digest mismatch refuses before mutation' \
  '[[ $RC -ne 0 && "$OUT" == *"digest mismatch"* && ! -e "$TMP/var/lib/brokkr/marker" ]]'
unset EXPECTED_PROBE_OVERRIDE

run apply
check 'apply writes content-bound metadata' \
  '[[ $RC -eq 0 && "$OUT" == *"probe_sha256="* && "$OUT" == *"config_sha256="* && "$OUT" == *"sshd_config_sha256="* ]]'
check 'apply installs every managed artifact' \
  '[[ -f "$TMP/usr/local/lib/brokkr/probe" && -f "$TMP/etc/brokkr/probe.conf" && -f "$TMP/etc/ssh/sshd_config.d/probe.conf" && -f "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys" && -f "$TMP/var/lib/brokkr/marker" ]]'
check 'config is group-readable only by the dedicated account' \
  'grep -q "install -m 0640 -o root -g heimdall-storage-probe" "$TMP/calls"'
check 'dedicated UID can traverse and read its root-owned authorization without mutation rights' \
  'grep -q "install -d -m 0750 -o root -g heimdall-storage-probe .*\.ssh" "$TMP/calls" && grep -q "chown root:heimdall-storage-probe .*authorized_keys.new" "$TMP/calls" && [[ $(mode "$TMP/root/var/lib/heimdall-storage-probe/.ssh") == 750 && $(mode "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys") == 640 ]]'
check 'authorization and marker retain root ownership' \
  'grep -q "chown root:heimdall-storage-probe .*authorized_keys.new" "$TMP/calls" && grep -q "chown root:root .*marker.new" "$TMP/calls"'
check 'apply makes the PAM account non-locked without exposing a password login' \
  'grep -q "chpasswd --encrypted" "$TMP/calls" && ! grep -q "usermod --lock" "$TMP/calls"'
check 'apply verifies an explicit SSH public-key-only policy for the dedicated account' \
  'grep -q "sshd -t" "$TMP/calls" && grep -q "sshd -T" "$TMP/calls" && grep -q "systemctl reload ssh.service" "$TMP/calls"'
check 'tracked policy independently denies Unix-domain forwarding' \
  'grep -qx "    AllowStreamLocalForwarding no" "$REPO/scripts/heimdall-storage-probe.sshd.conf"'

TEST_SSHD_POLICY=unsafe
cp "$TMP/usr/local/lib/brokkr/probe" "$TMP/stage/probe"
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"
run apply
check 'unsafe effective SSH policy refuses before authorization replacement' \
  '[[ $RC -ne 0 && "$OUT" == *"public-key forced-command only"* ]]'
unset TEST_SSHD_POLICY

TEST_SSHD_POLICY=streamlocal
: >"$TMP/calls"
cp "$TMP/usr/local/lib/brokkr/probe" "$TMP/stage/probe"
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"
run apply
check 'streamlocal-enabled effective SSH policy refuses before PAM admission' \
  '[[ $RC -ne 0 && "$OUT" == *"public-key forced-command only"* && $(cat "$TMP/calls") != *"chpasswd --encrypted"* ]]'
unset TEST_SSHD_POLICY

: >"$TMP/calls"
run_first_apply_with_install_failure
check 'first-apply post-policy failure leaves no unlocked account without a marker' \
  '[[ $RC -ne 0 && ! -e "$TMP/rollback/var/lib/brokkr/marker" && ! -e "$TMP/rollback/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys" && $(cat "$TMP/calls") == *"usermod --lock heimdall-storage-probe"* && $(cat "$TMP/calls") != *"chpasswd --encrypted"* ]]'
check 'first-apply post-policy failure removes and reloads the new SSH policy' \
  '[[ ! -e "$TMP/rollback/etc/ssh/sshd_config.d/probe.conf" && ! -e "$TMP/rollback/usr/local/lib/brokkr/probe" && ! -e "$TMP/rollback/etc/brokkr/probe.conf" && $(grep -c "systemctl reload ssh.service" "$TMP/calls") -eq 2 ]]'
check 'first-apply rollback leaves no group-readable authorization behind' \
  '[[ ! -e "$TMP/rollback/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys" && ! -e "$TMP/rollback/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys.new" ]]'

cp "$TMP/usr/local/lib/brokkr/probe" "$TMP/stage/probe"
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"
run apply
# shellcheck disable=SC2034 # consumed by the eval-based assertion below.
expected_reapply_receipt="key_fingerprint=SHA256:fixture probe_sha256=$(sha256 "$TMP/usr/local/lib/brokkr/probe") config_sha256=$(sha256 "$TMP/etc/brokkr/probe.conf") sshd_config_sha256=$(sha256 "$TMP/etc/ssh/sshd_config.d/probe.conf")"
check 'content-identical reapply is idempotent and returns the verified receipt' \
  '[[ $RC -eq 0 && "$OUT" == "$expected_reapply_receipt" ]]'

# shellcheck disable=SC2034 # consumed by the eval-based assertion below.
existing_config_sha=$(sha256 "$TMP/etc/brokkr/probe.conf")
cp "$TMP/usr/local/lib/brokkr/probe" "$TMP/stage/probe"
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"
sed -i.bak 's|MIMIR_SYNC_DIR=/x|MIMIR_SYNC_DIR=/changed|' "$TMP/stage/config"
rm -f "$TMP/stage/config.bak"
run apply
check 'content-changing reapply refuses without clobbering managed state' \
  '[[ $RC -ne 0 && "$OUT" == *"content-changing reapply"* && "$(sha256 "$TMP/etc/brokkr/probe.conf")" == "$existing_config_sha" ]]'
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"

cp "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys" "$TMP/auth.saved"
ln -sf /tmp/other "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys"
cp "$TMP/usr/local/lib/brokkr/probe" "$TMP/stage/probe"
cp "$TMP/etc/brokkr/probe.conf" "$TMP/stage/config"
run apply
check 'symlinked authorization refuses' '[[ $RC -ne 0 && "$OUT" == *"unsafe"* ]]'
rm -f "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys"
mv "$TMP/auth.saved" "$TMP/root/var/lib/heimdall-storage-probe/.ssh/authorized_keys"

printf '\n# drift\n' >>"$TMP/usr/local/lib/brokkr/probe"
run revoke
check 'drifted managed content blocks bounded revoke' \
  '[[ $RC -ne 0 && "$OUT" == *"absent or drifted"* ]]'
sed -i.bak '$d' "$TMP/usr/local/lib/brokkr/probe"
sed -i.bak '$d' "$TMP/usr/local/lib/brokkr/probe"
rm -f "$TMP/usr/local/lib/brokkr/probe.bak"

: >"$TMP/calls"
run revoke
check 'bounded revoke removes only managed artifacts and locks account' \
  '[[ $RC -eq 0 && "$OUT" == "revoked=1" && ! -e "$TMP/usr/local/lib/brokkr/probe" && ! -e "$TMP/etc/brokkr/probe.conf" && ! -e "$TMP/etc/ssh/sshd_config.d/probe.conf" && ! -e "$TMP/var/lib/brokkr/marker" && $(cat "$TMP/calls") == *"usermod --lock heimdall-storage-probe"* && $(cat "$TMP/calls") == *"sshd -t"* && $(cat "$TMP/calls") == *"systemctl reload ssh.service"* ]]'

if (( FAIL )); then exit 1; fi
printf '%s passed\n' "$PASS"
