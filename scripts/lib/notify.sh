# shellcheck shell=bash
# ─── Grimnir shared Telegram-notify helper ───────────────────────────────────
#
# notify_telegram "message"  → pushes a one-line operator alert.
#
# Preferred path, only when RATATOSKR_URL is explicitly configured: the
# Ratatoskr bot's /api/send endpoint, reached over the
# tailnet with a Bearer key — works from any trusted tailnet host without
# interactive SSH authentication:
#   POST http://control-node:3034/api/send  {chat_id:<number>, text:<string>}
#   Authorization: Bearer <RATATOSKR_SEND_API_KEY>
# Falls back to the direct Telegram Bot API when its token is explicitly configured.
# With neither destination configured, notification is a local no-op.
#
# Config sources, in precedence order (per value):
#   1. environment ($RATATOSKR_URL, $RATATOSKR_SEND_API_KEY,
#      $TELEGRAM_ALLOWED_USERS, $TELEGRAM_BOT_TOKEN)
#   2. the Ratatoskr .env       ($RATATOSKR_ENV — present on the Pi)
#   3. a fleet secrets file      ($NOTIFY_ENV, ~/.config/grimnir/notify.env) for
#      off-box hosts (e.g. laptop) that have no Ratatoskr .env — see
#      scripts/lib/notify.env.example and ratatoskr/docs/remote-send.md.
#
# The Bearer key and bot token are passed via curl --config (stdin) so neither
# credential ever appears in the process argv (ps) — the message body itself is
# on the command line via -d. Config files are read with grep, never sourced.
# Best-effort by design: a notify failure NEVER fails the calling script (callers
# such as maintenance-report.sh run under `set -euo pipefail`). bash 3.2+.

RATATOSKR_ENV="${RATATOSKR_ENV:-$HOME/repos/ratatoskr/.env}"
NOTIFY_ENV="${NOTIFY_ENV:-$HOME/.config/grimnir/notify.env}"

# JSON-escape an arbitrary string into a quoted JSON string literal.
_notify_json_string() {
  MSG="$1" node --input-type=commonjs -e 'process.stdout.write(JSON.stringify(process.env.MSG||""))'
}

# Read VAR= from a config file (grep only — never sources the file).
# $1 = config file path, $2 = variable name. Prints the value (may be empty).
# Strips wrapping double-quotes and any CR so a CRLF-saved file still parses.
_notify_cfg_get() {
  [[ -f "$1" ]] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"\r'
}

notify_telegram() {
  local msg="$1"
  [[ -z "$msg" ]] && return 0

  # Choose the config file: prefer the Ratatoskr .env (Pi), else the fleet file.
  local cfg=""
  if [[ -f "$RATATOSKR_ENV" ]]; then
    cfg="$RATATOSKR_ENV"
  elif [[ -f "$NOTIFY_ENV" ]]; then
    cfg="$NOTIFY_ENV"
  fi

  # Resolve each value: environment wins, else the chosen config file.
  local url send_key chat_id bot_token
  url="${RATATOSKR_URL:-$(_notify_cfg_get "$cfg" RATATOSKR_URL)}"
  send_key="${RATATOSKR_SEND_API_KEY:-$(_notify_cfg_get "$cfg" RATATOSKR_SEND_API_KEY)}"
  # A newline in the key would terminate the curl --config header line and let a
  # malformed key inject a second directive — strip CR/LF defensively.
  send_key="${send_key//$'\n'/}"
  send_key="${send_key//$'\r'/}"
  chat_id="${TELEGRAM_ALLOWED_USERS:-$(_notify_cfg_get "$cfg" TELEGRAM_ALLOWED_USERS)}"
  chat_id="${chat_id%%,*}"   # first allowed user if comma-separated
  bot_token="${TELEGRAM_BOT_TOKEN:-$(_notify_cfg_get "$cfg" TELEGRAM_BOT_TOKEN)}"

  if [[ -z "$chat_id" ]]; then
    echo "  notify: no Telegram chat id available — skipping alert" >&2
    return 0
  fi
  if [[ ! "$chat_id" =~ ^-?[0-9]+$ ]]; then
    echo "  notify: TELEGRAM_ALLOWED_USERS first entry '$chat_id' is not numeric — skipping alert" >&2
    return 0
  fi

  # `|| text_json='""'` keeps the contract: if node is missing/crashes, the
  # assignment still exits 0 (no set -e abort in the caller) and the empty JSON
  # string forces a non-200, falling through to the node-free direct-API path.
  local text_json
  text_json="$(_notify_json_string "$msg")" || text_json='""'

  # Preferred: Ratatoskr endpoint. The Bearer header (if any) goes via curl
  # --config (stdin) so the key never lands in argv. chat_id MUST be an unquoted
  # JSON number; text_json is a pre-escaped JSON string literal.
  local code="not-configured"
  if [[ -n "$url" ]]; then
    local auth_cfg=""
    [[ -n "$send_key" ]] && auth_cfg="header = \"Authorization: Bearer ${send_key}\""
    code="$(printf '%s\n' "$auth_cfg" | curl -sS -m 8 -o /dev/null -w '%{http_code}' --config - \
         -X POST "$url" \
         -H "Content-Type: application/json" \
         -d "{\"chat_id\": ${chat_id}, \"text\": ${text_json}}" 2>/dev/null || echo 000)"
  fi
  if [[ "$code" == "200" ]]; then
    return 0
  fi

  # Fallback: direct Telegram Bot API. Pass the token-bearing URL via curl's
  # --config (stdin) so the bot token never appears in the process argv (ps).
  if [[ -n "$bot_token" ]]; then
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$bot_token" | \
    curl -sS -m 8 -o /dev/null --config - \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${msg}" 2>/dev/null || true
  else
    if [[ -n "$url" ]]; then
      echo "  notify: Ratatoskr unreachable (HTTP ${code}) and no bot token for fallback" >&2
    else
      echo "  notify: no Ratatoskr URL or direct bot token configured — skipping alert" >&2
    fi
  fi
  return 0
}
