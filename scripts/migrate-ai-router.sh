#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Move every running daemon off the old bundled 9router, onto the AI Router.
#
#   ./scripts/migrate-ai-router.sh           # strip the leftovers (backs up first)
#   ./scripts/migrate-ai-router.sh --check   # only report; exits 1 if any are left
#
# Per daemon (main + each running satellite):
#   1. strips what `make router-on` wrote into its volume — Claude's
#      ANTHROPIC_BASE_URL / _AUTH_TOKEN / _DEFAULT_*_MODEL and Codex's
#      9router provider (scripts/lib/router-leftovers.py). Left in place they
#      silently override the AI Router plugin's routing.
#   2. removes the old agent-link-9router Paseo plugin, if registered, and
#      moves the copy the old image left in ~/.paseo/plugins/9router aside.
#
# Idempotent: a second run changes nothing. Login files (.credentials.json,
# auth.json) are never opened. New agent sessions pick the change up; running
# ones keep their old environment until restarted.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/daemons.sh
. scripts/lib/daemons.sh
DC="docker compose --profile satellites"
OLD_PLUGIN=agent-link-9router

CHECK=""; [ "${1:-}" = "--check" ] && CHECK="--check"

daemons="$(running_daemons)"
[ -n "$daemons" ] || { echo "no Paseo daemon is running — 'make up' first" >&2; exit 1; }

left=0
for svc in $daemons; do
  echo "── $svc ──"
  rc=0
  $DC exec -T --user paseo "$svc" python3 - $CHECK /home/paseo \
    < scripts/lib/router-leftovers.py || rc=$?
  [ "$rc" -eq 0 ] || left=1

  # The daemon, not the filesystem, knows what is registered.
  still_registered=0
  if $DC exec -T --user paseo "$svc" bash -lc \
       "paseo plugin ls 2>/dev/null | awk 'NR>1{print \$1}' | grep -qx $OLD_PLUGIN"; then
    if [ -n "$CHECK" ]; then
      printf '  %-26s WOULD remove\n' "plugin $OLD_PLUGIN"; left=1
    elif $DC exec -T --user paseo "$svc" paseo plugin remove "$OLD_PLUGIN" >/dev/null 2>&1; then
      printf '  %-26s removed\n' "plugin $OLD_PLUGIN"
    else
      printf '  %-26s FAILED to remove — run: paseo plugin remove %s\n' "plugin $OLD_PLUGIN" "$OLD_PLUGIN"
      left=1; still_registered=1
    fi
  else
    printf '  %-26s not installed\n' "plugin $OLD_PLUGIN"
  fi

  # The old image copied the plugin into the volume. Unregistered, it is dead
  # weight that `make doctor` reports as "present but not registered".
  # Moved, not deleted, and never while the plugin is still registered. Home
  # passed as $1 so it is one argument, not part of a string.
  [ "$still_registered" = 1 ] && continue
  # shellcheck disable=SC2016  # expands inside the container, on purpose
  moved="$($DC exec -T --user paseo "$svc" bash -c '
    d="$1/.paseo/plugins/9router"; [ -d "$d" ] || exit 0
    if [ "$2" = --check ]; then echo would; exit 0; fi
    b="$1/.paseo/9router-plugin.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$d" "$b" && echo "${b##*/}"' _ /home/paseo "${CHECK:-apply}" 2>/dev/null || true)"
  case "$moved" in
    "")    ;;
    would) printf '  ~/.paseo/plugins/9router   WOULD move aside\n'; left=1 ;;
    *)     printf '  ~/.paseo/plugins/9router   moved to ~/.paseo/%s\n' "$moved" ;;
  esac
done

echo
if [ -n "$CHECK" ]; then
  [ "$left" -eq 0 ] && echo "clean: no 9router routing left on any running daemon" \
                    || echo "leftovers found — run: make migrate-ai-router"
  exit "$left"
fi
[ "$left" -eq 0 ] || { echo "some steps failed; see above" >&2; exit 1; }
echo "done. Stopped satellites were skipped — start them and re-run."
echo "next: install the AI Router plugin (README: \"Upgrading an existing host to AI Router\")"
