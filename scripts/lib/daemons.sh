#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# daemons — the Paseo daemons on this host that are running right now.
#
# Sourceable:  . scripts/lib/daemons.sh   →  running_daemons
#
# Prints one compose service per line: `paseo` first, then any running
# satellite (paseo-2 … paseo-9). Tunnels and anything else are left out.
# --profile satellites is what makes compose list the satellites at all; it
# starts nothing here, `ps` only reads.
#
# Callers run commands in each with:
#     $DC exec -T --user paseo "$svc" …      where DC="docker compose --profile satellites"
# ─────────────────────────────────────────────────────────────────────────────

running_daemons() {
  docker compose --profile satellites ps --format '{{.Service}}' 2>/dev/null \
    | grep -E '^paseo(-[0-9]+)?$' \
    | sort -t- -k2,2n -u || true
}
