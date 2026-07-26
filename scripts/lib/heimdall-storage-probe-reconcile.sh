#!/usr/bin/env bash
# Root-side reconciler. Inputs are explicit environment variables, never sourced.
set -euo pipefail
: "${BROKKR_STORAGE_MODE:?}" "${BROKKR_STORAGE_USER:?}" "${BROKKR_STORAGE_PROBE_PATH:?}" "${BROKKR_STORAGE_CONFIG_PATH:?}" "${BROKKR_STORAGE_MARKER:?}" "${BROKKR_STORAGE_AUTH_OPTIONS:?}"
fail() { echo "brokkr storage probe remote: $*" >&2; exit 1; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
marker_value() { awk -F= -v key="$1" '$1 == key { print $2; exit }' "$BROKKR_STORAGE_MARKER"; }
managed() { test -f "$BROKKR_STORAGE_MARKER" && ! test -L "$BROKKR_STORAGE_MARKER" && grep -qx 'schema=brokkr-storage-probe-v2' "$BROKKR_STORAGE_MARKER"; }
managed_artifacts_intact() {
  managed &&
    test -f "$auth" && ! test -L "$auth" &&
    test -f "$BROKKR_STORAGE_PROBE_PATH" && ! test -L "$BROKKR_STORAGE_PROBE_PATH" &&
    test -f "$BROKKR_STORAGE_CONFIG_PATH" && ! test -L "$BROKKR_STORAGE_CONFIG_PATH" &&
    test "$(sha256 "$auth")" = "$(marker_value auth_sha256)" &&
    test "$(sha256 "$BROKKR_STORAGE_PROBE_PATH")" = "$(marker_value probe_sha256)" &&
    test "$(sha256 "$BROKKR_STORAGE_CONFIG_PATH")" = "$(marker_value config_sha256)"
}
root=${BROKKR_STORAGE_TEST_ROOT:-}
home="$root/var/lib/$BROKKR_STORAGE_USER"; ssh_dir="$home/.ssh"; auth="$ssh_dir/authorized_keys"
case "$BROKKR_STORAGE_MODE" in
apply)
  : "${BROKKR_STORAGE_EXPECTED_PROBE_SHA256:?}" "${BROKKR_STORAGE_EXPECTED_CONFIG_SHA256:?}" "${BROKKR_STORAGE_PUBKEY:?}" "${BROKKR_STORAGE_FINGERPRINT:?}"
  for file in "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_STAGE_CONFIG"; do
    { [[ -n "${BROKKR_STORAGE_TEST_ROOT:-}" ]] || [[ "$file" =~ ^/tmp/brokkr-storage-probe\.[0-9]+\.(probe|config)\.new$ ]]; } && test -f "$file" && ! test -L "$file" || fail 'unsafe staging artifact'
  done
  test "$(sha256 "$BROKKR_STORAGE_STAGE_PROBE")" = "$BROKKR_STORAGE_EXPECTED_PROBE_SHA256" || fail 'staged probe digest mismatch'
  test "$(sha256 "$BROKKR_STORAGE_STAGE_CONFIG")" = "$BROKKR_STORAGE_EXPECTED_CONFIG_SHA256" || fail 'staged config digest mismatch'
  bash -n "$BROKKR_STORAGE_STAGE_PROBE" || fail 'staged probe syntax is invalid'
  test "$(grep -Ec '^echo ---[[:space:]]*$' "$BROKKR_STORAGE_STAGE_PROBE")" -eq 18 || fail 'staged probe section contract is invalid'
  BROKKR_STORAGE_PROBE_CONFIG="$BROKKR_STORAGE_STAGE_CONFIG" bash "$BROKKR_STORAGE_STAGE_PROBE" --validate-config ||
    fail 'staged probe configuration is invalid'
  if ! id "$BROKKR_STORAGE_USER" >/dev/null 2>&1; then useradd --system --create-home --home-dir "$home" --shell /bin/sh --user-group "$BROKKR_STORAGE_USER"; fi
  test "$(getent passwd "$BROKKR_STORAGE_USER" | cut -d: -f6)" = "$home" || fail 'dedicated account contract drift'
  test "$(getent passwd "$BROKKR_STORAGE_USER" | cut -d: -f7)" = /bin/sh || fail 'dedicated account contract drift'
  test "$(id -gn "$BROKKR_STORAGE_USER")" = "$BROKKR_STORAGE_USER" || fail 'dedicated account group contract drift'
  for file in "$home" "$ssh_dir" "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"; do test ! -L "$file" || fail 'managed artifact path is unsafe'; done
  if test -e "$auth" || test -e "$BROKKR_STORAGE_PROBE_PATH" || test -e "$BROKKR_STORAGE_CONFIG_PATH" || test -e "$BROKKR_STORAGE_MARKER"; then
    managed_artifacts_intact || fail 'refusing to replace unmanaged or drifted artifact'
  fi
  install -d -m 0755 -o root -g root "$home" "$(dirname "$BROKKR_STORAGE_PROBE_PATH")" "$(dirname "$BROKKR_STORAGE_CONFIG_PATH")" "$(dirname "$BROKKR_STORAGE_MARKER")"
  install -d -m 0700 -o root -g root "$ssh_dir"; chown root:root "$home" "$ssh_dir"; chmod 0755 "$home"; chmod 0700 "$ssh_dir"
  rm -f "$auth.new" "$BROKKR_STORAGE_MARKER.new"
  install -m 0755 -o root -g root "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_PROBE_PATH"
  install -m 0640 -o root -g "$BROKKR_STORAGE_USER" "$BROKKR_STORAGE_STAGE_CONFIG" "$BROKKR_STORAGE_CONFIG_PATH"
  printf '%s %s\n' "$BROKKR_STORAGE_AUTH_OPTIONS" "$BROKKR_STORAGE_PUBKEY" >"$auth.new"; chown root:root "$auth.new"; chmod 0600 "$auth.new"; mv "$auth.new" "$auth"
  auth_digest=$(sha256 "$auth"); probe_digest=$(sha256 "$BROKKR_STORAGE_PROBE_PATH"); config_digest=$(sha256 "$BROKKR_STORAGE_CONFIG_PATH")
  printf 'schema=brokkr-storage-probe-v2\nkey_fingerprint=%s\nauth_sha256=%s\nprobe_sha256=%s\nconfig_sha256=%s\n' "$BROKKR_STORAGE_FINGERPRINT" "$auth_digest" "$probe_digest" "$config_digest" >"$BROKKR_STORAGE_MARKER.new"; chown root:root "$BROKKR_STORAGE_MARKER.new"; chmod 0600 "$BROKKR_STORAGE_MARKER.new"; mv "$BROKKR_STORAGE_MARKER.new" "$BROKKR_STORAGE_MARKER"
  rm -f "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_STAGE_CONFIG"
  printf 'key_fingerprint=%s probe_sha256=%s config_sha256=%s\n' "$BROKKR_STORAGE_FINGERPRINT" "$probe_digest" "$config_digest"
  ;;
revoke)
  managed_artifacts_intact || fail 'managed artifacts are absent or drifted; refusing bounded revoke'
  for file in "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"; do test ! -L "$file" || fail 'managed artifact path is unsafe'; done
  rm -f "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"; usermod --lock "$BROKKR_STORAGE_USER"; echo 'revoked=1'
  ;;
*) fail 'unsupported mode';;
esac
