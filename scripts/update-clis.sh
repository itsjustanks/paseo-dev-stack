#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Update Paseo and the agent CLIs in place, in a way a recreate cannot undo.
#
#   ./scripts/update-clis.sh                 # the default set below
#   ./scripts/update-clis.sh <pkg@ver>...    # something else
#
# WHY NOT `npm install -g --prefix /usr/local`: that writes into the
# container's own layer, which `compose down`/`up` throws away — and the
# systemd unit does exactly that on every reboot. The CLIs then silently roll
# back to the image's versions. /opt/npm-global is a host directory
# (./global-packages) mounted into EVERY daemon and first on PATH, so one
# install there updates them all and survives recreates, rebuilds and updates.
#
# The daemon itself is started from a path, not from PATH; the entrypoint
# switches it to the /opt/npm-global server when that one is newer. So each
# daemon then gets:
#   - `paseo daemon restart` when it already runs from /opt/npm-global, or
#   - a container restart the first time, so the entrypoint can switch it.
# One daemon at a time, waiting for each to answer before the next. Agents
# running in a daemon are interrupted while it restarts.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/daemons.sh
. scripts/lib/daemons.sh
DC="docker compose --profile satellites"
NPM_GLOBAL=/opt/npm-global

log() { printf '\033[1;36m[clis]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

if [ $# -gt 0 ]; then PKGS="$*"
else PKGS="@getpaseo/cli@latest @getpaseo/server@latest @anthropic-ai/claude-code@latest @openai/codex@latest"; fi

daemons="$(running_daemons)"
[ -n "$daemons" ] || die "no Paseo daemon is running — 'make up' first"
first="$(printf '%s\n' "$daemons" | head -1)"

# ── Install once ────────────────────────────────────────────────────────────
# As paseo, never root: root-owned files in the shared mount are the next
# `npm i -g` failing with EACCES. --prefix is explicit so a stray npmrc cannot
# send it back to /usr/local.
log "installing into $NPM_GLOBAL (shared by every daemon): $PKGS"
if ! $DC exec -T --user paseo "$first" bash -lc \
     "npm install -g --prefix $NPM_GLOBAL --no-audit --no-fund $PKGS" 2>&1 \
     | tail -15 | sed 's/^/    /'; then
  die "npm install failed; nothing was restarted"
fi

# ── Restart each daemon ─────────────────────────────────────────────────────
wait_healthy() {
  local svc="$1"
  for _ in $(seq 1 60); do
    $DC exec -T "$svc" curl -fsS -o /dev/null http://127.0.0.1:6767/api/health \
      >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

for svc in $daemons; do
  entry="$($DC exec -T "$svc" cat /etc/paseo-server-entry 2>/dev/null | tr -d '\r' || true)"
  case "$entry" in
    "$NPM_GLOBAL"/*)
      log "$svc: restarting the daemon worker"
      $DC exec -T --user paseo "$svc" paseo daemon restart >/dev/null \
        || die "$svc: paseo daemon restart failed; later daemons were not touched" ;;
    *)
      log "$svc: restarting the container (first switch to $NPM_GLOBAL)"
      $DC restart "$svc" >/dev/null \
        || die "$svc: restart failed; later daemons were not touched" ;;
  esac
  wait_healthy "$svc" || die "$svc did not come back healthy; later daemons were not touched"
  now="$($DC exec -T "$svc" cat /etc/paseo-server-entry 2>/dev/null | tr -d '\r' || true)"
  log "$svc: healthy — server ${now:-?}"
done

echo
$DC exec -T --user paseo "$first" bash -lc \
  'for c in paseo claude codex; do printf "  %-8s %s  (%s)\n" "$c" "$($c --version 2>/dev/null | head -1)" "$(command -v $c)"; done' || true
