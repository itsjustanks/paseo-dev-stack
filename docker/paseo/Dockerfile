# syntax=docker/dockerfile:1
#
# devstack agent image — Paseo + coding-agent CLIs + headless agent-browser.
#
# Base: ghcr.io/getpaseo/paseo:latest  (Debian 12 bookworm, Node 22 tarball at
# /usr/local/bin, user paseo uid/gid 1000, tini+gosu entrypoint, /workspace cwd)
#
# ── The trap that shapes this file ──────────────────────────────────────────
# The base image declares VOLUME /home/paseo. Every agent installer (claude,
# codex, kimi, cursor) writes into $HOME by default, so anything installed
# there at BUILD time is masked the moment the volume mounts — the CLIs would
# silently vanish at runtime.
#
# Fix: build with HOME=/opt/agent-home (a real image path, outside the volume)
# and symlink binaries into /usr/local/bin. At runtime HOME is /home/paseo
# again and carries only credentials + config, which is what we want persisted.
# ─────────────────────────────────────────────────────────────────────────────

FROM ghcr.io/getpaseo/paseo:latest

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    AGENT_HOME=/opt/agent-home \
    DO_NOT_TRACK=1 \
    npm_config_update_notifier=false

# ── System packages ─────────────────────────────────────────────────────────
# Package names are bookworm-correct: NOT the Ubuntu 24.04 *t64 variants
# (libasound2t64 etc. do not exist here and would fail the build).
# Chromium libs are listed explicitly rather than relying on
# `agent-browser install --with-deps`, which wants an interactive apt.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg unzip zip xz-utils jq ripgrep \
      git openssh-client rsync less procps htop sudo vim-tiny \
      build-essential pkg-config \
      python3 python3-pip python3-venv pipx \
      libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
      libdrm2 libxkbcommon0 libatspi2.0-0 libxcomposite1 libxdamage1 \
      libxfixes3 libxrandr2 libgbm1 libasound2 libpango-1.0-0 libcairo2 \
      libx11-6 libxcb1 libxext6 libxi6 libglib2.0-0 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# NOTE: Node 22 already ships in the base image at /usr/local/bin (tarball, not
# dpkg). We deliberately do NOT install nodesource — it would collide.

# ── uv — fast Python package/venv manager ───────────────────────────────────
RUN curl -fsSL https://astral.sh/uv/install.sh | \
      env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    && uv --version

# ── Supabase CLI (official .deb; npm global install is explicitly discouraged)
ARG SUPABASE_VERSION=2.66.4
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/supabase.deb \
       "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_${SUPABASE_VERSION}_linux_${arch}.deb" \
    && dpkg -i /tmp/supabase.deb && rm -f /tmp/supabase.deb \
    && supabase --version

# ── GitHub CLI ──────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && gh --version | head -1

# ─────────────────────────────────────────────────────────────────────────────
# Agent CLIs — each in its own layer so one upstream outage doesn't invalidate
# the rest. HOME is redirected so nothing lands under the /home/paseo volume.
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p "$AGENT_HOME" && chmod 755 "$AGENT_HOME"

# Claude Code — installer honours $HOME → $HOME/.local/bin/claude
RUN HOME="$AGENT_HOME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    && ln -sf "$AGENT_HOME/.local/bin/claude" /usr/local/bin/claude \
    && claude --version

# Codex — honours CODEX_INSTALL_DIR; CODEX_HOME is overridden at RUNTIME by the
# base image to /home/paseo/.codex, so auth persists on the volume.
RUN HOME="$AGENT_HOME" CODEX_INSTALL_DIR=/usr/local/bin \
      CODEX_HOME="$AGENT_HOME/.codex" \
      bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && codex --version

# Kimi Code — KIMI_INSTALL_DIR=/usr/local is the documented system-wide install.
# (npm "kimi-cli" is an UNRELATED package — do not use it.)
RUN KIMI_INSTALL_DIR=/usr/local HOME="$AGENT_HOME" bash -c \
      'curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash' \
    && /usr/local/bin/kimi --version 2>/dev/null || true

# Cursor Agent — hardcodes $HOME/.local/{bin,share}; no env override exists,
# so redirecting HOME is the only way to keep it off the volume.
RUN HOME="$AGENT_HOME" bash -c 'curl -fsSL https://cursor.com/install | bash' \
    && ln -sf "$AGENT_HOME/.local/share/cursor-agent" /opt/cursor-agent-share \
    && ln -sf "$AGENT_HOME/.local/bin/cursor-agent" /usr/local/bin/cursor-agent \
    && cursor-agent --version 2>/dev/null || true

# ── agent-browser (headless Chromium for AI agents) ─────────────────────────
# Chrome for Testing (~150MB) is cached OUTSIDE $HOME so it survives into the
# image instead of being re-downloaded on every fresh container.
# NOTE: we do NOT set a global XDG_CACHE_HOME — the base image points that at
# the volume for Paseo's own cache and overriding it breaks Paseo.
ENV AGENT_BROWSER_CACHE=/opt/agent-browser-cache
RUN npm install -g agent-browser \
    && mkdir -p "$AGENT_BROWSER_CACHE" \
    && HOME="$AGENT_HOME" XDG_CACHE_HOME="$AGENT_BROWSER_CACHE" \
       agent-browser install \
    && chmod -R a+rX "$AGENT_BROWSER_CACHE"

# Optional extras, e.g. --build-arg EXTRA_NPM_PACKAGES="opencode-ai"
ARG EXTRA_NPM_PACKAGES=""
RUN if [ -n "$EXTRA_NPM_PACKAGES" ]; then npm install -g $EXTRA_NPM_PACKAGES; fi

# paseo must be able to read every redirected install, and needs sudo for
# ad-hoc package installs from inside an agent session.
RUN chmod -R a+rX "$AGENT_HOME" \
    && echo 'paseo ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-paseo \
    && chmod 0440 /etc/sudoers.d/90-paseo

COPY docker/paseo/entrypoint-devstack.sh /usr/local/bin/entrypoint-devstack.sh
COPY docker/paseo/agent-env.sh           /etc/profile.d/10-devstack-agents.sh
RUN chmod +x /usr/local/bin/entrypoint-devstack.sh \
    && chmod 0644 /etc/profile.d/10-devstack-agents.sh

# Our entrypoint seeds config/memory then delegates to the base entrypoint,
# which drops root → paseo via gosu. tini stays PID 1.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-devstack.sh"]
