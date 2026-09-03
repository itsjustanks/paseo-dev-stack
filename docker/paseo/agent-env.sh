# /etc/profile.d/10-devstack-agents.sh
# Sourced by interactive login shells inside the container (docker exec -it).
# Keeps agent CLIs pointed at 9router and agent-browser at its prebuilt cache.

# agent-browser: Chrome for Testing lives outside $HOME so it survives the
# /home/paseo volume mount. Do NOT export XDG_CACHE_HOME globally — Paseo uses
# it for its own cache.
export AGENT_BROWSER_CACHE="${AGENT_BROWSER_CACHE:-/opt/agent-browser-cache}"
agent-browser() { XDG_CACHE_HOME="$AGENT_BROWSER_CACHE" command agent-browser "$@"; }

# 9router: only wire up when both vars are present, so an unconfigured stack
# still falls back to each CLI's normal OAuth login.
if [ -n "${NINEROUTER_URL:-}" ] && [ -n "${NINEROUTER_KEY:-}" ]; then
  export ANTHROPIC_BASE_URL="$NINEROUTER_URL"
  export ANTHROPIC_AUTH_TOKEN="$NINEROUTER_KEY"
  unset ANTHROPIC_API_KEY 2>/dev/null || true
fi

export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
