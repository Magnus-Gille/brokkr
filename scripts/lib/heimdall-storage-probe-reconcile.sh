#!/usr/bin/env bash
# Root-side reconciler. Inputs are explicit environment variables, never sourced.
set -euo pipefail
: "${BROKKR_STORAGE_MODE:?}" "${BROKKR_STORAGE_USER:?}" "${BROKKR_STORAGE_PROBE_PATH:?}" "${BROKKR_STORAGE_CONFIG_PATH:?}" "${BROKKR_STORAGE_SSHD_CONFIG_PATH:?}" "${BROKKR_STORAGE_MARKER:?}" "${BROKKR_STORAGE_AUTH_OPTIONS:?}"
fail() { echo "brokkr storage probe remote: $*" >&2; exit 1; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}
marker_value() { awk -F= -v key="$1" '$1 == key { print $2; exit }' "$BROKKR_STORAGE_MARKER"; }
managed() { test -f "$BROKKR_STORAGE_MARKER" && ! test -L "$BROKKR_STORAGE_MARKER" && grep -qx 'schema=brokkr-storage-probe-v3' "$BROKKR_STORAGE_MARKER"; }
managed_artifacts_intact() {
  managed &&
    test -f "$auth" && ! test -L "$auth" &&
    test -f "$BROKKR_STORAGE_PROBE_PATH" && ! test -L "$BROKKR_STORAGE_PROBE_PATH" &&
    test -f "$BROKKR_STORAGE_CONFIG_PATH" && ! test -L "$BROKKR_STORAGE_CONFIG_PATH" &&
    test -f "$BROKKR_STORAGE_SSHD_CONFIG_PATH" && ! test -L "$BROKKR_STORAGE_SSHD_CONFIG_PATH" &&
    test "$(sha256 "$auth")" = "$(marker_value auth_sha256)" &&
    test "$(sha256 "$BROKKR_STORAGE_PROBE_PATH")" = "$(marker_value probe_sha256)" &&
    test "$(sha256 "$BROKKR_STORAGE_CONFIG_PATH")" = "$(marker_value config_sha256)" &&
    test "$(sha256 "$BROKKR_STORAGE_SSHD_CONFIG_PATH")" = "$(marker_value sshd_config_sha256)"
}
verify_sshd_policy() {
  local policy expected
  sshd -t || return 1
  policy="$(sshd -T -C "user=$BROKKR_STORAGE_USER,host=localhost,addr=127.0.0.1")" ||
    return 1
  for expected in \
    'authenticationmethods publickey' \
    'passwordauthentication no' \
    'kbdinteractiveauthentication no' \
    'permitemptypasswords no' \
    'permittty no' \
    'allowtcpforwarding no' \
    'allowstreamlocalforwarding no' \
    'allowagentforwarding no' \
    'gatewayports no' \
    'x11forwarding no' \
    'permittunnel no' \
    'permituserrc no' \
    "forcecommand $BROKKR_STORAGE_PROBE_PATH"; do
    printf '%s\n' "$policy" | grep -Fqx "$expected" || return 1
  done
}
reload_sshd() {
  local unit
  for unit in ssh.service sshd.service; do
    if systemctl is-active --quiet "$unit"; then
      systemctl reload "$unit" || return 1
      return 0
    fi
  done
  return 1
}
root=${BROKKR_STORAGE_TEST_ROOT:-}
home="$root/var/lib/$BROKKR_STORAGE_USER"; ssh_dir="$home/.ssh"; auth="$ssh_dir/authorized_keys"
apply_incomplete=0
new_sshd_policy=0
rollback_incomplete_apply() {
  [[ "$apply_incomplete" == 1 ]] || return 0
  rm -f "$auth.new" "$BROKKR_STORAGE_MARKER.new" "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_MARKER" || true
  usermod --lock "$BROKKR_STORAGE_USER" >/dev/null 2>&1 || true
  if [[ "$new_sshd_policy" == 1 ]]; then
    rm -f "$BROKKR_STORAGE_SSHD_CONFIG_PATH"
    sshd -t >/dev/null 2>&1 && reload_sshd >/dev/null 2>&1 || true
  fi
}
trap rollback_incomplete_apply EXIT
case "$BROKKR_STORAGE_MODE" in
apply)
  : "${BROKKR_STORAGE_EXPECTED_PROBE_SHA256:?}" "${BROKKR_STORAGE_EXPECTED_CONFIG_SHA256:?}" "${BROKKR_STORAGE_EXPECTED_SSHD_CONFIG_SHA256:?}" "${BROKKR_STORAGE_PUBKEY:?}" "${BROKKR_STORAGE_FINGERPRINT:?}"
  for file in "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_STAGE_CONFIG" "$BROKKR_STORAGE_STAGE_SSHD_CONFIG"; do
    { [[ -n "${BROKKR_STORAGE_TEST_ROOT:-}" ]] || [[ "$file" =~ ^/tmp/brokkr-storage-probe\.[0-9]+\.(probe|config|sshd)\.new$ ]]; } && test -f "$file" && ! test -L "$file" || fail 'unsafe staging artifact'
  done
  test "$(sha256 "$BROKKR_STORAGE_STAGE_PROBE")" = "$BROKKR_STORAGE_EXPECTED_PROBE_SHA256" || fail 'staged probe digest mismatch'
  test "$(sha256 "$BROKKR_STORAGE_STAGE_CONFIG")" = "$BROKKR_STORAGE_EXPECTED_CONFIG_SHA256" || fail 'staged config digest mismatch'
  test "$(sha256 "$BROKKR_STORAGE_STAGE_SSHD_CONFIG")" = "$BROKKR_STORAGE_EXPECTED_SSHD_CONFIG_SHA256" || fail 'staged sshd configuration digest mismatch'
  bash -n "$BROKKR_STORAGE_STAGE_PROBE" || fail 'staged probe syntax is invalid'
  test "$(grep -Ec '^echo ---[[:space:]]*$' "$BROKKR_STORAGE_STAGE_PROBE")" -eq 18 || fail 'staged probe section contract is invalid'
  BROKKR_STORAGE_PROBE_CONFIG="$BROKKR_STORAGE_STAGE_CONFIG" bash "$BROKKR_STORAGE_STAGE_PROBE" --validate-config ||
    fail 'staged probe configuration is invalid'
  if ! id "$BROKKR_STORAGE_USER" >/dev/null 2>&1; then useradd --system --create-home --home-dir "$home" --shell /bin/sh --user-group "$BROKKR_STORAGE_USER"; fi
  test "$(getent passwd "$BROKKR_STORAGE_USER" | cut -d: -f6)" = "$home" || fail 'dedicated account contract drift'
  test "$(getent passwd "$BROKKR_STORAGE_USER" | cut -d: -f7)" = /bin/sh || fail 'dedicated account contract drift'
  test "$(id -gn "$BROKKR_STORAGE_USER")" = "$BROKKR_STORAGE_USER" || fail 'dedicated account group contract drift'
  for file in "$home" "$ssh_dir" "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_SSHD_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"; do test ! -L "$file" || fail 'managed artifact path is unsafe'; done
  if test -e "$auth" || test -e "$BROKKR_STORAGE_PROBE_PATH" || test -e "$BROKKR_STORAGE_CONFIG_PATH" || test -e "$BROKKR_STORAGE_SSHD_CONFIG_PATH" || test -e "$BROKKR_STORAGE_MARKER"; then
    managed_artifacts_intact || fail 'refusing to replace unmanaged or drifted artifact'
    expected_auth_digest="$(printf '%s %s\n' "$BROKKR_STORAGE_AUTH_OPTIONS" "$BROKKR_STORAGE_PUBKEY" | sha256_stdin)"
    test "$BROKKR_STORAGE_EXPECTED_PROBE_SHA256" = "$(marker_value probe_sha256)" &&
      test "$BROKKR_STORAGE_EXPECTED_CONFIG_SHA256" = "$(marker_value config_sha256)" &&
    test "$BROKKR_STORAGE_EXPECTED_SSHD_CONFIG_SHA256" = "$(marker_value sshd_config_sha256)" &&
      test "$expected_auth_digest" = "$(marker_value auth_sha256)" ||
      fail 'refusing content-changing reapply'
    probe_digest="$(marker_value probe_sha256)"
    config_digest="$(marker_value config_sha256)"
    sshd_config_digest="$(marker_value sshd_config_sha256)"
    verify_sshd_policy || fail 'effective sshd policy is not public-key forced-command only'
  else
    apply_incomplete=1
    install -d -m 0755 -o root -g root "$home" "$(dirname "$BROKKR_STORAGE_PROBE_PATH")" "$(dirname "$BROKKR_STORAGE_CONFIG_PATH")" "$(dirname "$BROKKR_STORAGE_SSHD_CONFIG_PATH")" "$(dirname "$BROKKR_STORAGE_MARKER")"
    # sshd temporarily adopts the account UID to read AuthorizedKeysFile.  Keep
    # root as owner, but give only the account's private group the traverse/read
    # path; the group has no write bit on either managed authorization artifact.
    install -d -m 0750 -o root -g "$BROKKR_STORAGE_USER" "$ssh_dir"; chown root:root "$home"; chown root:"$BROKKR_STORAGE_USER" "$ssh_dir"; chmod 0755 "$home"; chmod 0750 "$ssh_dir"
    rm -f "$auth.new" "$BROKKR_STORAGE_MARKER.new"
    new_sshd_policy=1
    install -m 0644 -o root -g root "$BROKKR_STORAGE_STAGE_SSHD_CONFIG" "$BROKKR_STORAGE_SSHD_CONFIG_PATH"
    verify_sshd_policy || fail 'effective sshd policy is not public-key forced-command only'
    reload_sshd || fail 'could not safely reload SSH daemon'
    install -m 0755 -o root -g root "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_PROBE_PATH"
    install -m 0640 -o root -g "$BROKKR_STORAGE_USER" "$BROKKR_STORAGE_STAGE_CONFIG" "$BROKKR_STORAGE_CONFIG_PATH"
    printf '%s %s\n' "$BROKKR_STORAGE_AUTH_OPTIONS" "$BROKKR_STORAGE_PUBKEY" >"$auth.new"; chown root:"$BROKKR_STORAGE_USER" "$auth.new"; chmod 0640 "$auth.new"; mv "$auth.new" "$auth"
    auth_digest=$(sha256 "$auth"); probe_digest=$(sha256 "$BROKKR_STORAGE_PROBE_PATH"); config_digest=$(sha256 "$BROKKR_STORAGE_CONFIG_PATH")
    sshd_config_digest=$(sha256 "$BROKKR_STORAGE_SSHD_CONFIG_PATH")
    printf 'schema=brokkr-storage-probe-v3\nkey_fingerprint=%s\nauth_sha256=%s\nprobe_sha256=%s\nconfig_sha256=%s\nsshd_config_sha256=%s\n' "$BROKKR_STORAGE_FINGERPRINT" "$auth_digest" "$probe_digest" "$config_digest" "$sshd_config_digest" >"$BROKKR_STORAGE_MARKER.new"; chown root:root "$BROKKR_STORAGE_MARKER.new"; chmod 0600 "$BROKKR_STORAGE_MARKER.new"; mv "$BROKKR_STORAGE_MARKER.new" "$BROKKR_STORAGE_MARKER"
    apply_incomplete=0
  fi
  password_hash="$(openssl rand -base64 48 | openssl passwd -6 -stdin)" || fail 'could not generate dedicated account password hash'
  [[ "$password_hash" == \$6\$* ]] || fail 'generated dedicated account password hash is invalid'
  if ! printf '%s:%s\n' "$BROKKR_STORAGE_USER" "$password_hash" | chpasswd --encrypted; then
    unset password_hash
    fail 'could not set dedicated account password hash'
  fi
  unset password_hash
  rm -f "$BROKKR_STORAGE_STAGE_PROBE" "$BROKKR_STORAGE_STAGE_CONFIG" "$BROKKR_STORAGE_STAGE_SSHD_CONFIG"
  printf 'key_fingerprint=%s probe_sha256=%s config_sha256=%s sshd_config_sha256=%s\n' "$BROKKR_STORAGE_FINGERPRINT" "$probe_digest" "$config_digest" "$sshd_config_digest"
  ;;
revoke)
  managed_artifacts_intact || fail 'managed artifacts are absent or drifted; refusing bounded revoke'
  for file in "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_SSHD_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"; do test ! -L "$file" || fail 'managed artifact path is unsafe'; done
  rm -f "$auth" "$BROKKR_STORAGE_PROBE_PATH" "$BROKKR_STORAGE_CONFIG_PATH" "$BROKKR_STORAGE_SSHD_CONFIG_PATH" "$BROKKR_STORAGE_MARKER"
  usermod --lock "$BROKKR_STORAGE_USER"
  sshd -t || fail 'post-revocation sshd configuration validation failed'
  reload_sshd || fail 'revocation removed access but could not safely reload SSH daemon'
  echo 'revoked=1'
  ;;
*) fail 'unsupported mode';;
esac
