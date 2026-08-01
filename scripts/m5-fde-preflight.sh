#!/usr/bin/env bash
# Read-only, public-safe readiness check for an owner-attended M5 FDE ceremony.
#
# This script never changes a block device, keyslot, boot setting, backup, or
# service. It emits only coarse states so device names and backup locators do
# not leak into tickets or logs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/m5-fde-preflight.sh \
  --copy-observed-at EPOCH \
  --integrity-verified-at EPOCH \
  --restore-verified-at EPOCH \
  --key-recovery-verified-at EPOCH \
  --attest-copy-observed \
  --attest-integrity-verified \
  --attest-restore-validated \
  --attest-backup-key-recovered \
  [--max-copy-age-hours N] \
  [--max-integrity-age-hours N] \
  [--max-restore-age-days N] \
  [--max-key-recovery-age-days N]

Exit 0 means the read-only ceremony gate passed. Exit 2 means it failed closed.
The attestation flags mean the operator inspected the underlying evidence, not
merely its timestamp. The timestamps must come from an access-controlled record;
do not pass recovery material, device names, or backup locations.
USAGE
}

COPY_AT=""
INTEGRITY_AT=""
RESTORE_AT=""
KEY_RECOVERY_AT=""
ATTEST_COPY=no
ATTEST_INTEGRITY=no
ATTEST_RESTORE=no
ATTEST_KEY_RECOVERY=no
MAX_COPY_HOURS=24
MAX_INTEGRITY_HOURS=24
MAX_RESTORE_DAYS=30
MAX_KEY_RECOVERY_DAYS=90

require_value() {
  if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
    printf 'Option %s requires a value.\n' "$1" >&2
    exit 64
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-observed-at) require_value "$@"; COPY_AT="$2"; shift 2 ;;
    --integrity-verified-at) require_value "$@"; INTEGRITY_AT="$2"; shift 2 ;;
    --restore-verified-at) require_value "$@"; RESTORE_AT="$2"; shift 2 ;;
    --key-recovery-verified-at) require_value "$@"; KEY_RECOVERY_AT="$2"; shift 2 ;;
    --attest-copy-observed) ATTEST_COPY=yes; shift ;;
    --attest-integrity-verified) ATTEST_INTEGRITY=yes; shift ;;
    --attest-restore-validated) ATTEST_RESTORE=yes; shift ;;
    --attest-backup-key-recovered) ATTEST_KEY_RECOVERY=yes; shift ;;
    --max-copy-age-hours) require_value "$@"; MAX_COPY_HOURS="$2"; shift 2 ;;
    --max-integrity-age-hours) require_value "$@"; MAX_INTEGRITY_HOURS="$2"; shift 2 ;;
    --max-restore-age-days) require_value "$@"; MAX_RESTORE_DAYS="$2"; shift 2 ;;
    --max-key-recovery-age-days) require_value "$@"; MAX_KEY_RECOVERY_DAYS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

for max_value in \
  "$MAX_COPY_HOURS" \
  "$MAX_INTEGRITY_HOURS" \
  "$MAX_RESTORE_DAYS" \
  "$MAX_KEY_RECOVERY_DAYS"; do
  if ! is_positive_integer "$max_value"; then
    printf 'Evidence age limits must be positive integers.\n' >&2
    exit 64
  fi
done

: "${DATE_BIN:=date}"
: "${FINDMNT_BIN:=findmnt}"
: "${LSBLK_BIN:=lsblk}"
: "${CRYPTSETUP_BIN:=cryptsetup}"
: "${MOKUTIL_BIN:=mokutil}"
: "${TPM_SYSFS_ROOT:=/sys/class/tpm}"

NOW="$($DATE_BIN +%s 2>/dev/null || true)"
if ! is_positive_integer "$NOW"; then
  printf 'Unable to obtain the current epoch.\n' >&2
  exit 2
fi

evidence_state() {
  local observed_at="$1"
  local max_age_seconds="$2"
  local attested="$3"
  local age

  if [[ "$attested" != yes ]]; then
    printf 'unattested\n'
    return
  fi
  if [[ -z "$observed_at" ]]; then
    printf 'unknown\n'
    return
  fi
  if ! is_positive_integer "$observed_at"; then
    printf 'invalid\n'
    return
  fi
  if (( observed_at > NOW )); then
    printf 'future\n'
    return
  fi
  age=$((NOW - observed_at))
  if (( age > max_age_seconds )); then
    printf 'stale\n'
  else
    printf 'pass\n'
  fi
}

backup_copy="$(evidence_state "$COPY_AT" "$((MAX_COPY_HOURS * 3600))" "$ATTEST_COPY")"
backup_integrity="$(evidence_state "$INTEGRITY_AT" "$((MAX_INTEGRITY_HOURS * 3600))" "$ATTEST_INTEGRITY")"
backup_restore="$(evidence_state "$RESTORE_AT" "$((MAX_RESTORE_DAYS * 86400))" "$ATTEST_RESTORE")"
backup_key_recovery="$(evidence_state "$KEY_RECOVERY_AT" "$((MAX_KEY_RECOVERY_DAYS * 86400))" "$ATTEST_KEY_RECOVERY")"

secure_boot=unknown
if [[ -x "$MOKUTIL_BIN" ]] || command -v "$MOKUTIL_BIN" >/dev/null 2>&1; then
  mokutil_output="$($MOKUTIL_BIN --sb-state 2>/dev/null || true)"
  if printf '%s\n' "$mokutil_output" | grep -qi 'SecureBoot enabled'; then
    secure_boot=enabled
  elif printf '%s\n' "$mokutil_output" | grep -qi 'SecureBoot disabled'; then
    secure_boot=disabled
  fi
fi

tpm2=unknown
if [[ -r "$TPM_SYSFS_ROOT/tpm0/tpm_version_major" ]]; then
  tpm_version="$(tr -d '[:space:]' <"$TPM_SYSFS_ROOT/tpm0/tpm_version_major")"
  if [[ "$tpm_version" == 2 ]]; then
    tpm2=present
  elif [[ -n "$tpm_version" ]]; then
    tpm2=not-tpm2
  fi
fi

root_encryption=unknown
migration_required=unknown
root_source=""
if [[ -x "$FINDMNT_BIN" ]] || command -v "$FINDMNT_BIN" >/dev/null 2>&1; then
  root_source="$($FINDMNT_BIN -n -o SOURCE / 2>/dev/null || true)"
fi
if [[ -n "$root_source" ]] && { [[ -x "$LSBLK_BIN" ]] || command -v "$LSBLK_BIN" >/dev/null 2>&1; }; then
  root_topology="$($LSBLK_BIN -s -n -p -o PATH,TYPE "$root_source" 2>/dev/null || true)"
  if [[ -n "$root_topology" ]]; then
    crypt_path="$(printf '%s\n' "$root_topology" | awk '$NF == "crypt" {print $1; exit}')"
    if [[ -z "$crypt_path" ]]; then
      root_encryption=not-luks-backed
      migration_required=yes
    elif [[ -x "$CRYPTSETUP_BIN" ]] || command -v "$CRYPTSETUP_BIN" >/dev/null 2>&1; then
      crypt_status="$($CRYPTSETUP_BIN status "$crypt_path" 2>/dev/null || true)"
      crypt_type="$(printf '%s\n' "$crypt_status" | awk -F: 'tolower($1) ~ /^[[:space:]]*type[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}')"
      case "$crypt_type" in
        luks2) root_encryption=luks2; migration_required=no ;;
        luks1) root_encryption=luks1; migration_required=yes ;;
        *) root_encryption=dm-crypt-unknown; migration_required=unknown ;;
      esac
    else
      root_encryption=dm-crypt-unknown
    fi
  fi
fi

ceremony_gate=pass
for state in \
  "$backup_copy" \
  "$backup_integrity" \
  "$backup_restore" \
  "$backup_key_recovery"; do
  [[ "$state" == pass ]] || ceremony_gate=fail
done
[[ "$secure_boot" == enabled ]] || ceremony_gate=fail
[[ "$tpm2" == present ]] || ceremony_gate=fail
case "$root_encryption" in
  not-luks-backed|luks1|luks2) ;;
  *) ceremony_gate=fail ;;
esac

printf 'preflight_version=1\n'
printf 'operation=read-only\n'
printf 'backup_copy=%s\n' "$backup_copy"
printf 'backup_integrity=%s\n' "$backup_integrity"
printf 'backup_restore=%s\n' "$backup_restore"
printf 'backup_key_recovery=%s\n' "$backup_key_recovery"
printf 'secure_boot=%s\n' "$secure_boot"
printf 'tpm2=%s\n' "$tpm2"
printf 'root_encryption=%s\n' "$root_encryption"
printf 'migration_required=%s\n' "$migration_required"
printf 'ceremony_gate=%s\n' "$ceremony_gate"

[[ "$ceremony_gate" == pass ]] || exit 2
