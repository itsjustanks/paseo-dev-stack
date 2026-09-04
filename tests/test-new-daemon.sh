#!/usr/bin/env bash
# Regression test: new-daemon.sh must never take the host down.
#
# On 2026-09-04 this script OOM-killed a 31GB server: `compose up` started a
# second uncapped Paseo container next to a main one holding a 28GB cgroup, and
# the kernel killed docker mid-"Container Creating". These cases lock in the
# three guards that prevent a repeat.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/fakebin"
cp scripts/new-daemon.sh scripts/autotune-memory.sh "$T/scripts/"
cp docker-compose.yml "$T/"

# Stand in for docker: claim the image exists, record what would have run.
cat > "$T/fakebin/docker" <<'EOF'
#!/bin/sh
[ "$1" = "image" ] && exit 0
echo "docker $*" >> "$FAKE_DOCKER_LOG"
EOF
chmod +x "$T/fakebin/docker"
export FAKE_DOCKER_LOG="$T/docker.log"
export PATH="$T/fakebin:$PATH"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

cd "$T"

# ── 1. Refuses when the budget is already spent ─────────────────────────────
# The exact shape that killed the server: main container capped at nearly the
# whole box, second daemon requested anyway.
printf 'PASEO_PASSWORD=x\nPASEO_MEM_LIMIT=999999m\n' > .env
: > "$FAKE_DOCKER_LOG"
if bash scripts/new-daemon.sh acme 6771 >/dev/null 2>&1; then
  bad "should refuse when memory budget is exhausted"
else
  ok "refuses when memory budget is exhausted"
fi
grep -q PASEO_NAME_2 .env && bad "must not touch .env when refusing" \
                          || ok "leaves .env untouched when refusing"
[ -s "$FAKE_DOCKER_LOG" ] && bad "must not start anything when refusing" \
                          || ok "starts nothing when refusing"

# ── 2. Never builds ─────────────────────────────────────────────────────────
# Building a 5-CLI + Chromium image beside a running stack is the other way to
# exhaust the host, so the compose call must carry --no-build.
printf 'PASEO_PASSWORD=x\n' > .env
bash scripts/autotune-memory.sh --daemons 2 --write >/dev/null 2>&1
: > "$FAKE_DOCKER_LOG"
bash scripts/new-daemon.sh acme 6771 >/dev/null 2>&1 || true
grep -q -- '--no-build' "$FAKE_DOCKER_LOG" \
  && ok "passes --no-build to compose" \
  || bad "compose call is missing --no-build (would build beside a live stack)"

# ── 3. Satellite inherits a real cap ────────────────────────────────────────
# Writing 0 here means "unlimited", which is what let a satellite eat the host.
sat="$(grep -E '^PASEO_MEM_LIMIT_2=' .env | tail -1 | cut -d= -f2-)"
case "$sat" in
  ''|0) bad "satellite cap is '$sat' (unlimited — the original bug)" ;;
  *)    ok  "satellite inherits a real cap ($sat)" ;;
esac

# ── 4. Ports never collide ──────────────────────────────────────────────────
p="$(grep -E '^AGENT_BROWSER_STREAM_PORT_2=' .env | cut -d= -f2-)"
[ "$p" = "9225" ] && ok "stream port matches the compose default for slot 2" \
                  || bad "stream port $p != compose default 9225"

dupes="$(grep -oE '\$\{AGENT_BROWSER_STREAM_PORT_[0-9]+:-[0-9]+\}' docker-compose.yml \
         | grep -oE ':-[0-9]+' | sort | uniq -d)"
[ -z "$dupes" ] && ok "no duplicate stream-port defaults across slots" \
                || bad "duplicate stream-port defaults: $dupes"

# ── 5. Missing image is refused, not built ──────────────────────────────────
cat > "$T/fakebin/docker" <<'EOF'
#!/bin/sh
[ "$1" = "image" ] && exit 1
echo "docker $*" >> "$FAKE_DOCKER_LOG"
EOF
chmod +x "$T/fakebin/docker"
printf 'PASEO_PASSWORD=x\n' > .env
: > "$FAKE_DOCKER_LOG"
if bash scripts/new-daemon.sh acme 6771 >/dev/null 2>&1; then
  bad "should refuse when the image does not exist"
else
  ok "refuses when the image does not exist"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
