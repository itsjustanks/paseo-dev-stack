#!/usr/bin/env bash
# shellcheck shell=bash
# /etc/profile.d/10-devstack-agents.sh
# Sourced by interactive login shells inside the container (docker exec -it).
# Points agent-browser at its baked Chrome and puts the global bins on PATH.

# agent-browser: Chrome for Testing lives outside $HOME so it survives the
# /home/paseo volume mount. Do NOT export XDG_CACHE_HOME globally — Paseo uses
# it for its own cache.
# Chrome for Testing is baked into the image and symlinked to
# ~/.agent-browser by the entrypoint; this pins the binary explicitly too.
if [ -f /opt/chrome-path ]; then
  AGENT_BROWSER_EXECUTABLE_PATH="$(cat /opt/chrome-path)"
  export AGENT_BROWSER_EXECUTABLE_PATH
fi

# pnpm refuses `add -g` unless its bin dir is on PATH; bun's too.
export PNPM_HOME="${PNPM_HOME:-/usr/local/share/pnpm}"
export BUN_INSTALL="${BUN_INSTALL:-/usr/local/share/bun}"
export PATH="/usr/local/bin:$PNPM_HOME/bin:$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"
