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
# `|| true`: grep exits 1 when nothing matches, and under `set -e` a command
# substitution's status is the assignment's status — so a .env with no
# PASEO_PORT line killed this script silently before it printed anything.
used="$(grep -hoE '^PASEO_PORT[_0-9]*=[0-9]+' .env | cut -d= -f2 | tr '\n' ' ' || true)"
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

# ── Preflight ───────────────────────────────────────────────────────────────
# This script took a 31GB server down on 2026-09-04. Two causes, both guarded
# below:
#
#   1. BUILD  - `compose up` builds a missing image by DEFAULT. The devstack
#               image is large (5 agent CLIs, Chromium, every cloud CLI), so
#               building it WHILE the main stack holds a 28GB cgroup left the
#               host with no headroom. It swap-died: ping answered, port 22
#               accepted, but the kernel could not fork an sshd session. So we
#               never build here — the image must already exist.
#   2. BUDGET - autotune gives the MAIN container almost the whole box
#               (PASEO_MEM_LIMIT=29462m of 31GB). A second daemon can never fit
#               under that, and nothing was checking. We check now, and say
#               exactly what to lower.
IMAGE="$(grep -E '^\s*image:\s*paseo-dev-stack/agents' docker-compose.yml \
         | head -1 | sed -E 's/.*image:[[:space:]]*//')"
IMAGE="${IMAGE:-paseo-dev-stack/agents:latest}"

command -v docker >/dev/null || die "docker not found"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die \
"image '$IMAGE' does not exist yet.

  A satellite reuses the main image — this script never builds one, because
  building while the stack is running is what took a server down.

  Build it first, when the box is idle:
      make build        (or: docker compose build paseo)"

# Memory budget. mem_limit is a RESERVATION in practice: the main container will
# grow into whatever it is given, so a satellite needs real headroom beyond it.
mem_mb() {  # "29462m" | "28g" | "0" -> MB (0 = unlimited)
  local v="${1:-0}"; v="$(printf '%s' "$v" | tr 'A-Z' 'a-z' | tr -d ' ')"
  case "$v" in
    ''|0)   printf '0' ;;
    *g)     printf '%s' "$(( ${v%g} * 1024 ))" ;;
    *m)     printf '%s' "${v%m}" ;;
    *k)     printf '%s' "$(( ${v%k} / 1024 ))" ;;
    *[!0-9]*) printf '0' ;;
    *)      printf '%s' "$(( v / 1048576 ))" ;;   # bare bytes
  esac
}

TOTAL_MB=0
if [ -r /proc/meminfo ]; then
  TOTAL_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
elif command -v sysctl >/dev/null; then
  TOTAL_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
fi

if [ "$TOTAL_MB" -gt 0 ]; then
  # Everything already promised to existing containers.
  # Everything already promised, EXCLUDING the slot we are about to fill:
  # `autotune --daemons N` writes a cap for each expected slot in advance, so
  # counting our own target would make a correctly-tuned host look full.
  COMMITTED_MB=0
  RESERVED_FOR_US_MB=0
  for key in PASEO_MEM_LIMIT PASEO_MEM_LIMIT_2 PASEO_MEM_LIMIT_3 PASEO_MEM_LIMIT_4 \
             PASEO_MEM_LIMIT_5 PASEO_MEM_LIMIT_6 PASEO_MEM_LIMIT_7 PASEO_MEM_LIMIT_8 \
             PASEO_MEM_LIMIT_9; do
    val="$(grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ "$key" = "PASEO_MEM_LIMIT_${SLOT}" ]; then
      RESERVED_FOR_US_MB="$(mem_mb "$val")"
      continue
    fi
    COMMITTED_MB=$(( COMMITTED_MB + $(mem_mb "$val") ))
  done

  # A daemon that has actually served a request sits well above idle; 2GB is the
  # floor at which one is usable at all.
  NEED_MB="${DEVSTACK_DAEMON_MIN_MB:-2048}"
  # Keep the crash buffer the autotune reserves, so a wedged box can still be
  # rescued over ssh.
  RESERVE_MB="${DEVSTACK_HOST_RESERVE_MB:-1024}"
  FREE_MB=$(( TOTAL_MB - COMMITTED_MB - RESERVE_MB ))

  if [ "$COMMITTED_MB" -gt 0 ] && [ "$FREE_MB" -lt "$NEED_MB" ]; then
    die "not enough memory budget for another daemon.

  host total       ${TOTAL_MB}MB
  already capped   ${COMMITTED_MB}MB   (other PASEO_MEM_LIMIT* in .env)
  reserved slot ${SLOT}  ${RESERVED_FOR_US_MB}MB
  host reserve     ${RESERVE_MB}MB
  left over        ${FREE_MB}MB        (need >= ${NEED_MB}MB)

  The main container is sized to take almost the whole box, which is right for
  a single-tenant host and impossible for a second daemon. To run several,
  re-tune for the tenant count:

      ./scripts/autotune-memory.sh --daemons 2   # then: make up

  Override for a deliberate oversubscribe: DEVSTACK_DAEMON_MIN_MB=512"
  fi
fi

# Cap for this satellite. Prefer the reservation autotune made for the slot;
# otherwise mirror the main container, so a satellite is never less bounded
# than the daemon it sits beside. Only truly unlimited when nothing is capped.
SAT_MEM="0"
if [ "${RESERVED_FOR_US_MB:-0}" -gt 0 ]; then
  SAT_MEM="${RESERVED_FOR_US_MB}m"
else
  main_mem="$(grep -E '^PASEO_MEM_LIMIT=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  [ -n "$main_mem" ] && [ "$main_mem" != "0" ] && SAT_MEM="$main_mem"
fi

WSDIR="./workspace-${NAME}"

log "adding daemon '$NAME' on port $PORT (slot $SLOT)"
mkdir -p "$WSDIR"

# Append rather than rewrite: an existing value is never touched.
{
  printf '\n# ── daemon: %s ──\n' "$NAME"
  printf 'PASEO_NAME_%s=%s\n'    "$SLOT" "$NAME"
  printf 'PASEO_PORT_%s=%s\n'    "$SLOT" "$PORT"
  printf 'WORKSPACE_DIR_%s=%s\n' "$SLOT" "$WSDIR"
  # Inherit the tuned per-daemon cap when autotune reserved one for this slot.
  # Writing 0 (unlimited) here is what made a satellite able to eat the host:
  # it silently overrode the reservation the budget check had just approved.
  printf 'PASEO_MEM_LIMIT_%s=%s\n'     "$SLOT" "$SAT_MEM"
  printf 'PASEO_MEMSWAP_LIMIT_%s=%s\n' "$SLOT" "$SAT_MEM"
  printf 'AGENT_BROWSER_STREAM_PORT_%s=%s\n' "$SLOT" "$((9223 + SLOT))"
} >> .env

log "starting it"
# --no-build is the whole point of the preflight above: reuse the image that
# is already there, never compile one next to a running stack.
docker compose --profile satellites up -d --no-build "paseo-${SLOT}" 2>&1 | tail -4

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
