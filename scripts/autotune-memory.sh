#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Detect how much RAM this host has and size the stack to USE it.
#
# The goal is to favour the agent container aggressively — an 8GB box that only
# hands out 4GB is wasting half the machine — while keeping a small reserve so
# that when something DOES blow up, the host still has enough memory to run
# sshd/docker and let you restart things. Without that reserve an OOM takes the
# whole box down and you need a console or a hard reboot.
#
#   ./scripts/autotune-memory.sh            # show the recommendation
#   ./scripts/autotune-memory.sh --write    # apply it to .env
#
# Env overrides:
#   HOST_RESERVE_GB   memory kept for the host  (default 1)
#   SIDECAR_GB        memory kept for 9router + cloudflared (default 1)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

HOST_RESERVE_GB="${HOST_RESERVE_GB:-1}"
SIDECAR_GB="${SIDECAR_GB:-1}"
WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

# ── Detect total RAM ────────────────────────────────────────────────────────
total_kb=""
if [ -r /proc/meminfo ]; then
  total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
elif command -v sysctl >/dev/null 2>&1; then            # macOS
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo)"
  [ -n "$bytes" ] && total_kb=$(( bytes / 1024 ))
fi
[ -n "$total_kb" ] || { echo "cannot determine total RAM on this host" >&2; exit 1; }

# Integer maths only (no bc dependency); work in MiB throughout.
total_mb=$(( total_kb / 1024 ))
reserve_mb=$(( HOST_RESERVE_GB * 1024 ))
sidecar_mb=$(( SIDECAR_GB * 1024 ))

# On a small box a flat 1GB reserve is proportionally huge, and on a big box it
# is proportionally tiny. Take the LARGER of the flat reserve and 5% so the
# safety margin scales, but never less than the flat floor the user asked for.
pct_mb=$(( total_mb * 5 / 100 ))
[ "$pct_mb" -gt "$reserve_mb" ] && reserve_mb=$pct_mb

paseo_mb=$(( total_mb - reserve_mb - sidecar_mb ))

if [ "$paseo_mb" -lt 1024 ]; then
  echo "host has only ${total_mb}MB — too small to tune safely; leaving limits unset" >&2
  exit 1
fi

# V8 heap for Node inside the container. ~40% of the container cap: high enough
# for tsc/eslint/jest on a big repo, low enough that a single Node process
# cannot fill the container on its own (Turbopack allocates NATIVELY and ignores
# this, which is exactly why the container cap above exists as well).
node_heap_mb=$(( paseo_mb * 40 / 100 ))
[ "$node_heap_mb" -gt 16384 ] && node_heap_mb=16384   # past ~16GB V8 GC degrades

# devserver-guard's kill threshold: a Next dev server legitimately uses 6-11GB
# while compiling, so never drop below 12GB or it kills healthy compiles. Scale
# up on a big box, but keep it under the container cap.
guard_gb=12
cap_gb=$(( paseo_mb / 1024 ))
[ $(( cap_gb * 60 / 100 )) -gt "$guard_gb" ] && guard_gb=$(( cap_gb * 60 / 100 ))
[ "$guard_gb" -ge "$cap_gb" ] && guard_gb=$(( cap_gb - 1 ))

# Reap surplus dev servers once free memory drops below this.
min_avail_gb=$(( reserve_mb / 1024 + 2 ))

cat <<REPORT
  host total          ${total_mb} MB  ($(( total_mb / 1024 )) GB)
  host reserve        ${reserve_mb} MB   (crash headroom: ssh + docker stay alive)
  sidecars            ${sidecar_mb} MB   (9router, cloudflared)
  ──────────────────────────────────────────
  PASEO_MEM_LIMIT     ${paseo_mb}m   ($(( paseo_mb / 1024 )) GB to the agent container)
  NODE_OPTIONS        --max-old-space-size=${node_heap_mb}
  guard kill above    ${guard_gb} GB per dev server
  guard reaps below   ${min_avail_gb} GB free
REPORT

[ "$WRITE" = 1 ] || { echo; echo "run with --write to apply to .env"; exit 0; }

[ -f .env ] || { echo ".env not found — copy .env.example first" >&2; exit 1; }

# Rewrite a key in place, preserving everything else. Values here are simple
# (digits/letters/dashes) so a plain sed is safe; the general .env merge in
# scripts/update.sh handles arbitrary values.
set_key() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${k}=" .env; then
    sed "s|^${k}=.*|${k}=${v}|" .env > "$tmp"
  else
    cat .env > "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
  fi
  mv "$tmp" .env
}

set_key PASEO_MEM_LIMIT       "${paseo_mb}m"
set_key PASEO_MEMSWAP_LIMIT   "${paseo_mb}m"
set_key NODE_OPTIONS          "--max-old-space-size=${node_heap_mb}"
set_key DEVSERVER_GUARD_MAX_GB      "${guard_gb}.0"
set_key DEVSERVER_GUARD_MIN_AVAIL_GB "${min_avail_gb}.0"

echo
echo "  ✅ written to .env — apply with: make up"
