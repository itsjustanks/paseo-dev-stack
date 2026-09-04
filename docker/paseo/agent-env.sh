#!/usr/bin/env bash
# shellcheck shell=bash
# /etc/profile.d/10-devstack-agents.sh
# Sourced by interactive login shells inside the container (docker exec -it).
# Keeps agent CLIs pointed at 9router and agent-browser at its prebuilt cache.

# agent-browser: Chrome for Testing lives outside $HOME so it survives the
# /home/paseo volume mount. Do NOT export XDG_CACHE_HOME globally — Paseo uses
# it for its own cache.
# Chrome for Testing is baked into the image and symlinked to
# ~/.agent-browser by the entrypoint; this pins the binary explicitly too.
if [ -f /opt/chrome-path ]; then
  AGENT_BROWSER_EXECUTABLE_PATH="$(cat /opt/chrome-path)"
  export AGENT_BROWSER_EXECUTABLE_PATH
fi

# 9router: only wire up when both vars are present, so an unconfigured stack
# still falls back to each CLI's normal OAuth login.
if [ -n "${NINEROUTER_URL:-}" ] && [ -n "${NINEROUTER_KEY:-}" ]; then
  export ANTHROPIC_BASE_URL="$NINEROUTER_URL"
  export ANTHROPIC_AUTH_TOKEN="$NINEROUTER_KEY"
  unset ANTHROPIC_API_KEY 2>/dev/null || true
fi

# pnpm refuses `add -g` unless its bin dir is on PATH; bun's too.
export PNPM_HOME="${PNPM_HOME:-/usr/local/share/pnpm}"
export BUN_INSTALL="${BUN_INSTALL:-/usr/local/share/bun}"
export PATH="/usr/local/bin:$PNPM_HOME/bin:$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"
