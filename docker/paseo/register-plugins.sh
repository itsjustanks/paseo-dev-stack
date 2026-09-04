#!/usr/bin/env bash
# Register queued Paseo plugins once the daemon is accepting commands.
#
# `paseo plugin add` talks to the RUNNING daemon, so it cannot happen in the
# entrypoint (the daemon starts after it). The entrypoint queues plugins in
# .pending-plugins; this waits for health, registers each one, and clears the
# queue. Idempotent: an already-registered plugin is skipped.
set -uo pipefail

HOME_DIR="${HOME:-/home/paseo}"
QUEUE="$HOME_DIR/.paseo/.pending-plugins"
PORT="${PASEO_LISTEN##*:}"; PORT="${PORT:-6767}"

log() { printf '[plugins] %s\n' "$*" >&2; }

[ -s "$QUEUE" ] || exit 0

# Wait for the daemon (up to ~90s). Without this the first add races the boot
# and fails with a connection error, leaving no plugin and no obvious reason.
for _ in $(seq 1 45); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/api/health" 2>/dev/null; then
    break
  fi
  sleep 2
done

registered="$(paseo plugin ls 2>/dev/null | awk 'NR>1{print $1}')"

while IFS=$'\t' read -r dir sub; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  # The id is declared by the plugin itself; ids must match /^[a-z][a-z0-9-]*$/
  # so they cannot start with a digit (a plain "9router" is rejected).
  id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$dir/$sub/paseo-plugin.json" 2>/dev/null | head -1)"
  if [ -n "$id" ] && printf '%s\n' "$registered" | grep -qx "$id"; then
    log "$id already registered"
    continue
  fi
  if [ "$sub" = "." ]; then
    out="$(paseo plugin add "$dir" 2>&1)"
  else
    out="$(paseo plugin add "$dir" --path "$sub" 2>&1)"
  fi
  if printf '%s' "$out" | grep -qiE '^error|invalid_format'; then
    log "failed to register ${id:-$dir}: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  else
    log "registered ${id:-$dir}"
  fi
done < "$QUEUE"

rm -f "$QUEUE"
