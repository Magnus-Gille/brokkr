# shellcheck shell=bash
# ─── Grimnir shared Munin helpers ────────────────────────────────────────────
#
# Sourceable library factoring the Munin JSON-RPC plumbing that was previously
# copy-pasted across security-scan.sh and generate-architecture.sh (flagged in
# debate/auto-ops-codex-critique.md as "duplication with nicer intent"). New
# on-Pi maintenance scripts source THIS instead of adding a divergent 4th copy.
#
# Usage:
#   source "$(dirname "$0")/lib/munin.sh"
#   munin_discover_token              # sets MUNIN_TOKEN from a service .env
#   munin_tool_call memory_write "$json_args"
#
# Honours a pre-set $MUNIN_TOKEN (e.g. from --munin-token) and a $MUNIN_URL
# override (defaults to the local MCP endpoint). Never echoes the token value.
# Compatible with bash 3.2+ (macOS default).

MUNIN_URL="${MUNIN_URL:-http://localhost:3030/mcp}"

# ─── Find the Munin bearer token from a service .env ─────────────────────────
# Mirrors security-scan.sh: walk the usual repos' .env files for MUNIN_API_KEY.
munin_discover_token() {
  local repos_dir="${1:-${REPOS_DIR:-$HOME/repos}}"
  [[ -n "${MUNIN_TOKEN:-}" ]] && return 0
  local envfile val
  for envfile in "$repos_dir/hugin/.env" "$repos_dir/ratatoskr/.env" "$repos_dir/heimdall/.env"; do
    if [[ -f "$envfile" ]]; then
      val="$(grep -E '^MUNIN_API_KEY=' "$envfile" 2>/dev/null | head -1 | cut -d= -f2-)"
      if [[ -n "$val" ]]; then
        MUNIN_TOKEN="$val"
        return 0
      fi
    fi
  done
  return 1
}

# ─── Low-level: POST a raw JSON-RPC payload, return the first SSE data line ───
munin_call() {
  local payload="$1"
  if [[ -z "${MUNIN_TOKEN:-}" ]]; then
    echo "(Munin token not available)"
    return 1
  fi
  curl -s --max-time 10 \
    -X POST "$MUNIN_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $MUNIN_TOKEN" \
    -d "$payload" 2>/dev/null | \
    sed -n 's/^data: //p' | head -1 || echo "{}"
}

# ─── High-level: call a Munin MCP tool with a JSON arguments object ───────────
munin_tool_call() {
  local tool_name="$1" args_json="$2"
  local payload
  payload=$(TOOL_NAME="$tool_name" ARGS_JSON="$args_json" node --input-type=commonjs -e '
    console.log(JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: process.env.TOOL_NAME, arguments: JSON.parse(process.env.ARGS_JSON) }
    }))
  ')
  munin_call "$payload"
}
