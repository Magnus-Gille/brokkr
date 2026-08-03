#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/m5-fde-preflight.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brokkr-m5-fde-preflight-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'not ok - %s\n' "$label" >&2
    FAIL=$((FAIL + 1))
  fi
}

mkdir -p "$TMP/bin" "$TMP/tpm/tpm0"

cat >"$TMP/bin/date" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_NOW_EPOCH:?}"
MOCK
cat >"$TMP/bin/findmnt" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '/dev/fixture-root'
MOCK
cat >"$TMP/bin/lsblk" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_LSBLK_OUTPUT:-/dev/fixture-root ext4}"
MOCK
cat >"$TMP/bin/cryptsetup" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_CALLS:?}"
if [[ "${MOCK_CRYPTSETUP_RC:-0}" -ne 0 ]]; then
  exit "$MOCK_CRYPTSETUP_RC"
fi
printf '%s\n' "${MOCK_CRYPTSETUP_OUTPUT:-type: LUKS2}"
MOCK
cat >"$TMP/bin/mokutil" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_CALLS:?}"
printf '%s\n' "${MOCK_MOKUTIL_OUTPUT:-SecureBoot enabled}"
exit "${MOCK_MOKUTIL_RC:-0}"
MOCK
chmod +x "$TMP/bin/"*
printf '2\n' >"$TMP/tpm/tpm0/tpm_version_major"

NOW=2000000000
FRESH_COPY=$((NOW - 3600))
FRESH_RESTORE=$((NOW - 86400))
FRESH_KEY=$((NOW - 86400))

run_preflight() {
  local output="$1"
  shift
  : >"$TMP/calls"
  set +e
  env \
    FINDMNT_BIN="$TMP/bin/findmnt" \
    LSBLK_BIN="$TMP/bin/lsblk" \
    CRYPTSETUP_BIN="$TMP/bin/cryptsetup" \
    MOKUTIL_BIN="$TMP/bin/mokutil" \
    DATE_BIN="$TMP/bin/date" \
    TPM_SYSFS_ROOT="$TMP/tpm" \
    MOCK_CALLS="$TMP/calls" \
    MOCK_NOW_EPOCH="$NOW" \
    MOCK_LSBLK_OUTPUT="${MOCK_LSBLK_OUTPUT:-/dev/fixture-root ext4}" \
    MOCK_CRYPTSETUP_OUTPUT="${MOCK_CRYPTSETUP_OUTPUT:-type: LUKS2}" \
    MOCK_CRYPTSETUP_RC="${MOCK_CRYPTSETUP_RC:-0}" \
    MOCK_MOKUTIL_OUTPUT="${MOCK_MOKUTIL_OUTPUT:-SecureBoot enabled}" \
    MOCK_MOKUTIL_RC="${MOCK_MOKUTIL_RC:-0}" \
    bash "$SCRIPT" "$@" >"$output" 2>&1
  RUN_RC=$?
  set -e
}

fresh_args=(
  --copy-observed-at "$FRESH_COPY"
  --integrity-verified-at "$FRESH_COPY"
  --restore-verified-at "$FRESH_RESTORE"
  --key-recovery-verified-at "$FRESH_KEY"
  --attest-copy-observed
  --attest-integrity-verified
  --attest-restore-validated
  --attest-backup-key-recovered
)

run_preflight "$TMP/ready.out" "${fresh_args[@]}"
check "fresh evidence, Secure Boot, TPM2, and readable topology pass" test "$RUN_RC" -eq 0
check "unencrypted root is reported without exposing the root path" grep -q '^root_encryption=not-luks-backed$' "$TMP/ready.out"
check "unencrypted root requires migration" grep -q '^migration_required=yes$' "$TMP/ready.out"
check "all evidence produces an explicit ceremony pass" grep -q '^ceremony_gate=pass$' "$TMP/ready.out"
check "root device path is redacted from output" sh -c "! grep -q '/dev/fixture-root' '$TMP/ready.out'"
check "preflight uses only Secure Boot status operation" grep -qx -- '--sb-state' "$TMP/calls"

run_preflight "$TMP/missing.out"
check "missing backup evidence fails closed" test "$RUN_RC" -eq 2
check "missing restore evidence is unattested" grep -q '^backup_restore=unattested$' "$TMP/missing.out"
check "missing evidence blocks the ceremony" grep -q '^ceremony_gate=fail$' "$TMP/missing.out"

run_preflight "$TMP/unattested.out" \
  --copy-observed-at "$FRESH_COPY" \
  --integrity-verified-at "$FRESH_COPY" \
  --restore-verified-at "$FRESH_RESTORE" \
  --key-recovery-verified-at "$FRESH_KEY"
check "timestamps without evidence attestations fail closed" test "$RUN_RC" -eq 2
check "unattested restore is not treated as proof" grep -q '^backup_restore=unattested$' "$TMP/unattested.out"

run_preflight "$TMP/no-restore-timestamp.out" \
  --attest-restore-validated
check "attestation without a timestamp fails closed" test "$RUN_RC" -eq 2
check "attestation without a timestamp remains unknown" grep -q '^backup_restore=unknown$' "$TMP/no-restore-timestamp.out"

run_preflight "$TMP/missing-value.out" --copy-observed-at
check "option without a value is a usage error" test "$RUN_RC" -eq 64

run_preflight "$TMP/stale.out" \
  --copy-observed-at "$((NOW - 90000))" \
  --integrity-verified-at "$FRESH_COPY" \
  --restore-verified-at "$FRESH_RESTORE" \
  --key-recovery-verified-at "$FRESH_KEY" \
  --attest-copy-observed \
  --attest-integrity-verified \
  --attest-restore-validated \
  --attest-backup-key-recovered
check "stale copy evidence fails closed" test "$RUN_RC" -eq 2
check "stale copy is attributable" grep -q '^backup_copy=stale$' "$TMP/stale.out"

run_preflight "$TMP/future.out" \
  --copy-observed-at "$((NOW + 1))" \
  --integrity-verified-at "$FRESH_COPY" \
  --restore-verified-at "$FRESH_RESTORE" \
  --key-recovery-verified-at "$FRESH_KEY" \
  --attest-copy-observed \
  --attest-integrity-verified \
  --attest-restore-validated \
  --attest-backup-key-recovered
check "future-dated evidence fails closed" test "$RUN_RC" -eq 2
check "future-dated copy is attributable" grep -q '^backup_copy=future$' "$TMP/future.out"

MOCK_MOKUTIL_OUTPUT='SecureBoot disabled' run_preflight "$TMP/sb-disabled.out" "${fresh_args[@]}"
check "disabled Secure Boot blocks TPM/FDE ceremony" test "$RUN_RC" -eq 2
check "disabled Secure Boot is attributable" grep -q '^secure_boot=disabled$' "$TMP/sb-disabled.out"

mv "$TMP/tpm/tpm0/tpm_version_major" "$TMP/tpm/tpm0/tpm_version_major.off"
run_preflight "$TMP/tpm-missing.out" "${fresh_args[@]}"
check "missing TPM2 evidence blocks the ceremony" test "$RUN_RC" -eq 2
check "missing TPM2 is attributable" grep -q '^tpm2=unknown$' "$TMP/tpm-missing.out"
mv "$TMP/tpm/tpm0/tpm_version_major.off" "$TMP/tpm/tpm0/tpm_version_major"

MOCK_LSBLK_OUTPUT=$'/dev/fixture-root lvm\n/dev/mapper/fixture-crypt crypt\n/dev/fixture-parent part' \
  run_preflight "$TMP/luks2.out" "${fresh_args[@]}"
check "LUKS2-backed root passes current-state proof" test "$RUN_RC" -eq 0
check "LUKS2-backed root is recognized" grep -q '^root_encryption=luks2$' "$TMP/luks2.out"
check "LUKS2-backed root needs no migration" grep -q '^migration_required=no$' "$TMP/luks2.out"
check "cryptsetup is only used for read-only status" grep -qx -- 'status /dev/mapper/fixture-crypt' "$TMP/calls"

MOCK_LSBLK_OUTPUT=$'/dev/fixture-root lvm\n/dev/mapper/fixture-crypt crypt\n/dev/fixture-parent part' \
MOCK_CRYPTSETUP_OUTPUT='type: PLAIN' \
  run_preflight "$TMP/plain.out" "${fresh_args[@]}"
check "dm-crypt without LUKS proof fails closed" test "$RUN_RC" -eq 2
check "non-LUKS mapping is attributable" grep -q '^root_encryption=dm-crypt-unknown$' "$TMP/plain.out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
