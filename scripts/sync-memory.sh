#!/usr/bin/env bash
# Sync Claude Code auto-memory between this repo (./memory) and the running
# container's live store (/home/paseo/.claude/memory).
#
# Auto-memory is machine-local by design: plain .md files plus a MEMORY.md
# index, no database or cache. That makes it trivially portable — this script
# is just a careful copy in either direction.
#
#   ./scripts/sync-memory.sh push   # repo  -> container
#   ./scripts/sync-memory.sh pull   # container -> repo
set -euo pipefail

cd "$(dirname "$0")/.."
SVC=paseo
CONTAINER_MEM=/home/paseo/.claude/memory
REPO_MEM=./memory
DC="docker compose"

cid="$($DC ps -q "$SVC" 2>/dev/null || true)"
[ -n "$cid" ] || { echo "container not running — 'make up' first" >&2; exit 1; }

case "${1:-}" in
  push)
    shopt -s nullglob
    files=("$REPO_MEM"/*.md)
    [ ${#files[@]} -gt 0 ] || { echo "no .md files in $REPO_MEM"; exit 0; }
    docker exec -u paseo "$cid" mkdir -p "$CONTAINER_MEM"
    for f in "${files[@]}"; do
      docker cp "$f" "$cid:$CONTAINER_MEM/$(basename "$f")"
      echo "  → $(basename "$f")"
    done
    # docker cp writes as root even with -u on exec; fix ownership or Claude
    # Code cannot read its own memory.
    docker exec -u root "$cid" chown -R paseo:paseo "$CONTAINER_MEM"
    echo "pushed ${#files[@]} file(s) to $CONTAINER_MEM"
    ;;
  pull)
    mkdir -p "$REPO_MEM"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    docker cp "$cid:$CONTAINER_MEM/." "$tmp/" 2>/dev/null || {
      echo "no memory store in the container yet"; exit 0; }
    n=0
    for f in "$tmp"/*.md; do [ -e "$f" ] || continue; cp "$f" "$REPO_MEM/"; n=$((n+1)); done
    echo "pulled $n file(s) into $REPO_MEM"
    ;;
  *) echo "usage: $0 {push|pull}" >&2; exit 2 ;;
esac
