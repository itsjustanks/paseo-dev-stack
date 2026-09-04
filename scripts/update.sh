#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Update a deployed stack to the latest release.
#
#   ./scripts/update.sh            # show what would change
#   ./scripts/update.sh --apply    # pull, merge .env, rebuild, restart
#
# NEVER touches the Docker volumes — agent credentials live on /home/paseo and
# must survive every update. Only containers and images are replaced.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
REPO="${PDS_REPO:-itsjustanks/paseo-dev-stack}"

log()  { printf '\033[1;36m[update]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ── Current version ─────────────────────────────────────────────────────────
current() {
  if [ -f VERSION ]; then cat VERSION
  elif git rev-parse --git-dir >/dev/null 2>&1; then
    git describe --tags --always --dirty 2>/dev/null || git rev-parse --short HEAD
  else echo "unknown"; fi
}

# ── Latest release ──────────────────────────────────────────────────────────
# The GitHub API returns SINGLE-LINE JSON, so `grep -m1 '"tag_name"'` matches
# the entire body and a following sed captures release notes instead of the tag.
# Match the key AND its value together, then strip.
latest() {
  local body
  body="$(curl -fsSL --max-time 20 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null)" || return 1
  printf '%s' "$body" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

CUR="$(current)"
LATEST="$(latest || true)"
log "installed: $CUR"
if [ -n "$LATEST" ]; then
  log "latest:    $LATEST"
  [ "$CUR" = "$LATEST" ] && log "already up to date"
else
  warn "could not reach the GitHub API (offline, or no releases yet)"
fi

# ── What would change ───────────────────────────────────────────────────────
if git rev-parse --git-dir >/dev/null 2>&1; then
  git fetch --tags --quiet origin 2>/dev/null || warn "git fetch failed"
  dirty="$(git status --porcelain -- . ':!.env' ':!workspace' 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    warn "you have local edits to tracked files:"
    printf '%s\n' "$dirty" | sed 's/^/    /'
    warn "they would block a fast-forward pull; commit or stash them first"
  fi
  changes="$(git log --oneline HEAD..origin/main 2>/dev/null | head -20 || true)"
  if [ -n "$changes" ]; then
    echo; log "incoming commits:"; printf '%s\n' "$changes" | sed 's/^/    /'
  fi
fi

# ── .env merge ──────────────────────────────────────────────────────────────
# Add keys that .env.example has and .env does not, WITHOUT touching existing
# values. Done in Python, not shell, because a naive `source .env` or
# `cut -d= -f2` mangles anything real:
#   TOKEN=abc=def         value legitimately contains '='  -> cut truncates it
#   PW=hunter2#1          '#' is NOT a comment mid-line     -> sed strips it
#   NAME=a b              unquoted spaces                   -> word-splitting
# We treat only the FIRST '=' as the separator and never re-parse the value.
merge_env() {
  python3 - "$1" <<'PY'
import sys, os
apply = sys.argv[1] == "1"
def parse(path):
    keys = []
    if not os.path.exists(path): return keys
    for line in open(path):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s: continue
        keys.append(s.split("=", 1)[0].strip())   # FIRST '=' only
    return keys

have = set(parse(".env"))
missing = []
block, seen = [], set()
for line in open(".env.example"):
    s = line.strip()
    if s and not s.startswith("#") and "=" in s:
        k = s.split("=", 1)[0].strip()
        if k not in have and k not in seen:
            seen.add(k); missing.append(k); block.append(line.rstrip("\n"))
    elif block and s.startswith("#"):
        pass  # keep comments only when attached to a kept key (below)

if not missing:
    print("  .env is up to date"); raise SystemExit(0)

print(f"  {len(missing)} new key(s) in .env.example: {', '.join(missing)}")
if not apply:
    print("  run with --apply to append them (existing values are never changed)")
    raise SystemExit(0)

with open(".env", "a") as f:
    f.write("\n# ── added by update.sh ──\n")
    for line in block:
        f.write(line + "\n")
print(f"  appended {len(missing)} key(s) to .env")
PY
}

echo; log "checking .env against .env.example"
merge_env "$APPLY"

# ── Apply ───────────────────────────────────────────────────────────────────
if [ "$APPLY" = 0 ]; then
  echo; log "dry run — nothing changed. Re-run with --apply to update."
  exit 0
fi

echo
if git rev-parse --git-dir >/dev/null 2>&1; then
  log "pulling"
  git pull --ff-only 2>&1 | sed 's/^/    /' || {
    warn "fast-forward pull failed — resolve manually, then re-run"
    exit 1
  }
fi

log "rebuilding and restarting (volumes untouched)"
docker compose up -d --build 2>&1 | tail -6 | sed 's/^/    /'

echo; log "now at: $(current)"
log "verify with: make doctor"
