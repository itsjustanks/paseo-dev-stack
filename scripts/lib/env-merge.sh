#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# env-merge — add new keys from .env.example into an existing .env WITHOUT
# touching a single byte the user already wrote.
#
# Sourceable:   . scripts/lib/env-merge.sh   →  env_merge <example> <target>
# Runnable:     scripts/lib/env-merge.sh .env.example .env [--dry-run]
#
# ── Why this is append-only ──────────────────────────────────────────────────
# The file holds live secrets: PASEO_PASSWORD, TUNNEL_TOKEN, NINEROUTER_KEY.
# Any strategy that REWRITES the file can corrupt them. This one never rewrites:
# it reads the set of keys already assigned, and appends only the blocks for
# keys that are absent. The worst possible failure is a missing new key (which
# `doctor` reports), never a mangled value.
#
# ── Why the obvious approaches corrupt values ────────────────────────────────
#  1. cut -d= -f2            NODE_OPTIONS=--max-old-space-size=8192
#                            → "--max-old-space-size". Values legitimately
#                            contain '='; base64/JWT tunnel tokens end in '=='.
#                            Split on the FIRST '=' only: ${line#*=}.
#  2. sed "s|^K=.*|K=$v|"    '&' in $v expands to the whole match, '\' escapes,
#                            and a value containing the delimiter ends the
#                            expression. A TUNNEL_TOKEN with '|' rewrites the
#                            file into garbage. We never substitute a value.
#  3. sed 's/#.*//'          "password: p#ssw0rd" → "p". Compose only treats
#                            ' #' (whitespace-preceded) as an inline comment,
#                            never a bare '#'. We never strip comments from
#                            values because we never re-emit values.
#  4. grep -q "^KEY"         matches NINEROUTER_PORT when asking about
#                            NINEROUTER_PO... and matches "PASEO_PORT_EXTRA"
#                            when asking about "PASEO_PORT". Anchor on the '='.
#  5. any line with '='      this very .env.example documents defaults inside
#                            comments:
#                                #     8GB  box -> PASEO_MEM_LIMIT=5g
#                                # Example: NODE_OPTIONS=--max-old-space-size=8192
#                            A naive scanner treats those as assignments and
#                            then "helpfully" writes PASEO_MEM_LIMIT=5g into a
#                            32GB box's config. Comment lines must be skipped
#                            BEFORE any key is extracted.
#  6. writing a key twice    docker compose takes the LAST assignment in .env.
#                            Appending a key that already exists silently
#                            overrides the user's value with the example
#                            default. Absence detection has to be exact —
#                            hence the newline-sentinel set below, not grep.
#
# bash 3.2 compatible (macOS /bin/bash): no `declare -A`, no mapfile, no ${x,,}.
# ─────────────────────────────────────────────────────────────────────────────

# env_line_key <line> — print the assigned key, or return 1.
# Accepts:  KEY=v   |   export KEY=v   |   leading whitespace
# Rejects:  # KEY=v |   #KEY=v         |   anything with no '=' after the key
env_line_key() {
  local line="$1"
  # '#' is not a valid identifier character, so an anchored identifier match
  # can never fire on a comment line. That is the whole trick.
  [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] || return 1
  printf '%s' "${BASH_REMATCH[2]}"
}

# env_key_set <file> — newline-delimited set of keys assigned in <file>,
# wrapped in sentinel newlines so membership tests are exact.
#
# NOTE: $(env_key_set f) strips the trailing newline — and so does any FURTHER
# command substitution, so a wrapper cannot fix it. env_has_key therefore
# re-adds the closing sentinel itself. Without that, the LAST key in the file
# reads as absent and gets re-appended, silently overriding the user's value
# with the example default (compose takes the last assignment). This was a real
# bug caught by the idempotency test, not a hypothetical.
env_key_set() {
  local file="$1" line key set_=$'\n'
  [ -f "$file" ] || { printf '%s' "$set_"; return 0; }
  # `|| [ -n "$line" ]` catches a final line with no trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    key="$(env_line_key "$line")" || continue
    case "$set_" in *$'\n'"$key"$'\n'*) continue ;; esac
    set_="${set_}${key}"$'\n'
  done < "$file"
  printf '%s' "$set_"
}

# env_has_key <set> <key> — exact membership, no regex, no prefix collisions.
# Re-adds the closing sentinel so it is correct whether the set was captured
# with $(...) (newline eaten) or used directly. A doubled newline is harmless.
env_has_key() {
  local set_="$1"$'\n'
  case "$set_" in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

# env_value_of <file> <key> — last assignment wins (compose semantics).
# Splits on the FIRST '=' only, so values containing '=' survive intact.
env_value_of() {
  local file="$1" want="$2" line key val=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key="$(env_line_key "$line")" || continue
    [ "$key" = "$want" ] || continue
    val="${line#*=}"
  done < "$file"
  printf '%s' "$val"
}

# env_merge <example> <target> [--dry-run]
#
# Appends, for every key present in <example> but absent from <target>, the
# key's own documentation block (the comment/blank lines immediately above it)
# followed by the assignment line itself, verbatim.
#
# Exit: 0 = nothing to do, 10 = keys were added (or would be), 1 = error.
# Sets: ENV_MERGE_ADDED (space-separated), ENV_MERGE_ORPHANED (keys the target
#       still defines that the example no longer documents — reported, never
#       removed, because a user may rely on them).
env_merge() {
  local example="$1" target="$2" dry="${3:-}"
  ENV_MERGE_ADDED=""; ENV_MERGE_ORPHANED=""

  [ -f "$example" ] || { echo "env_merge: no such file: $example" >&2; return 1; }
  [ -f "$target" ]  || { echo "env_merge: no such file: $target"  >&2; return 1; }

  local have want line key buf="" add_file added=""
  have="$(env_key_set "$target")"
  add_file="$(mktemp "${TMPDIR:-/tmp}/envmerge.XXXXXX")" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    if key="$(env_line_key "$line")"; then
      if ! env_has_key "$have" "$key"; then
        # Emit the accumulated comment block, then the assignment, verbatim.
        [ -n "$buf" ] && printf '%s' "$buf" >> "$add_file"
        printf '%s\n' "$line" >> "$add_file"
        added="$added $key"
        # Record it so a key documented twice in the example is added once.
        have="${have}${key}"$'\n'
      fi
      buf=""                     # the block belonged to this key either way
    else
      buf="${buf}${line}"$'\n'   # comment or blank: hold it for the next key
    fi
  done < "$example"

  # Keys the user has that the example no longer documents. Informational.
  want="$(env_key_set "$example")"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    env_has_key "$want" "$key" || ENV_MERGE_ORPHANED="$ENV_MERGE_ORPHANED $key"
  done <<< "$(env_key_set "$target")"

  ENV_MERGE_ADDED="${added# }"
  ENV_MERGE_ORPHANED="${ENV_MERGE_ORPHANED# }"

  if [ ! -s "$add_file" ]; then rm -f "$add_file"; return 0; fi
  if [ "$dry" = "--dry-run" ]; then
    printf '%s' "$(cat "$add_file")"; echo
    rm -f "$add_file"; return 10
  fi

  # Back up before the only mutation in this file.
  cp -p "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)"

  # A .env with no trailing newline would glue the header onto the last value.
  # $(tail -c1) strips a trailing newline, so it is empty iff the file ends in
  # one. An empty file needs no separator either.
  if [ -s "$target" ] && [ -n "$(tail -c1 "$target"; echo x)" ]; then
    [ "$(tail -c1 "$target")" != "" ] && printf '\n' >> "$target"
  fi

  {
    printf '\n# ─── added by scripts/update.sh on %s ───\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# New settings from .env.example. Defaults shown; edit as needed.\n'
    cat "$add_file"
  } >> "$target"

  rm -f "$add_file"
  return 10
}

# Standalone entry point (works in bash 3.2; BASH_SOURCE is set there).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  env_merge "${1:-.env.example}" "${2:-.env}" "${3:-}"; rc=$?
  [ -n "${ENV_MERGE_ADDED:-}" ] && echo "added: $ENV_MERGE_ADDED" >&2
  [ -n "${ENV_MERGE_ORPHANED:-}" ] && echo "no longer in the example: $ENV_MERGE_ORPHANED" >&2
  [ $rc -eq 10 ] && rc=0
  exit $rc
fi
