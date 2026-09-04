#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Route the agent CLIs through 9router — using 9router's OWN API.
#
#   ./scripts/router-connect.sh status   # what is routed right now
#   ./scripts/router-connect.sh key      # mint an API key into .env
#   ./scripts/router-connect.sh on       # route claude + codex
#   ./scripts/router-connect.sh off      # unroute
#
# IMPORTANT — why this does not edit config files itself:
# 9router already owns CLI wiring. Its /api/cli-tools/* endpoints write
# ~/.claude/settings.json (env.ANTHROPIC_BASE_URL) and ~/.codex/config.toml
# ([model_providers.9router] + model_provider) and can cleanly remove both
# again. Hand-editing those files duplicates that logic and fights it — the
# next dashboard action would overwrite our edits, or ours would strand a
# half-written config it no longer recognises. So this script is a thin client
# for 9router's API, nothing more.
#
# Scope: 9router adds ITSELF as an extra provider. Paseo's own preloaded agent
# providers (claude, codex, …) keep behaving exactly as they do — routing is
# opt-in per CLI and fully reversible with `off`.
#
# Note: routing subscription OAuth through a proxy is outside Anthropic's and
# OpenAI's consumer terms. That is your call to make knowingly.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
DC="docker compose"
SVC=paseo

env_get() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | head -1; }
env_set() {
  local k="$1" v="$2" tmp; tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    BEGIN{done=0}
    { if (index($0, k "=") == 1) { print k "=" v; done=1 } else print }
    END{ if(!done) print k "=" v }' .env > "$tmp"
  mv "$tmp" .env
}

URL="$(env_get NINEROUTER_URL)";  URL="${URL:-http://9router:20128}"
PORT="$(env_get NINEROUTER_PORT)"; PORT="${PORT:-20128}"
PW="$(env_get NINEROUTER_PASSWORD)"

# Every management endpoint needs the JWT cookie from /api/auth/login.
# NOTE: with the DEFAULT password 9router refuses REMOTE logins outright — it
# must be changed (or set via INITIAL_PASSWORD) before any of this works.
in_container() { $DC exec -T --user paseo "$SVC" bash -lc "$1"; }

api() {   # api <METHOD> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local data=""
  [ -n "$body" ] && data="-d '$body'"
  in_container "
    set -e
    jar=\$(mktemp)
    curl -s -c \"\$jar\" -X POST '$URL/api/auth/login' \
      -H 'Content-Type: application/json' -d '{\"password\":\"$PW\"}' \
      | grep -q '\"success\":true' || { echo '__AUTH_FAILED__'; exit 0; }
    curl -s -b \"\$jar\" -X $method '$URL$path' \
      -H 'Content-Type: application/json' $data"
}

need_pw() {
  [ -n "$PW" ] || { echo "NINEROUTER_PASSWORD is not set in .env" >&2; exit 1; }
}

case "${1:-status}" in

status)
  echo "── 9router ──"
  code="$(in_container "curl -s -o /dev/null -w '%{http_code}' $URL/api/health" 2>/dev/null || echo 000)"
  [ "$code" = 200 ] && echo "  reachable at $URL" || echo "  NOT reachable ($code)"
  key="$(env_get NINEROUTER_KEY)"
  [ -n "$key" ] && echo "  api key: set (${key:0:12}…)" || echo "  api key: not set"

  echo
  echo "── routed CLIs (as reported by 9router) ──"
  if [ -n "$PW" ]; then
    for cli in claude codex; do
      r="$(api GET "/api/cli-tools/${cli}-settings" 2>/dev/null || true)"
      case "$r" in
        *__AUTH_FAILED__*) echo "  $cli   -> (login failed — check NINEROUTER_PASSWORD)" ;;
        *'"configured":true'*|*'"has9Router":true'*|*'"enabled":true'*)
                           echo "  $cli   -> 9router" ;;
        *)                 echo "  $cli   -> direct (own login)" ;;
      esac
    done
  else
    echo "  (set NINEROUTER_PASSWORD in .env to query)"
  fi
  echo "  kimi    -> direct (no base-URL override exists)"
  echo "  cursor  -> direct (no base-URL override exists)"
  echo
  echo "  Paseo's own providers are untouched by any of this."
  echo "  dashboard: http://127.0.0.1:${PORT}/dashboard"
  ;;

key)
  need_pw
  echo "minting an API key…"
  key="$(api POST /api/keys '{"name":"paseo-dev-stack"}' 2>&1 \
         | sed -n 's/.*"key":"\([^"]*\)".*/\1/p' | tail -1)"
  case "$key" in
    sk-*) env_set NINEROUTER_KEY "$key"
          echo "  saved to .env: ${key:0:12}…"
          echo "  next: ./scripts/router-connect.sh on" ;;
    *)    echo "  failed to mint a key." >&2
          echo "  Open http://127.0.0.1:${PORT}/dashboard — with the DEFAULT" >&2
          echo "  password, 9router refuses remote logins until you change it." >&2
          exit 1 ;;
  esac
  ;;

on)
  need_pw
  key="$(env_get NINEROUTER_KEY)"
  [ -n "$key" ] || { echo "no NINEROUTER_KEY — run: $0 key" >&2; exit 1; }
  # Let 9router write each CLI's config. It normalises the base URL (adds /v1
  # for Claude), merges rather than clobbers existing settings, and records
  # enough state to undo itself later.
  echo "asking 9router to route claude…"
  api POST /api/cli-tools/claude-settings \
    "{\"env\":{\"ANTHROPIC_BASE_URL\":\"$URL\",\"ANTHROPIC_AUTH_TOKEN\":\"$key\"}}" \
    | head -c 200; echo
  echo "asking 9router to route codex…"
  api POST /api/cli-tools/codex-settings \
    "{\"baseUrl\":\"$URL/v1\",\"apiKey\":\"$key\"}" | head -c 200; echo
  echo
  echo "  done — restart to pick up the new config: make restart"
  ;;

off)
  need_pw
  echo "asking 9router to unroute claude…"; api DELETE /api/cli-tools/claude-settings | head -c 200; echo
  echo "asking 9router to unroute codex…";  api DELETE /api/cli-tools/codex-settings  | head -c 200; echo
  echo
  echo "  each CLI is back on its own login. Restart: make restart"
  ;;

*) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
