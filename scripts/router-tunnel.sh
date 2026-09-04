#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Expose the 9router dashboard temporarily, so you can connect accounts to it
# from a browser on another machine.
#
# 9router binds to 127.0.0.1 on the host by design — it holds your model
# subscriptions, so it must never be published. This opens a THROWAWAY
# Cloudflare quick tunnel to it for as long as the command runs, and closes it
# the moment you press ctrl-C.
#
#   ./scripts/router-tunnel.sh [port]
#
# ⚠ A quick tunnel has NO AUTHENTICATION. Anyone with the URL reaches the
#   dashboard, which is why this is foreground-only and dies with your shell.
#   For anything lasting, put a named tunnel behind Cloudflare Access instead.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

PORT="${1:-}"
if [ -z "$PORT" ]; then
  PORT="$(grep -E '^NINEROUTER_PORT=' .env 2>/dev/null | cut -d= -f2 | head -1)"
  PORT="${PORT:-20128}"
fi

DASH="http://127.0.0.1:${PORT}/dashboard"
PW="$(grep -E '^NINEROUTER_PASSWORD=' .env 2>/dev/null | cut -d= -f2- | head -1 || true)"

if ! curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${PORT}/api/health"; then
  echo "9router is not answering on 127.0.0.1:${PORT} — is the stack up?" >&2
  exit 1
fi

cat <<INTRO

  9router dashboard

    locally      ${DASH}
    password     ${PW:-<see NINEROUTER_PASSWORD in .env>}

  Opening a temporary public tunnel. It has NO authentication and closes when
  you press ctrl-C. Use it to connect accounts, then close it.

INTRO

# Run cloudflared from the image already present, on the compose network, so it
# reaches 9router by service name rather than needing a published port.
exec docker compose run --rm --no-deps \
  --entrypoint cloudflared cloudflared-quick \
  tunnel --no-autoupdate --url "http://9router:20128"
