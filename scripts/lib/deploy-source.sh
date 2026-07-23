#!/usr/bin/env bash
# Reusable local deployment-source identity guard.

is_full_commit_sha() {
  local revision=${1:-}
  [[ "$revision" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

verify_deploy_source_identity() {
  local requested_source=${1:-} expected_revision=${2:-}
  local invocation_source=${3:-$PWD}
  local expected_source invocation_path actual_source actual_revision

  if ! is_full_commit_sha "$expected_revision"; then
    echo "ERROR: deploy source requires an explicit full commit SHA (40 or 64 lowercase hex characters)" >&2
    return 1
  fi

  if ! expected_source=$(cd "$requested_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $requested_source @ $expected_revision"
    echo "Actual source: unresolved @ unknown"
    echo "ERROR: deployment source directory does not exist or is not accessible" >&2
    return 1
  fi

  if ! invocation_path=$(cd "$invocation_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: unresolved @ unknown"
    echo "ERROR: deployment invocation directory does not exist or is not accessible" >&2
    return 1
  fi

  if ! actual_source=$(git -C "$invocation_path" rev-parse --show-toplevel 2>/dev/null); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: $invocation_path @ not-a-git-worktree"
    echo "ERROR: deployment invocation source is not a git worktree" >&2
    return 1
  fi
  if ! actual_source=$(cd "$actual_source" 2>/dev/null && pwd -P); then
    echo "Expected source: $expected_source @ $expected_revision"
    echo "Actual source: unresolved-git-root @ unknown"
    echo "ERROR: deployment source Git root cannot be resolved" >&2
    return 1
  fi
  actual_revision=$(git -C "$actual_source" rev-parse --verify HEAD 2>/dev/null || echo unknown)

  echo "Expected source: $expected_source @ $expected_revision"
  echo "Actual source: $actual_source @ $actual_revision"

  if [[ "$expected_source" != "$invocation_path" ]]; then
    echo "ERROR: deployment command ran from a different directory than the expected source" >&2
    return 1
  fi
  if [[ "$invocation_path" != "$actual_source" ]]; then
    echo "ERROR: deployment invocation directory is not the resolved Git worktree root" >&2
    return 1
  fi
  if [[ "$expected_revision" != "$actual_revision" ]]; then
    echo "ERROR: deployment source revision does not match the orchestrator's expected revision" >&2
    return 1
  fi
}
