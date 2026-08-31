#!/usr/bin/env bash
# Bounded cleanup for hermetic test fixtures allocated by fixture_cleanup_alloc.
#
# Scope: these guards contain ACCIDENTS, not adversaries. They exist so this library can never
# remove a directory it did not itself allocate when handed an empty, stale, mistyped or
# unexpected path — the failure mode that turns a cleanup helper into data loss.
#
# They are deliberately NOT a security boundary against a same-UID process. Such a process can
# already delete every one of these files directly, without involving this library at all, so
# hardening the marker against forgery or closing the stat/rm TOCTOU window would buy no real
# protection. Do not mistake the ownership, mode, marker and identity checks for defence against
# a local attacker; they are assertions that the target is ours.

fixture_cleanup_stat_field() {
  local field=$1 fallback=$2 path=$3

  if stat -c "$field" "$path" 2>/dev/null; then
    return 0
  fi
  stat -f "$fallback" "$path"
}

# Bounded listing of what is still inside a directory, so a recurrence is attributable to an
# actual writer instead of an anonymous "Directory not empty". Entries are printed relative to
# the fixture root, so nothing outside the fixture's own tree is ever disclosed.
fixture_cleanup_residue() {
  local root=$1 max=20 total=0 shown=0 entry

  total="$(find "$root" -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')" || total=0
  while IFS= read -r entry; do
    printf '  residue: %s\n' "${entry#"$root"/}" >&2
    shown=$((shown + 1))
  done < <(find "$root" -mindepth 1 -maxdepth 4 2>/dev/null | LC_ALL=C sort | head -n "$max")
  if ((shown == 0)); then
    printf '  residue: none visible\n' >&2
  elif ((total > shown)); then
    printf '  residue: %d further entries not listed (%d total)\n' \
      "$((total - shown))" "$total" >&2
  fi
}

fixture_cleanup_alloc() {
  local parent target basename identity marker

  parent="$(mktemp -d)" || return 1
  chmod 700 "$parent" || { rmdir "$parent"; return 1; }
  target="$(mktemp -d "$parent/fixture.XXXXXX")" || {
    rmdir "$parent"
    return 1
  }
  basename=${target##*/}
  identity="$(fixture_cleanup_stat_field '%d:%i' '%d:%i' "$target")" || {
    rmdir "$target"; rmdir "$parent"
    return 1
  }
  marker="$parent/.brokkr-fixture.$basename"
  printf 'brokkr-fixture-v1\n%s' "$identity" >"$marker" || {
    rmdir "$target"; rmdir "$parent"
    return 1
  }
  chmod 600 "$marker" || {
    unlink "$marker"; rmdir "$target"; rmdir "$parent"
    return 1
  }
  printf '%s\n' "$target"
}

fixture_cleanup_dir() {
  local target=${1-} parent basename marker marker_contents identity quarantine_parent quarantine
  local parent_owner parent_mode marker_owner marker_mode quarantined_identity
  local attempt last_status=1 current_identity

  parent=${target%/*}
  basename=${target##*/}
  marker="$parent/.brokkr-fixture.$basename"
  if [[ -z "$target" || "$parent" == "$target" || "$parent" == / ||
    ! "$basename" =~ ^fixture\.[A-Za-z0-9]{6}$ || ! -d "$parent" || -L "$parent" ||
    ! -d "$target" || -L "$target" || ! -f "$marker" || -L "$marker" ]]; then
    printf 'fixture cleanup refused unsafe or unallocated target: %s\n' "$target" >&2
    return 1
  fi

  if ! parent_owner="$(fixture_cleanup_stat_field '%u' '%u' "$parent")" ||
    ! parent_mode="$(fixture_cleanup_stat_field '%a' '%Lp' "$parent")" ||
    ! marker_owner="$(fixture_cleanup_stat_field '%u' '%u' "$marker")" ||
    ! marker_mode="$(fixture_cleanup_stat_field '%a' '%Lp' "$marker")"; then
    printf 'fixture cleanup refused uninspectable target: %s\n' "$target" >&2
    return 1
  fi
  if [[ "$parent_owner" != "$(id -u)" || "$parent_mode" != 700 ||
    "$marker_owner" != "$(id -u)" || "$marker_mode" != 600 ]]; then
    printf 'fixture cleanup refused untrusted target: %s\n' "$target" >&2
    return 1
  fi

  if ! identity="$(fixture_cleanup_stat_field '%d:%i' '%d:%i' "$target")"; then
    printf 'fixture cleanup refused uninspectable target: %s\n' "$target" >&2
    return 1
  fi
  if ! marker_contents="$(<"$marker")"; then
    printf 'fixture cleanup refused unreadable marker: %s\n' "$target" >&2
    return 1
  fi
  if [[ "$marker_contents" != $'brokkr-fixture-v1\n'"$identity" ]]; then
    printf 'fixture cleanup refused unallocated or replaced target: %s\n' "$target" >&2
    return 1
  fi

  quarantine_parent="$(mktemp -d "$parent/.cleanup.XXXXXX")" || {
    printf 'fixture cleanup could not create quarantine for: %s\n' "$target" >&2
    return 1
  }
  chmod 700 "$quarantine_parent" || {
    rmdir "$quarantine_parent"
    printf 'fixture cleanup could not secure quarantine for: %s\n' "$target" >&2
    return 1
  }
  quarantine="$quarantine_parent/$basename"
  if ! mv -- "$target" "$quarantine"; then
    rmdir "$quarantine_parent"
    printf 'fixture cleanup could not quarantine target: %s\n' "$target" >&2
    return 1
  fi
  if [[ -L "$quarantine" ]] ||
    ! quarantined_identity="$(fixture_cleanup_stat_field '%d:%i' '%d:%i' "$quarantine")" ||
    [[ "$quarantined_identity" != "$identity" ]]; then
    printf 'fixture cleanup refused replacement; preserved at: %s\n' "$quarantine" >&2
    return 1
  fi

  for ((attempt = 1; attempt <= 3; attempt += 1)); do
    if [[ -e "$quarantine" || -L "$quarantine" ]] &&
      { [[ -L "$quarantine" || ! -d "$quarantine" ]] ||
        ! current_identity="$(fixture_cleanup_stat_field '%d:%i' '%d:%i' "$quarantine")" ||
        [[ "$current_identity" != "$identity" ]]; }; then
      printf 'fixture cleanup refused changed quarantine; preserved at: %s\n' "$quarantine" >&2
      return 1
    fi
    if rm -rf -- "$quarantine" && [[ ! -e "$quarantine" && ! -L "$quarantine" ]]; then
      if ! unlink "$marker" || ! rmdir "$quarantine_parent"; then
        printf 'fixture cleanup failed after quarantined fixture removal: %s\n' "$target" >&2
        return 1
      fi
      if rmdir "$parent"; then
        return 0
      fi
      if [[ -e "$target" || -L "$target" ]]; then
        printf 'fixture cleanup preserved replacement at: %s\n' "$target" >&2
        fixture_cleanup_residue "$target"
        return 1
      fi
      printf 'fixture cleanup failed to remove private parent: %s\n' "$parent" >&2
      return 1
    else
      last_status=$?
    fi
    if ((attempt < 3)); then
      # Escalating but still bounded. A racing writer holding an open descriptor needs more
      # than a few milliseconds to finish; the success path never reaches this sleep at all.
      case $attempt in
        1) sleep 0.05 ;;
        *) sleep 0.25 ;;
      esac
    fi
  done

  printf 'fixture cleanup failed after 3 attempts (last status %d): %s\n' \
    "$last_status" "$quarantine" >&2
  fixture_cleanup_residue "$quarantine"
  return 1
}

fixture_cleanup_on_exit() {
  local test_status=$? cleanup_status=0 target=$1

  fixture_cleanup_dir "$target" || cleanup_status=$?
  if ((test_status != 0)); then
    exit "$test_status"
  fi
  exit "$cleanup_status"
}
