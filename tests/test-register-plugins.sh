#!/usr/bin/env bash
# Regression test: AI_ROUTER_PLUGIN_SOURCE installs the AI Router plugin on
# boot, once per daemon, and does nothing at all when unset.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Stand-ins: the daemon is healthy; paseo records calls and reports $FAKE_REG.
mkdir -p "$T/bin" "$T/home/.paseo"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/curl"
cat > "$T/bin/paseo" <<'EOF'
#!/bin/sh
echo "paseo $*" >> "$FAKE_LOG"
case "$1 $2" in
  "plugin ls")      echo "PLUGIN STATUS"; [ -n "$FAKE_REG" ] && echo "$FAKE_REG running" ;;
  "plugin install") [ -n "$FAKE_FAIL" ] && { echo "Error: not a plugin"; exit 1; } ;;
esac
exit 0
EOF
chmod +x "$T/bin/curl" "$T/bin/paseo"
export FAKE_LOG="$T/paseo.log" PATH="$T/bin:$PATH" HOME="$T/home" PASEO_LISTEN=0.0.0.0:6767
run() { : > "$FAKE_LOG"; bash docker/paseo/register-plugins.sh 2> "$T/err" || true; }

FAKE_REG="" FAKE_FAIL="" AI_ROUTER_PLUGIN_SOURCE="" run
[ ! -s "$FAKE_LOG" ] && ok "unset: exits without touching the daemon" || bad "unset: called paseo"

SRC="https://github.com/you/paseo-plugin-ai-router.git:apps/paseo"
FAKE_REG="" FAKE_FAIL="" AI_ROUTER_PLUGIN_SOURCE="$SRC" run
grep -qxF "paseo plugin install $SRC" "$FAKE_LOG" && grep -q 'installed ai-router' "$T/err" \
  && ok "set: installs it from the source, as given" || bad "set: $(tr '\n' '|' < "$FAKE_LOG")"

FAKE_REG="ai-router" FAKE_FAIL="" AI_ROUTER_PLUGIN_SOURCE="$SRC" run
grep -q 'plugin install' "$FAKE_LOG" && bad "reinstalled an already registered ai-router" \
  || ok "already registered: left alone (no reinstall on every boot)"

FAKE_REG="" FAKE_FAIL=1 AI_ROUTER_PLUGIN_SOURCE="$SRC" run
grep -q 'failed to install ai-router' "$T/err" && ok "a failed install is logged, not claimed" \
  || bad "failure not reported: $(cat "$T/err")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
