#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Install an extra agent CLI into the RUNNING container, and optionally persist
# it so it survives a rebuild.
#
#   ./scripts/add-agent.sh npm  opencode-ai
#   ./scripts/add-agent.sh npm  @google/gemini-cli
#   ./scripts/add-agent.sh curl https://example.com/install.sh
#   ./scripts/add-agent.sh --list
#
# WHY THIS IS NOT JUST `npm i -g`:
# /home/paseo is a Docker VOLUME. Anything an installer writes into $HOME is
# masked on the next `docker compose up`, so a CLI installed the obvious way
# silently vanishes. This installs with HOME redirected to /opt/agent-home (a
# real image path) and symlinks the binary into /usr/local/bin, which is how the
# built-in CLIs are handled.
#
# Installs into a running container are EPHEMERAL — a rebuild starts from the
# image again. Pass --persist to also record the package in .env
# (EXTRA_NPM_PACKAGES) so the next build bakes it in.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
DC="docker compose"
SVC=paseo

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PERSIST=0
args=()
for a in "$@"; do
  case "$a" in
    --persist) PERSIST=1 ;;
    -h|--help) usage 0 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]:-}"

running() { [ -n "$($DC ps -q "$SVC" 2>/dev/null)" ]; }

if [ "${1:-}" = "--list" ]; then
  running || { echo "container not running — 'make up' first" >&2; exit 1; }
  echo "── agent CLIs available in the container ──"
  $DC exec -T --user paseo "$SVC" bash -lc '
    for c in claude codex kimi cursor-agent opencode gemini aider goose amp; do
      if command -v "$c" >/dev/null 2>&1; then
        # Several CLIs print a warning to stderr BEFORE the version (codex
        # emits a PATH-alias warning in a container), so filter those out
        # rather than showing the warning as the version.
        v="$($c --version 2>&1 | grep -viE "^(warning|warn|note):" | grep -v "^$" | head -1)"
        printf "  %-14s %s\n" "$c" "${v:-installed}"
      fi
    done
    echo
    echo "── cloud / platform CLIs ──"
    for c in doctl cloudflared wrangler vercel netlify flyctl supabase gh code; do
      if command -v "$c" >/dev/null 2>&1; then
        # doctl (and some others) use `version`, not `--version`.
        v="$($c --version 2>&1)"
        case "$v" in *"unknown flag"*|*"unknown command"*) v="$($c version 2>&1)" ;; esac
        v="$(printf "%s" "$v" | grep -viE "^(warning|warn|note):" | grep -v "^$" | head -1)"
        printf "  %-14s %s\n" "$c" "${v:-installed}"
      fi
    done
    echo
    echo "── extra global npm packages ──"
    npm ls -g --depth=0 2>/dev/null | tail -n +2 | sed "s/^/  /"'
  exit 0
fi

METHOD="${1:-}"; TARGET="${2:-}"
[ -n "$METHOD" ] && [ -n "$TARGET" ] || usage 2
running || { echo "container not running — 'make up' first" >&2; exit 1; }

case "$METHOD" in
  npm)
    echo "installing $TARGET (npm, global)…"
    # npm -g writes to /usr/local, which is NOT on the volume, so this survives
    # a restart — but not a rebuild. Hence --persist.
    $DC exec -T --user root "$SVC" bash -lc "npm install -g '$TARGET'"
    ;;
  curl)
    echo "installing from $TARGET (curl installer, HOME redirected)…"
    $DC exec -T --user root "$SVC" bash -lc "
      set -e
      export HOME=/opt/agent-home
      curl -fsSL '$TARGET' | bash
      # Surface anything new in the redirected HOME's bin dir.
      for f in \$HOME/.local/bin/*; do
        [ -x \"\$f\" ] || continue
        ln -sf \"\$f\" /usr/local/bin/\$(basename \"\$f\")
      done
      chmod -R a+rX \$HOME"
    ;;
  *) echo "unknown method '$METHOD' (use: npm | curl)" >&2; usage 2 ;;
esac

if [ "$PERSIST" = 1 ]; then
  if [ "$METHOD" != npm ]; then
    echo
    echo "  ⚠ --persist only supports npm packages."
    echo "    For a curl installer, add a RUN line to docker/paseo/Dockerfile so"
    echo "    it is baked into the image (copy the pattern used for Claude/Codex:"
    echo "    install with HOME=\$AGENT_HOME, then symlink into /usr/local/bin)."
  else
    cur="$(grep -E '^EXTRA_NPM_PACKAGES=' .env 2>/dev/null | cut -d= -f2- || true)"
    case " $cur " in
      *" $TARGET "*) echo "  already in EXTRA_NPM_PACKAGES" ;;
      *)
        new="$(printf '%s %s' "$cur" "$TARGET" | sed 's/^ *//;s/ *$//')"
        tmp="$(mktemp)"
        if grep -qE '^EXTRA_NPM_PACKAGES=' .env; then
          sed "s|^EXTRA_NPM_PACKAGES=.*|EXTRA_NPM_PACKAGES=$new|" .env > "$tmp"
        else
          cat .env > "$tmp"; echo "EXTRA_NPM_PACKAGES=$new" >> "$tmp"
        fi
        mv "$tmp" .env
        echo "  persisted — baked in on the next 'make build'"
        ;;
    esac
  fi
fi

echo
echo "  done. Verify with: ./scripts/add-agent.sh --list"
