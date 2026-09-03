#!/usr/bin/env bash
# devstack entrypoint — runs as root, seeds the /home/paseo volume on first
# boot, then hands off to the base Paseo entrypoint (which drops to `paseo`).
#
# Everything here is idempotent: the volume survives restarts, and we must
# never clobber credentials the user has already authenticated.
set -euo pipefail

log() { printf '[devstack] %s\n' "$*" >&2; }

HOME_DIR=/home/paseo
SEED=/opt/devstack-seed

# ── Ownership ───────────────────────────────────────────────────────────────
# A named volume starts empty and root-owned; a bind mount may carry host uids.
# Paseo cannot read its own state if this is wrong — the #1 cause of a
# container that boots but shows an empty workspace list.
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$HOME_DIR" /workspace
  if [ "$(stat -c %u "$HOME_DIR")" != "1000" ]; then
    log "chown $HOME_DIR -> paseo:paseo (first boot)"
    chown paseo:paseo "$HOME_DIR"
  fi
  # /workspace is usually a bind mount of host code. Only fix the mountpoint
  # itself; a recursive chown of a large repo is slow and rewrites host files.
  [ "$(stat -c %u /workspace)" != "1000" ] && chown paseo:paseo /workspace || true
fi

run_as_paseo() { if [ "$(id -u)" = "0" ]; then gosu paseo "$@"; else "$@"; fi; }

# ── Seed config (never overwrite) ───────────────────────────────────────────
seed_file() {
  local src="$1" dest="$2"
  [ -f "$src" ] || return 0
  if [ -e "$dest" ]; then log "keep existing $dest"; return 0; fi
  run_as_paseo mkdir -p "$(dirname "$dest")"
  run_as_paseo cp "$src" "$dest"
  log "seeded $dest"
}

seed_file "$SEED/claude/settings.json" "$HOME_DIR/.claude/settings.json"
seed_file "$SEED/codex/config.toml"    "$HOME_DIR/.codex/config.toml"

# ── Auto-memory ─────────────────────────────────────────────────────────────
# Claude Code's auto-memory lives at ~/.claude/projects/<slug>/memory, where
# <slug> is the cwd with non-alphanumerics replaced by '-'. Rather than depend
# on that slug (it changes with the workspace path), we pin an explicit shared
# store via the autoMemoryDirectory setting, seeded in settings.json.
MEM_DIR="$HOME_DIR/.claude/memory"
run_as_paseo mkdir -p "$MEM_DIR"
if [ -d "$SEED/memory" ] && [ -z "$(ls -A "$MEM_DIR" 2>/dev/null)" ]; then
  if compgen -G "$SEED/memory/*.md" > /dev/null; then
    run_as_paseo cp -n "$SEED"/memory/*.md "$MEM_DIR"/ 2>/dev/null || true
    log "seeded auto-memory ($(ls -1 "$MEM_DIR"/*.md 2>/dev/null | wc -l) files)"
  fi
fi
[ -f "$MEM_DIR/MEMORY.md" ] || run_as_paseo tee "$MEM_DIR/MEMORY.md" >/dev/null <<'MEMEOF'
<!-- Auto-memory index. One line per memory: - [Title](file.md) — hook -->
MEMEOF

# ── 9router wiring ──────────────────────────────────────────────────────────
# Point the agent CLIs at 9router when it is configured. We only export what
# is actually set, so an unconfigured stack falls back to normal OAuth login.
if [ -n "${NINEROUTER_URL:-}" ] && [ -n "${NINEROUTER_KEY:-}" ]; then
  log "9router: $NINEROUTER_URL"
  export ANTHROPIC_BASE_URL="$NINEROUTER_URL"
  export ANTHROPIC_AUTH_TOKEN="$NINEROUTER_KEY"
  unset ANTHROPIC_API_KEY || true
fi

# ── agent-browser ───────────────────────────────────────────────────────────
# Chrome for Testing was cached at build time outside $HOME; point the CLI at
# that cache without clobbering Paseo's own XDG_CACHE_HOME.
export AGENT_BROWSER_CACHE="${AGENT_BROWSER_CACHE:-/opt/agent-browser-cache}"

log "handing off to paseo entrypoint"
exec /usr/local/bin/paseo-docker-entrypoint "$@"
