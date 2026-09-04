#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# devstack updater — bring an installed deployment up to the latest release.
#
#   make update              check, show the diff, ask, then apply
#   make update-check        report only, change nothing (exit 10 = available)
#   scripts/update.sh --yes  non-interactive (systemd timer, CI)
#
# Guarantees, in order of importance:
#   1. The paseo-home volume is NEVER touched. No `down -v`, no `--volumes`,
#      no `rm`. Every agent credential lives there. This script cannot delete
#      it — grep it: the string "-v" never reaches `compose down`.
#   2. .env is only ever APPENDED to, and backed up first. Values are never
#      rewritten, so a password containing '=', '#', '|' or '&' is safe.
#   3. Nothing is applied before the user has seen what changes.
#   4. Every step is idempotent; a re-run after a failure resumes cleanly.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
DEVSTACK_DIR="$(pwd)"; export DEVSTACK_DIR
. scripts/lib/version.sh
. scripts/lib/env-merge.sh

DC="docker compose"
TARGET_REF=""            # set in step 2; referenced in step 4
ASSUME_YES=0; CHECK_ONLY=0; FORCE=0; NO_BUILD=0; REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --check)      CHECK_ONLY=1 ;;
    --force)      FORCE=1 ;;
    --no-build)   NO_BUILD=1 ;;
    --ref)        REF="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_warn=""; c_bad=""; c_dim=""; c_off=""; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_ok"   "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_off" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_bad"  "$c_off" "$*" >&2; }
hdr()  { printf '\n%s── %s ──%s\n' "$c_dim" "$*" "$c_off"; }
die()  { bad "$*"; exit 1; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || die "not a TTY and --yes not given; refusing to act unattended"
  printf '\n%s [y/N] ' "$1"; local a; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ── 0. preflight ────────────────────────────────────────────────────────────
hdr "preflight"
command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "'docker compose' plugin not available"
docker info >/dev/null 2>&1 || die "docker daemon is not running"
[ -f docker-compose.yml ] || die "not a devstack checkout: $DEVSTACK_DIR"
ok "docker ready"

# A rebuild reads .env. Missing .env means this was never installed here.
[ -f .env ] || die ".env is missing — this looks like a fresh clone, run ./install.sh"
ok ".env present"

# ── 1. what version are we, what version is out there ───────────────────────
hdr "versions"
LOCAL="$(version_local)"
IMAGE="$(version_image)"
COMMIT="$(version_local_commit)"
DIRTY="$(version_local_dirty)"

printf '  checkout : %s (%s, %s)\n' "$LOCAL" "$COMMIT" "$DIRTY"
printf '  image    : %s\n' "$IMAGE"

if ! REMOTE="$(version_remote)" || [ -z "$REMOTE" ]; then
  # A rate limit or an offline box must not look like "you are up to date".
  warn "could not reach the GitHub releases API (offline, or rate-limited)"
  warn "set GH_TOKEN in .env to raise the anonymous 60/hour limit"
  [ "$FORCE" = 1 ] || exit 3
  REMOTE=""
else
  printf '  latest   : %s\n' "$REMOTE"
fi

UPDATE_AVAILABLE=0
if [ -n "$REMOTE" ] && version_gt "$REMOTE" "$LOCAL"; then UPDATE_AVAILABLE=1; fi

# The checkout can be current while the running image is stale — pulled but
# never rebuilt, or a build that failed halfway. That still needs an apply.
REBUILD_NEEDED=0
if [ "$IMAGE" = "unknown" ]; then
  warn "the running image has no version label (built before stamping) — will rebuild"
  REBUILD_NEEDED=1
elif [ "$LOCAL" != "unknown" ] && [ "$IMAGE" != "$LOCAL" ]; then
  warn "image ($IMAGE) does not match the checkout ($LOCAL) — will rebuild"
  REBUILD_NEEDED=1
fi

if [ "$UPDATE_AVAILABLE" = 0 ] && [ "$REBUILD_NEEDED" = 0 ] && [ "$FORCE" = 0 ]; then
  ok "up to date"
  exit 0
fi

# ── 2. show what changes, BEFORE anything is touched ────────────────────────
if [ "$UPDATE_AVAILABLE" = 1 ]; then
  hdr "release notes for $REMOTE"
  notes="$(version_remote_notes 2>/dev/null)"
  if [ -n "$notes" ]; then
    printf '%s\n' "$notes" | head -40
  else
    say "  https://github.com/${DEVSTACK_REPO_SLUG}/releases/latest"
  fi
fi

# Fetch (read-only, safe) so the diff is real rather than a guess.
if [ -d .git ]; then
  hdr "changes to your files"
  git fetch --quiet --tags origin 2>/dev/null || warn "git fetch failed; diff may be stale"
  TARGET_REF="${REF:-origin/$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
  [ -n "$REMOTE" ] && git rev-parse -q --verify "refs/tags/v$REMOTE" >/dev/null 2>&1 \
    && TARGET_REF="v$REMOTE"
  if git rev-parse -q --verify "$TARGET_REF" >/dev/null 2>&1; then
    say "  target: $TARGET_REF"
    git --no-pager diff --stat HEAD.."$TARGET_REF" 2>/dev/null | sed 's/^/  /' | tail -30
  else
    warn "cannot resolve $TARGET_REF"
  fi
else
  warn "no .git here — this checkout was installed from a tarball"
  warn "the file update step will be skipped; only the image can be refreshed"
fi

# ── 3. local edits ──────────────────────────────────────────────────────────
# .env is gitignored so it is never at risk from git. docker-compose.yml is
# tracked, and people DO edit it (ports, extra services). A blind `git pull`
# either refuses or, worse, succeeds and silently reverts their change.
LOCAL_EDITS=""
if [ -d .git ]; then
  LOCAL_EDITS="$(git status --porcelain -- . 2>/dev/null | grep -vE '^\?\?' || true)"
  if [ -n "$LOCAL_EDITS" ]; then
    hdr "your local edits to tracked files"
    printf '%s\n' "$LOCAL_EDITS" | sed 's/^/  /'
    say ""
    say "  These will be stashed (not lost) and re-applied after the update."
    say "  If a re-apply conflicts, your version is kept and the conflict is left"
    say "  in the working tree for you to resolve; the stash is NOT dropped."
  fi
fi

if [ "$CHECK_ONLY" = 1 ]; then
  hdr "check only"
  [ "$UPDATE_AVAILABLE" = 1 ] && { say "  update available: $LOCAL → $REMOTE"; exit 10; }
  [ "$REBUILD_NEEDED"   = 1 ] && { say "  rebuild needed (image out of step)";  exit 10; }
  ok "up to date"; exit 0
fi

confirm "Apply the update?" || { say "aborted; nothing changed"; exit 0; }

# ── 4. update the files ─────────────────────────────────────────────────────
STASHED=0
if [ -d .git ]; then
  hdr "updating files"
  if [ -n "$LOCAL_EDITS" ]; then
    # A named stash is findable later. --keep-index is deliberately NOT used:
    # we want a clean tree for the merge.
    if git stash push -m "devstack-update $(date -u +%FT%TZ)" -- . >/dev/null 2>&1; then
      STASHED=1; ok "stashed your local edits"
    else
      die "could not stash local edits; resolve them and re-run"
    fi
  fi

  # --ff-only: never create a merge commit in a user's deployment. If it is not
  # a fast-forward, the checkout has diverged and a human must look.
  GIT_OK=1
  if git rev-parse -q --verify "$TARGET_REF" >/dev/null 2>&1 \
     && [ "${TARGET_REF#v}" != "$TARGET_REF" ]; then
    git checkout --quiet "$TARGET_REF" 2>/dev/null \
      && ok "checked out $TARGET_REF" \
      || { bad "checkout of $TARGET_REF failed"; GIT_OK=0; }
  else
    git pull --ff-only --quiet 2>/dev/null \
      && ok "fast-forwarded to $TARGET_REF" \
      || { bad "not a fast-forward — your checkout has diverged"; GIT_OK=0; }
  fi

  # Restore the user's edits BEFORE deciding whether to abort, so an abort
  # never strands their work inside a stash they do not know about.
  if [ "$STASHED" = 1 ]; then
    if git stash pop >/dev/null 2>&1; then
      ok "re-applied your local edits cleanly"
    else
      warn "your edits conflict with the update"
      warn "conflict markers are in the working tree; your stash is KEPT"
      warn "  resolve, then: git stash drop"
      GIT_OK=0
    fi
  fi

  # A failed file update must NOT proceed to a rebuild: building the OLD source
  # against the NEW version stamp produces an image that lies about what it
  # contains, which is worse than not updating at all.
  if [ "$GIT_OK" = 0 ]; then
    bad "the file update did not complete — stopping before the rebuild"
    bad "your stack is still running the previous version, untouched"
    say "  resolve the git state above, then re-run: make update"
    exit 1
  fi
fi

# ── 5. merge new .env keys ──────────────────────────────────────────────────
hdr ".env"
env_merge .env.example .env; rc=$?
case $rc in
  0)  ok "no new settings" ;;
  10) ok "added: $ENV_MERGE_ADDED"
      ok "backup: $(ls -t .env.bak.* 2>/dev/null | head -1)" ;;
  *)  die "the .env merge failed; nothing was changed" ;;
esac
[ -n "${ENV_MERGE_ORPHANED:-}" ] && \
  warn "in your .env but no longer in the example (kept): $ENV_MERGE_ORPHANED"

# A newly-added key can be one the stack REQUIRES. Fail before a rebuild
# rather than after, so a half-updated stack is never left running.
if ! $DC config --quiet >/dev/null 2>&1; then
  bad "docker compose rejects the merged config:"
  $DC config 2>&1 | tail -10 | sed 's/^/    /'
  die "fix .env, then re-run scripts/update.sh"
fi
ok "compose config valid"

# ── 6. rebuild and restart, minimising downtime ─────────────────────────────
if [ "$NO_BUILD" = 1 ]; then
  say ""; ok "files updated; skipping the rebuild (--no-build)"; exit 0
fi

hdr "rebuild"
say "  building the new image while the old one keeps serving..."
# The running container is untouched until the build succeeds. A failed build
# therefore leaves a WORKING stack, which is the whole point of building first.
NEW_VER="${REMOTE:-$LOCAL}"
# The stamp is passed as ENV, not --build-arg: compose interpolates it into
# build.args for the one service that declares it, and `make up` / `make build`
# export the same variables — so every build path stamps the image identically.
export DEVSTACK_VERSION="$NEW_VER"
export DEVSTACK_COMMIT="$(version_local_commit)"
export DEVSTACK_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! $DC build; then
  bad "build FAILED — the previous image is still running, nothing was replaced"
  bad "your stack is unchanged and healthy; re-run once the cause is fixed"
  exit 1
fi
ok "image built"

# Pull the third-party images too (9router, cloudflared). --ignore-buildable
# stops compose trying to pull our locally-built image, which has no registry.
$DC pull --quiet --ignore-buildable 2>/dev/null || $DC pull --quiet 2>/dev/null || true

hdr "restart"
# `up -d` recreates only what changed and reuses the volumes. It is the only
# restart primitive here for a reason: `down` would stop the stack first, and
# any flag near `down` risks someone adding -v later.
$DC up -d --remove-orphans || die "restart failed — check: docker compose logs"
ok "containers up"

# ── 7. verify ───────────────────────────────────────────────────────────────
hdr "verify"
for i in $(seq 1 30); do
  st="$($DC ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="paseo"{print $2}')"
  [ "$st" = running ] && break
  sleep 2
done
[ "$st" = running ] && ok "paseo running" || warn "paseo not running yet — docker compose logs paseo"

NEW_IMAGE="$(version_image)"
ok "image now reports: $NEW_IMAGE"

# The volume must still be there. If this ever fails, something in the chain
# destroyed credentials and the user needs to know immediately.
# Derived, never hardcoded: the project name is settable and a wrong guess
# would report a healthy volume as missing (or vice versa).
PROJ="$($DC config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null)"
PROJ="${PROJ:-paseo-dev-stack}"
if docker volume inspect "${PROJ}_paseo-home" >/dev/null 2>&1; then
  ok "paseo-home volume intact (agent credentials preserved)"
else
  bad "paseo-home volume ${PROJ}_paseo-home not found — check: docker volume ls"
fi

say ""
ok "updated: $LOCAL → $(version_local)"
say "  next: make doctor"
