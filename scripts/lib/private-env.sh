# shellcheck shell=bash
# ─── Brokkr private env-file loader ──────────────────────────────────────────
#
# brokkr_private_file_ok PATH LABEL  → 0 when PATH is a regular, non-symlink file
#                                      owned by the current uid with no group/other
#                                      permissions; otherwise prints why and returns 1.
# brokkr_source_private_env PATH     → validates PATH as above, checks its syntax,
#                                      then sources it with `set -a`. Returns 1 (and
#                                      sources nothing) on any failure.
#
# A sourced env file is shell code, so it is treated like a private executable:
# every check runs before the file is parsed or sourced. Callers decide whether an
# absent file is acceptable; these helpers reject one. bash 3.2+ (macOS and Linux).

brokkr_private_file_ok() {
  local path="$1" label="${2:-file}" owner_uid mode current_uid
  if [ -L "$path" ]; then
    echo "ERROR: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "ERROR: $label is not a regular file: $path" >&2
    return 1
  fi
  if owner_uid=$(stat -c '%u' "$path" 2>/dev/null); then
    mode=$(stat -c '%a' "$path" 2>/dev/null) || mode=""
  else
    owner_uid=$(stat -f '%u' "$path" 2>/dev/null) || owner_uid=""
    mode=$(stat -f '%Lp' "$path" 2>/dev/null) || mode=""
  fi
  if [ -z "$owner_uid" ] || [ -z "$mode" ]; then
    echo "ERROR: cannot inspect $label owner/mode: $path" >&2
    return 1
  fi
  current_uid=$(id -u)
  if [ "$owner_uid" != "$current_uid" ]; then
    echo "ERROR: $label owner uid $owner_uid does not match current uid $current_uid: $path" >&2
    return 1
  fi
  # Owner permissions may vary (0400, 0600); group/other must have none.
  case "$mode" in
    *00) ;;
    *) echo "ERROR: $label mode $mode is unsafe; group/other permissions must be 00: $path" >&2
       return 1 ;;
  esac
  return 0
}

brokkr_source_private_env() {
  local path="$1"
  brokkr_private_file_ok "$path" "env file" || return 1
  # A parse error in a sourced file aborts the shell before any handler can run,
  # so `bash -n` turns it into an attributable failure first.
  if ! bash -n "$path" 2>/dev/null; then
    echo "ERROR: env file has a syntax error: $path" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  if ! . "$path"; then
    set +a
    echo "ERROR: cannot source env file: $path" >&2
    return 1
  fi
  set +a
  return 0
}
