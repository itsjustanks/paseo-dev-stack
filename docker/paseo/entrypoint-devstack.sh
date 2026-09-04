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
SEED_MEM=/opt/devstack-seed-memory   # sibling mount; see docker-compose.yml

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

# Seeding is FIRST BOOT ONLY and never overwrites: seed_file returns early if
# the destination exists. Each daemon (including every satellite) has its own
# /home/paseo volume, so one daemon's Claude/Codex settings are never visible
# to another and are never replaced by the repo's defaults on a later restart.
# Set DEVSTACK_NO_SEED=1 to skip seeding entirely and start from stock defaults.
if [ "${DEVSTACK_NO_SEED:-0}" = "1" ]; then
  log "seeding disabled (DEVSTACK_NO_SEED=1)"
else
  seed_file "$SEED/claude/settings.json" "$HOME_DIR/.claude/settings.json"
  seed_file "$SEED/codex/config.toml"    "$HOME_DIR/.codex/config.toml"
fi

# ── Auto-memory ─────────────────────────────────────────────────────────────
# Claude Code's auto-memory lives at ~/.claude/projects/<slug>/memory, where
# <slug> is the cwd with non-alphanumerics replaced by '-'. Rather than depend
# on that slug (it changes with the workspace path), we pin an explicit shared
# store via the autoMemoryDirectory setting, seeded in settings.json.
MEM_DIR="$HOME_DIR/.claude/memory"
run_as_paseo mkdir -p "$MEM_DIR"
if [ -d "$SEED_MEM" ] && [ -z "$(ls -A "$MEM_DIR" 2>/dev/null)" ]; then
  if compgen -G "$SEED_MEM/*.md" > /dev/null; then
    run_as_paseo cp -n "$SEED_MEM"/*.md "$MEM_DIR"/ 2>/dev/null || true
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
# Chrome for Testing was downloaded at build time into $AGENT_HOME. agent-browser
# looks under $HOME/.agent-browser/browsers and ignores XDG_CACHE_HOME, and $HOME
# is now the volume — so link the baked copy into place rather than re-downloading
# ~150MB per container.
BAKED_AB=/opt/agent-home/.agent-browser
# agent-browser needs a WRITABLE .agent-browser (it puts its control socket
# there), so a bare symlink to the read-only baked copy fails with
# "Socket directory is not writable". Make a real directory owned by paseo and
# link only the browsers/ payload into it.
if [ ! -e "$HOME_DIR/.agent-browser" ] && [ -d "$BAKED_AB/browsers" ]; then
  run_as_paseo mkdir -p "$HOME_DIR/.agent-browser"
  run_as_paseo ln -s "$BAKED_AB/browsers" "$HOME_DIR/.agent-browser/browsers"
  log "linked prebuilt Chrome into $HOME_DIR/.agent-browser"
fi
# Anything root created under the volume (build-time installers, docker cp)
# leaves paseo unable to read its own config. Fix only the top level of $HOME
# plus the dirs we manage — a recursive chown of the whole volume would be slow
# and would rewrite user data on every boot.
if [ "$(id -u)" = "0" ]; then
  for d in "$HOME_DIR/.agent-browser" "$HOME_DIR/.fly" "$HOME_DIR/.claude" \
           "$HOME_DIR/.codex" "$HOME_DIR/.paseo" "$HOME_DIR/.config" \
           "$HOME_DIR/.npm" "$HOME_DIR/.cache" "$HOME_DIR/.local"; do
    [ -e "$d" ] && [ "$(stat -c %u "$d")" != "1000" ] && chown -R paseo:paseo "$d" || true
  done
fi
if [ -f /opt/chrome-path ]; then
  AGENT_BROWSER_EXECUTABLE_PATH="$(cat /opt/chrome-path)"
  export AGENT_BROWSER_EXECUTABLE_PATH
fi

# ── agent-browser stream bridge ─────────────────────────────────────────────
# agent-browser binds its live-view WebSocket to the container's 127.0.0.1 with
# no bind-address option, so Docker cannot publish it directly. This forwards
# 0.0.0.0:<bridge port> -> 127.0.0.1:<stream port> inside the container. The
# HOST-side port is still bound to 127.0.0.1 by compose, so nothing is public.
if [ -x /usr/local/bin/stream-bridge.py ]; then
  run_as_paseo env \
    AGENT_BROWSER_STREAM_PORT="${AGENT_BROWSER_STREAM_PORT:-9223}" \
    AGENT_BROWSER_STREAM_BRIDGE_PORT="${AGENT_BROWSER_STREAM_BRIDGE_PORT:-9224}" \
    nohup python3 /usr/local/bin/stream-bridge.py \
      >> "$HOME_DIR/.agent-browser-bridge.log" 2>&1 &
  log "stream bridge on :${AGENT_BROWSER_STREAM_BRIDGE_PORT:-9224}"
fi

# ── Shell skeleton ──────────────────────────────────────────────────────────
# /home/paseo is a VOLUME, so the .bashrc/.profile that useradd normally copies
# from /etc/skel are shadowed and absent. bash then starts with no PS1 and a
# terminal shows a bare "$" with no colours, no history, no aliases — which
# reads as a broken terminal rather than a missing dotfile.
#
# Seed the skeleton on first boot only; never overwrite a user's own file.
for skel in /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout; do
  [ -f "$skel" ] || continue
  dest="$HOME_DIR/$(basename "$skel")"
  [ -e "$dest" ] && continue
  run_as_paseo cp "$skel" "$dest"
  log "seeded $(basename "$skel")"
done

# Debian's stock .bashrc only enables a coloured prompt when it detects a
# "known good" TERM, and it sets PS1 without the host part. Append our own so
# every terminal shows user@host:cwd$ the way a normal login does. Guarded by a
# marker so a rebuild does not append it twice.
BRC="$HOME_DIR/.bashrc"
if [ -f "$BRC" ] && ! grep -q '# devstack-prompt' "$BRC" 2>/dev/null; then
  run_as_paseo tee -a "$BRC" >/dev/null <<'BASHRC'

# devstack-prompt — a readable prompt in Paseo terminals.
# Paseo may spawn bash WITHOUT -l, so this must live in .bashrc (which
# non-login interactive shells read), not .profile (which they do not).
force_color_prompt=yes
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export PATH="/usr/local/bin:${PNPM_HOME:-/usr/local/share/pnpm}/bin:${BUN_INSTALL:-/usr/local/share/bun}/bin:$HOME/.local/bin:$PATH"
BASHRC
  log "configured shell prompt"
fi

# ── Daemon defaults ─────────────────────────────────────────────────────────
# Two settings a container install needs that the daemon does not default to:
#
#   pluginsEnabled — defaults to FALSE (bootstrap.js: `config.pluginsEnabled ??
#     false`). Without it every plugin registers but sits at STATUS=disabled and
#     `paseo plugin reload` answers "Plugins are globally disabled". Since this
#     image ships a plugin, the container turns it on.
#
# Applied only when ABSENT — an explicit choice is never overwritten.
#
# NOTE: do NOT add keys the daemon's schema does not know. config.json is
# validated strictly and an unrecognised key makes EVERY paseo command fail with
# "Invalid config ... Unrecognized key", which looks like a broken daemon. There
# is no supported projectRoot/projectsRoot setting in 0.7.2 — those strings exist
# in the bundle but are not persisted-config keys. New projects therefore still
# default to $HOME; create them under /workspace explicitly (that is the bind
# mount, and the only path visible from the host).
CFG="$HOME_DIR/.paseo/config.json"
run_as_paseo mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] || run_as_paseo tee "$CFG" >/dev/null <<'JSON'
{}
JSON
run_as_paseo python3 - "$CFG" <<'PY' || log "could not apply daemon defaults"
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
changed = []
if "pluginsEnabled" not in d:
    d["pluginsEnabled"] = True; changed.append("pluginsEnabled=true")
if changed:
    tmp = p + ".tmp"
    json.dump(d, open(tmp, "w"), indent=2)
    os.replace(tmp, p)          # atomic: a crash mid-write cannot truncate it
    print("daemon defaults: " + ", ".join(changed))
PY

# ── Paseo plugins ───────────────────────────────────────────────────────────
# Plugins are vendored in the image but must be REGISTERED into ~/.paseo, which
# lives on the volume — so this runs at boot, not build.
#
# Copying the directory is NOT enough: `paseo plugin ls` stays empty and no
# provider appears. The daemon only knows about a plugin after `paseo plugin
# add`, which records it in config.json. Note the id comes from the plugin's
# own paseo-plugin.json (here: agent-link-9router) — you cannot pass --id
# "9router", because ids must match /^[a-z][a-z0-9-]*$/ and cannot start with
# a digit.
PLUGIN_SRC="${PASEO_PLUGIN_SOURCE:-/opt/paseo-plugins}"
PLUGIN_DEST="$HOME_DIR/.paseo/plugins"
if [ -d "$PLUGIN_SRC" ]; then
  run_as_paseo mkdir -p "$PLUGIN_DEST"
  for plug in "$PLUGIN_SRC"/*; do
    [ -d "$plug" ] || continue
    name="$(basename "$plug")"
    [ -e "$PLUGIN_DEST/$name" ] || run_as_paseo cp -r "$plug" "$PLUGIN_DEST/$name"
    # The plugin's code lives under apps/paseo when the repo is a monorepo.
    sub=""
    [ -f "$PLUGIN_DEST/$name/apps/paseo/paseo-plugin.json" ] && sub="apps/paseo"
    [ -f "$PLUGIN_DEST/$name/paseo-plugin.json" ] && sub="."
    if [ -z "$sub" ]; then
      log "plugin $name: no paseo-plugin.json, skipping"
      continue
    fi
    # Registration is deferred: the daemon is not up yet at this point, so we
    # leave a marker the post-start hook consumes.
    printf '%s\t%s\n' "$PLUGIN_DEST/$name" "$sub" \
      >> "$HOME_DIR/.paseo/.pending-plugins"
    log "plugin queued for registration: $name ($sub)"
  done
  run_as_paseo chown paseo:paseo "$HOME_DIR/.paseo/.pending-plugins" 2>/dev/null || true
fi


# Register queued plugins once the daemon is up. Backgrounded because
# `paseo plugin add` needs the daemon that the exec below starts.
if [ -x /usr/local/bin/register-plugins.sh ] \
   && [ -s "$HOME_DIR/.paseo/.pending-plugins" ]; then
  run_as_paseo env HOME="$HOME_DIR" PASEO_LISTEN="${PASEO_LISTEN:-0.0.0.0:6767}" \
    nohup /usr/local/bin/register-plugins.sh \
      >> "$HOME_DIR/.paseo/plugin-register.log" 2>&1 &
  log "plugin registrar started (waits for the daemon)"
fi

log "handing off to paseo entrypoint"
exec /usr/local/bin/paseo-docker-entrypoint "$@"
