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
# SUPABASE_VERSION is empty by default => resolve the latest release at build
# time. A hardcoded pin silently 404s the day upstream moves on, so pin only
# deliberately: --build-arg SUPABASE_VERSION=2.116.0
ARG SUPABASE_VERSION=
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    ver="${SUPABASE_VERSION}"; \
    if [ -z "$ver" ]; then \
      ver="$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest \
             | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
             | head -1 | sed -E 's/.*"v?([^"]+)"$/\1/')"; \
    fi; \
    echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || { echo "bad supabase version: '$ver'"; exit 1; }; \
    curl -fsSL -o /tmp/supabase.deb \
      "https://github.com/supabase/cli/releases/download/v${ver}/supabase_${ver}_linux_${arch}.deb"; \
    dpkg -i /tmp/supabase.deb; rm -f /tmp/supabase.deb; \
    supabase --version

# ── Cloud CLIs ──────────────────────────────────────────────────────────────
# doctl (DigitalOcean) — released as a tarball, no apt repo. Resolve the latest
# tag at build time; a hardcoded version 404s the day upstream moves on.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) doarch=amd64 ;; arm64) doarch=arm64 ;; \
      *) echo "unsupported arch for doctl"; exit 1 ;; \
    esac; \
    ver="$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest \
           | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
           | head -1 | sed -E 's/.*"v?([^"]+)"$/\1/')"; \
    echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || { echo "bad doctl version: '$ver'"; exit 1; }; \
    curl -fsSL "https://github.com/digitalocean/doctl/releases/download/v${ver}/doctl-${ver}-linux-${doarch}.tar.gz" \
      | tar -xz -C /usr/local/bin doctl; \
    chmod +x /usr/local/bin/doctl; \
    doctl version | head -1

# cloudflared (Cloudflare Tunnel client). The tunnel itself runs as its own
# container, but having the CLI here lets an agent create/manage tunnels,
# and `cloudflared tunnel login` from inside the workspace.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL -o /tmp/cloudflared.deb \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"; \
    dpkg -i /tmp/cloudflared.deb; rm -f /tmp/cloudflared.deb; \
    cloudflared --version

# Node-based cloud CLIs. These install to /usr/local (NOT $HOME), so they are
# not masked by the /home/paseo volume and need no HOME redirection.
#   wrangler  — Cloudflare Workers/Pages/R2/D1
#   vercel    — Vercel deployments
#   netlify   — Netlify (optional but tiny)
RUN npm install -g wrangler vercel netlify-cli \
    && wrangler --version && vercel --version && netlify --version | head -1

# flyctl (Fly.io) — installer honours FLYCTL_INSTALL and writes into it.
RUN set -eux; \
    FLYCTL_INSTALL=/usr/local/flyctl sh -c "curl -fsSL https://fly.io/install.sh | sh"; \
    ln -sf /usr/local/flyctl/bin/flyctl /usr/local/bin/flyctl; \
    ln -sf /usr/local/flyctl/bin/flyctl /usr/local/bin/fly; \
    chmod -R a+rX /usr/local/flyctl; \
    flyctl version

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

# Kimi Code. The official installer pulls from code.kimi.com, which is
# unreachable from some datacenters (observed: connect timeout from a DO
# droplet). Try it, then fall back to the npm package, which ships the same
# version. NOTE: npm "kimi-cli" is an UNRELATED package — the correct one is
# @moonshot-ai/kimi-code.
RUN set -eux; \
    if KIMI_INSTALL_DIR=/usr/local HOME="$AGENT_HOME" \
       timeout 120 bash -c 'curl -fsSL --max-time 60 https://code.kimi.com/kimi-code/install.sh | bash' \
       && [ -x /usr/local/bin/kimi ]; then \
      echo "kimi: installed from official CDN"; \
    else \
      echo "kimi: CDN unreachable, falling back to npm"; \
      npm install -g @moonshot-ai/kimi-code; \
    fi; \
    command -v kimi >/dev/null || { echo "kimi install FAILED"; exit 1; }; \
    kimi --version || true

# Cursor Agent — hardcodes $HOME/.local/{bin,share}; no env override exists,
# so redirecting HOME is the only way to keep it off the volume.
RUN HOME="$AGENT_HOME" bash -c 'curl -fsSL https://cursor.com/install | bash' \
    && ln -sf "$AGENT_HOME/.local/share/cursor-agent" /opt/cursor-agent-share \
    && ln -sf "$AGENT_HOME/.local/bin/cursor-agent" /usr/local/bin/cursor-agent \
    && cursor-agent --version 2>/dev/null || true

# ── agent-browser (headless Chromium for AI agents) ─────────────────────────
# Chrome for Testing (~150MB) is baked into the image so it is not re-fetched
# per container. agent-browser looks for it at $HOME/.agent-browser/browsers and
# ignores XDG_CACHE_HOME, so with HOME=$AGENT_HOME at build time it lands in the
# image; we then expose it via AGENT_BROWSER_CHROME for the runtime HOME.
# (We must NOT set a global XDG_CACHE_HOME — the base image points that at the
# volume for Paseo's own cache.)
RUN set -eux; \
    npm install -g agent-browser; \
    HOME="$AGENT_HOME" agent-browser install; \
    chrome="$(find "$AGENT_HOME/.agent-browser/browsers" -maxdepth 3 -type f -name chrome | head -1)"; \
    [ -n "$chrome" ] || { echo "Chrome not found after install"; exit 1; }; \
    echo "$chrome" > /opt/chrome-path; \
    chmod -R a+rX "$AGENT_HOME/.agent-browser"

# Optional extras, e.g. --build-arg EXTRA_NPM_PACKAGES="opencode-ai"
ARG EXTRA_NPM_PACKAGES=""
RUN if [ -n "$EXTRA_NPM_PACKAGES" ]; then npm install -g $EXTRA_NPM_PACKAGES; fi

# paseo must be able to read every redirected install, and needs sudo for
# ad-hoc package installs from inside an agent session.
RUN chmod -R a+rX "$AGENT_HOME" \
    && echo 'paseo ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-paseo \
    && chmod 0440 /etc/sudoers.d/90-paseo

# ── VS Code CLI (dev tunnels) ───────────────────────────────────────────────
# `code tunnel` exposes this container as a remote in vscode.dev — a full
# browser IDE over Microsoft's tunnel, no inbound port needed.
# The "cli-alpine-*" build is the statically-linked musl binary, which is the
# right choice on Debian too (the cli-linux-* slug does not exist -> 404).
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) vsarch=cli-alpine-x64 ;; \
      arm64) vsarch=cli-alpine-arm64 ;; \
      *) echo "unsupported arch for VS Code CLI"; exit 1 ;; \
    esac; \
    curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=${vsarch}" \
      -o /tmp/vscode-cli.tar.gz; \
    tar -xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin; \
    rm -f /tmp/vscode-cli.tar.gz; \
    chmod +x /usr/local/bin/code; \
    code --version

# ── Paseo plugin: 9router ───────────────────────────────────────────────────
# Surfaces 9router's accounts, quotas and models in the Paseo sidebar.
# Vendored into the image; the entrypoint registers it on first boot, because
# `paseo plugin add` writes into ~/.paseo, which is on the volume.
ARG PLUGIN_9ROUTER_REPO=https://github.com/itsjustanks/paseo-plugin-9router
ARG PLUGIN_9ROUTER_REF=main
RUN git clone --depth 1 -b "$PLUGIN_9ROUTER_REF" "$PLUGIN_9ROUTER_REPO" \
      /opt/paseo-plugins/9router \
    && rm -rf /opt/paseo-plugins/9router/.git \
    && chmod -R a+rX /opt/paseo-plugins

COPY docker/paseo/stream-bridge.py       /usr/local/bin/stream-bridge.py
COPY docker/paseo/entrypoint-devstack.sh /usr/local/bin/entrypoint-devstack.sh
COPY docker/paseo/agent-env.sh           /etc/profile.d/10-devstack-agents.sh
RUN chmod +x /usr/local/bin/entrypoint-devstack.sh /usr/local/bin/stream-bridge.py \
    && chmod 0644 /etc/profile.d/10-devstack-agents.sh

ENV PATH="/usr/local/bin:/home/paseo/.local/bin:${PATH}" \
    npm_config_update_notifier=false \
    DO_NOT_TRACK=1 \
    PASEO_PLUGIN_SOURCE=/opt/paseo-plugins

ARG PDS_VERSION=dev
ENV PDS_VERSION=${PDS_VERSION}
LABEL org.opencontainers.image.title="paseo-dev-stack" \
      org.opencontainers.image.source="https://github.com/itsjustanks/paseo-dev-stack" \
      org.opencontainers.image.version="${PDS_VERSION}"

# Our entrypoint seeds config/memory then delegates to the base entrypoint,
# which drops root → paseo via gosu. tini stays PID 1.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-devstack.sh"]
