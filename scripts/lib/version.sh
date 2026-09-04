#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# version.sh — how a deployment knows what it is, and what is available.
#
# Source it:  . scripts/lib/version.sh
#
# Four independent facts, deliberately kept separate:
#
#   local_version   what this CHECKOUT claims to be   (VERSION file)
#   local_commit    what this checkout actually is    (git, may be absent)
#   image_version   what the RUNNING container is     (OCI label, authoritative)
#   remote_version  what GitHub's latest release is   (API)
#
# They diverge in normal use, and each divergence means something different:
#   VERSION > image   → pulled/edited but never rebuilt   → `make update`
#   image  > VERSION  → someone rolled the checkout back  → suspicious
#   remote > VERSION  → an update is available            → `make update`
# `doctor` reports all of these; see doctor_version_report below.
# ─────────────────────────────────────────────────────────────────────────────

DEVSTACK_REPO_SLUG="${DEVSTACK_REPO_SLUG:-itsjustanks/paseo-dev-stack}"
DEVSTACK_IMAGE="${DEVSTACK_IMAGE:-paseo-dev-stack/agents:latest}"

# ── local ───────────────────────────────────────────────────────────────────
# The VERSION file is the source of truth, NOT `git describe`, because:
#   - install.sh clones with --depth 1, so no tags are fetched: `git describe`
#     fails outright ("No names found") on every fresh server install;
#   - a tarball/zip download has no .git at all;
#   - `docker compose pull` of a prebuilt image involves no git whatsoever.
# git is used only to enrich the answer when it happens to be available.
version_local() {
  local f="${DEVSTACK_DIR:-.}/VERSION"
  [ -f "$f" ] && tr -d ' \t\n\r' < "$f" || echo "unknown"
}

version_local_commit() {
  git -C "${DEVSTACK_DIR:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

version_local_dirty() {
  git -C "${DEVSTACK_DIR:-.}" diff --quiet 2>/dev/null && echo "clean" || echo "dirty"
}

# ── image ───────────────────────────────────────────────────────────────────
# Read from the OCI label baked at build time. This is the only fact that
# survives `docker compose pull` of a prebuilt image (no source tree involved)
# AND a local `docker compose build`, because both paths set the same label.
# Falls back to the file the Dockerfile also writes, for images built before
# labelling existed.
version_image() {
  local v
  v="$(docker image inspect "$DEVSTACK_IMAGE" \
        --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
        2>/dev/null | tr -d ' \t\n\r')"
  [ -n "$v" ] && [ "$v" != "<no value>" ] && { printf '%s' "$v"; return 0; }

  # Fallback for images built before labelling. NOTE the assignment: writing
  #   ... | tr -d ... || echo unknown
  # binds `||` to the PIPELINE, which SUCCEEDS even when the exec fails, so an
  # absent file printed an empty string instead of "unknown" — and an empty
  # string then compared unequal to every version and forced an endless
  # rebuild. Capture first, test the value, then decide.
  v="$(docker compose exec -T --user paseo paseo \
        cat /etc/devstack-version 2>/dev/null | tr -d ' \t\n\r')"
  [ -n "$v" ] && printf '%s' "$v" || printf 'unknown'
}

# ── remote ──────────────────────────────────────────────────────────────────
# GitHub returns the release object as a SINGLE LINE of JSON. Three naive
# parses that look fine against a pretty-printed fixture and break on the wire:
#
#   grep -m1 '"tag_name"' r.json
#       -m1 stops after the first matching LINE. There is one line. This
#       returns the entire ~40KB document. Measured, not theoretical.
#
#   grep -m1 '"tag_name"' r.json | cut -d'"' -f4
#       Field 4 is only "the tag" when tag_name happens to be the first key.
#       On the real payload the first key is "url", so field 4 is
#       "https://api.github.com/repos/.../releases/377383492".
#
#   sed -E 's/.*"tag_name": *"([^"]*)".*/\1/'
#       `.*` is greedy, so it matches the LAST occurrence. Release bodies
#       routinely quote JSON keys ("fix: parse \"tag_name\" correctly"), and a
#       changelog then decides your version number.
#
# Correct parses, in preference order. All three anchor on the key and take
# the FIRST match; python3 actually parses the JSON and is preferred because it
# also handles escaped quotes inside strings, which no regex does.
# github_get <path> — GET the API, with the token when one is set.
# NOTE: an empty array expanded as "${a[@]}" is an UNBOUND VARIABLE error in
# bash 3.2 (macOS /bin/bash) under `set -u`. That aborted version_remote and
# made every check report "offline". Always-non-empty header args avoid it.
github_get() {
  local url="https://api.github.com/repos/${DEVSTACK_REPO_SLUG}/$1"
  local tok="${GH_TOKEN:-}"
  if [ -n "$tok" ]; then
    curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H "Authorization: Bearer $tok" "$url" 2>/dev/null
  else
    curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' "$url" 2>/dev/null
  fi
}

version_remote() {
  local json
  json="$(github_get releases/latest)" || return 1
  [ -n "$json" ] || return 1
  local tag; tag="$(json_field "$json" tag_name)"
  [ -n "$tag" ] || return 1
  printf '%s' "${tag#v}"
}

# json_field <json> <key> — first value of a top-level-ish string key.
json_field() {
  local json="$1" key="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
v=d.get(sys.argv[1],"")
sys.stdout.write(v if isinstance(v,str) else str(v))
' "$key" && return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -er --arg k "$key" '.[$k] // empty' && return 0
  fi
  # Pure-shell fallback: -o prints each MATCH (not the line), head -1 takes the
  # first, and [^"]* is non-greedy by construction. Cannot see through an
  # escaped quote — hence it is the last resort, not the default.
  printf '%s' "$json" \
    | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"$/\1/'
}

version_remote_notes() {
  local json; json="$(github_get releases/latest)" || return 1
  json_field "$json" body
}

# ── comparison ──────────────────────────────────────────────────────────────
# `sort -V` is GNU-only in practice and BSD sort's -V has differed historically,
# so semver comparison goes through python3 (guaranteed on host and in the
# container by this repo's own prerequisites). Pre-release tags sort before
# their release, per semver.
#
# version_gt A B  → true when A is strictly newer than B.
version_gt() {
  [ "$1" = "$2" ] && return 1
  case "$1$2" in *unknown*) return 1 ;; esac
  python3 - "$1" "$2" <<'PY'
import sys,re
def key(v):
    v=v.strip().lstrip('v')
    core,_,pre=v.partition('-')
    nums=[int(x) if x.isdigit() else 0 for x in re.split(r'[.+]',core)[:3]]
    nums+= [0]*(3-len(nums))
    # no pre-release sorts AFTER a pre-release of the same core version
    return (nums,(1,) if not pre else (0,pre))
sys.exit(0 if key(sys.argv[1])>key(sys.argv[2]) else 1)
PY
}
