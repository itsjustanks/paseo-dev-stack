#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Wire the agent CLIs through 9router.
#
#   ./scripts/router-connect.sh status     # what is routed right now
#   ./scripts/router-connect.sh key        # mint an API key non-interactively
#   ./scripts/router-connect.sh on         # route claude + codex through it
#   ./scripts/router-connect.sh off        # back to each CLI's own login
#
# WHAT 9ROUTER ACTUALLY DOES — and its limits:
#   It is an OpenAI/Anthropic-compatible proxy holding several subscriptions,
#   tracking each one's quota and falling back when one runs out.
#   * Claude Code   -> ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN   (native)
#   * Codex         -> a [model_providers] block in config.toml    (native)
#   * Kimi / Cursor -> NOT routable this way. They speak their own vendor
#     protocols and have no base-URL override, so they keep their own logins.
#   Any NEW agent you add is routable only if it accepts a custom base URL.
#
# Routing subscription OAuth through a proxy is outside Anthropic's and
# OpenAI's consumer terms. This is your call to make knowingly.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."
DC="docker compose"

env_get() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | head -1; }
env_set() {
  local k="$1" v="$2" tmp; tmp="$(mktemp)"
  if grep -qE "^${k}=" .env; then
    # Value may contain '/', ':' and '-', so use a delimiter that cannot appear.
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="}
      $1==k {print k "=" v; found=1; next} {print}
      END{if(!found) print k "=" v}' .env > "$tmp"
  else
    cat .env > "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
  fi
  mv "$tmp" .env
}

URL="$(env_get NINEROUTER_URL)"; URL="${URL:-http://9router:20128}"
PORT="$(env_get NINEROUTER_PORT)"; PORT="${PORT:-20128}"
PW="$(env_get NINEROUTER_PASSWORD)"

case "${1:-status}" in

status)
  echo "── 9router ──"
  code="$($DC exec -T --user paseo paseo bash -lc \
    "curl -s -o /dev/null -w '%{http_code}' $URL/api/health" 2>/dev/null || echo 000)"
  [ "$code" = 200 ] && echo "  reachable at $URL" \
                    || echo "  NOT reachable at $URL (http $code)"
  key="$(env_get NINEROUTER_KEY)"
  [ -n "$key" ] && echo "  api key: set (${key:0:12}…)" || echo "  api key: not set"
  echo
  echo "── routed CLIs ──"
  $DC exec -T --user paseo paseo bash -lc '
    if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
      echo "  claude  -> $ANTHROPIC_BASE_URL"
    else echo "  claude  -> direct (own login)"; fi
    if grep -q "^model_provider *= *\"9router\"" ~/.codex/config.toml 2>/dev/null; then
      echo "  codex   -> 9router"
    else echo "  codex   -> direct (own login)"; fi
    echo "  kimi    -> direct (no base-URL override exists)"
    echo "  cursor  -> direct (no base-URL override exists)"'
  echo
  echo "  dashboard: http://127.0.0.1:${PORT}/dashboard"
  ;;

key)
  [ -n "$PW" ] || { echo "NINEROUTER_PASSWORD is not set in .env" >&2; exit 1; }
  echo "minting an API key…"
  # Two steps: login sets a JWT cookie, then POST /api/keys with it.
  # NOTE: with the DEFAULT password, 9router refuses remote logins entirely —
  # it must be changed (or set via INITIAL_PASSWORD) before this works.
  key="$($DC exec -T --user paseo paseo bash -lc "
    set -e
    jar=\$(mktemp)
    curl -s -c \"\$jar\" -X POST '$URL/api/auth/login' \
      -H 'Content-Type: application/json' \
      -d '{\"password\":\"$PW\"}' > /tmp/login.json
    grep -q '\"success\":true' /tmp/login.json || { cat /tmp/login.json; exit 1; }
    curl -s -b \"\$jar\" -X POST '$URL/api/keys' \
      -H 'Content-Type: application/json' \
      -d '{\"name\":\"paseo-dev-stack\"}' \
      | sed -n 's/.*\"key\":\"\([^\"]*\)\".*/\1/p'" 2>&1 | tail -1)"
  case "$key" in
    sk-*) env_set NINEROUTER_KEY "$key"
          echo "  key saved to .env: ${key:0:12}…"
          echo "  now run: ./scripts/router-connect.sh on" ;;
    *)    echo "  failed to mint a key. Response: $key" >&2
          echo "  Open http://127.0.0.1:${PORT}/dashboard and check the password." >&2
          exit 1 ;;
  esac
  ;;

on)
  key="$(env_get NINEROUTER_KEY)"
  [ -n "$key" ] || { echo "no NINEROUTER_KEY — run: $0 key" >&2; exit 1; }
  # Claude reads these from the environment, so compose passes them in and the
  # entrypoint exports them. Codex needs a config file instead.
  $DC exec -T --user paseo paseo bash -lc "
    set -e
    mkdir -p ~/.codex
    cfg=~/.codex/config.toml
    grep -q '^\[model_providers.9router\]' \$cfg 2>/dev/null || cat >> \$cfg <<'TOML'

model_provider = \"9router\"

[model_providers.9router]
name     = \"9router\"
base_url = \"$URL/v1\"
env_key  = \"NINEROUTER_KEY\"
wire_api = \"responses\"
TOML
    echo '  codex config written'"
  echo "  claude routed via ANTHROPIC_BASE_URL (already in compose env)"
  echo
  echo "  restart to apply: make restart"
  ;;

off)
  $DC exec -T --user paseo paseo bash -lc "
    cfg=~/.codex/config.toml
    [ -f \$cfg ] && sed -i '/^model_provider *= *\"9router\"/d' \$cfg || true
    echo '  codex unrouted'"
  env_set NINEROUTER_KEY ""
  echo "  cleared NINEROUTER_KEY (claude falls back to its own login)"
  echo "  restart to apply: make restart"
  ;;

*) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
