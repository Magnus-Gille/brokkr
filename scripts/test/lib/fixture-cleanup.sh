#!/usr/bin/env bash
# Bounded cleanup for hermetic test fixtures created by mktemp -d.

fixture_cleanup_dir() {
  local target=$1 attempt last_status=1

  if [[ -z "$target" || ! -d "$target" || -L "$target" ]]; then
    printf 'fixture cleanup refused unsafe target: %s\n' "$target" >&2
    return 1
  fi

  for ((attempt = 1; attempt <= 3; attempt += 1)); do
    if rm -rf -- "$target"; then
      return 0
    else
      last_status=$?
    fi
    if ((attempt < 3)); then
      sleep 0.01
    fi
  done

  printf 'fixture cleanup failed after 3 attempts (last status %d): %s\n' \
    "$last_status" "$target" >&2
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
