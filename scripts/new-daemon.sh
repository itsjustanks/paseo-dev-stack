#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Add another Paseo daemon to this host.
#
# Each daemon is fully isolated — its own state volume (agents, credentials,
# history), its own workspace directory, its own port and its own pairing
# identity — while sharing the one 9router pool. That is what makes this usable
# for several tenants on one machine: they share the model subscriptions and
# nothing else.
#
#   ./scripts/new-daemon.sh              # interactive
#   ./scripts/new-daemon.sh acme 6770    # name and port
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

log()  { printf '\033[1;36m[daemon]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "no .env here — run install.sh or 'cp .env.example .env' first"

NAME="${1:-}"
PORT="${2:-}"

if [ -z "$NAME" ]; then
  printf 'Name for the new daemon (letters, digits, dashes): '
  read -r NAME
fi
# The name becomes a container hostname and a compose service, so keep it to
# what both accept.
printf '%s' "$NAME" | grep -qE '^[a-z][a-z0-9-]{0,30}$' \
  || die "invalid name '$NAME' — lowercase letters, digits and dashes, starting with a letter"

# Pick the next free port unless one was given.
used="$(grep -hoE '^PASEO_PORT[_0-9]*=[0-9]+' .env | cut -d= -f2 | tr '\n' ' ')"
if [ -z "$PORT" ]; then
  PORT=6768
  while printf '%s' "$used" | grep -qw "$PORT" || \
        (command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":$PORT "); do
    PORT=$((PORT + 1))
  done
fi
printf '%s' "$PORT" | grep -qE '^[0-9]{2,5}$' || die "invalid port '$PORT'"

SLOT=""
for n in 2 3 4 5 6 7 8 9; do
  if ! grep -qE "^PASEO_NAME_${n}=" .env; then SLOT="$n"; break; fi
done
[ -n "$SLOT" ] || die "all satellite slots are in use; edit docker-compose.yml to add more"

WSDIR="./workspace-${NAME}"

log "adding daemon '$NAME' on port $PORT (slot $SLOT)"
mkdir -p "$WSDIR"

# Append rather than rewrite: an existing value is never touched.
{
  printf '\n# ── daemon: %s ──\n' "$NAME"
  printf 'PASEO_NAME_%s=%s\n'    "$SLOT" "$NAME"
  printf 'PASEO_PORT_%s=%s\n'    "$SLOT" "$PORT"
  printf 'WORKSPACE_DIR_%s=%s\n' "$SLOT" "$WSDIR"
  printf 'PASEO_MEM_LIMIT_%s=0\n'     "$SLOT"
  printf 'PASEO_MEMSWAP_LIMIT_%s=0\n' "$SLOT"
  printf 'AGENT_BROWSER_STREAM_PORT_%s=%s\n' "$SLOT" "$((9224 + SLOT))"
} >> .env

log "starting it"
docker compose --profile satellites up -d "paseo-${SLOT}" 2>&1 | tail -4

cat <<BANNER

  ✅ daemon '$NAME' is up

     ui        http://127.0.0.1:${PORT}
     workspace ${WSDIR}   (on the host; /workspace inside)
     state     its own volume — separate agents, logins and history
     models    shares the one 9router pool

  Pair it:
     docker exec -it --user paseo pds-paseo-${SLOT} paseo daemon pair --relay

  Or from the panel: admin tab, select it, press p

BANNER
