#!/usr/bin/env bash
# Register queued Paseo plugins once the daemon is accepting commands.
#
# `paseo plugin add` talks to the RUNNING daemon, so it cannot happen in the
# entrypoint (the daemon starts after it). The entrypoint queues plugins in
# .pending-plugins; this waits for health, registers each one, and clears the
# queue. Idempotent: an already-registered plugin is skipped.
#
# It also installs the AI Router plugin when AI_ROUTER_PLUGIN_SOURCE is set
# (off by default): any `paseo plugin install` source, e.g. a directory inside
# the container or a git URL, optionally followed by :apps/paseo.
set -uo pipefail

HOME_DIR="${HOME:-/home/paseo}"
QUEUE="$HOME_DIR/.paseo/.pending-plugins"
PORT="${PASEO_LISTEN##*:}"; PORT="${PORT:-6767}"

log() { printf '[plugins] %s\n' "$*" >&2; }

AI_ROUTER_SRC="${AI_ROUTER_PLUGIN_SOURCE:-}"
[ -s "$QUEUE" ] || [ -n "$AI_ROUTER_SRC" ] || exit 0

# Wait for the daemon (up to ~90s). Without this the first add races the boot
# and fails with a connection error, leaving no plugin and no obvious reason.
for _ in $(seq 1 45); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/api/health" 2>/dev/null; then
    break
  fi
  sleep 2
done

registered="$(paseo plugin ls 2>/dev/null | awk 'NR>1{print $1}')"

[ -s "$QUEUE" ] && while IFS=$'\t' read -r dir sub; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  # The id is declared by the plugin itself; ids must match /^[a-z][a-z0-9-]*$/
  # so they cannot start with a digit.
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

# Installed once per daemon: a registered ai-router is left alone, so it never
# reinstalls on boot and a panel-side setup is never disturbed. To switch the
# source: `paseo plugin remove ai-router`, then restart the daemon.
if [ -n "$AI_ROUTER_SRC" ]; then
  if printf '%s\n' "$registered" | grep -qx ai-router; then
    log "ai-router already registered"
  elif out="$(paseo plugin install "$AI_ROUTER_SRC" </dev/null 2>&1)" \
       && ! printf '%s' "$out" | grep -qiE '^error|invalid_format'; then
    log "installed ai-router from $AI_ROUTER_SRC"
  else
    log "failed to install ai-router from $AI_ROUTER_SRC: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
fi
