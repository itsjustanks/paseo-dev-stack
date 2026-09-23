#!/usr/bin/env bash
# Regression test: the stack is Paseo daemons only.
#
# 9router used to be a hard dependency — every daemon waited on its
# healthcheck. It was removed; routing is now an AI Router plugin configured
# through AI_ROUTER_* in .env. These cases lock that in: no router service or
# volume comes back, and the plugin settings reach the main daemon AND every
# satellite (they inherit env through the `paseo-common` anchor, so a satellite
# that redefines `environment:` would silently lose them).
#
#   bash tests/test-compose.sh            (DC="docker-compose" to override)
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
DC="${DC:-docker compose}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Render with the shipped example plus sentinel router settings. --env-file
# keeps the repo's own .env out of it.
cp .env.example "$T/.env"
{
  echo "PASEO_PASSWORD=ci-test"
  echo "AI_ROUTER_URL=https://router.test"
  echo "AI_ROUTER_KEY=k-test"
  echo "AI_ROUTER_TOKEN=t-test"
  echo "AI_ROUTER_CONSOLE_URL=https://console.test"
} >> "$T/.env"

$DC --env-file "$T/.env" config --format json > "$T/default.json"
$DC --env-file "$T/.env" --profile satellites config --format json > "$T/satellites.json"

# ── 1. No bundled router ────────────────────────────────────────────────────
for f in default satellites; do
  if grep -qiE '9router|ninerouter' "$T/$f.json"; then
    bad "$f config still mentions 9router: $(grep -oiE '[a-z_]*(9router|ninerouter)[a-z_]*' "$T/$f.json" | sort -u | tr '\n' ' ')"
  else
    ok "$f config has no 9router service, volume, env or dependency"
  fi
done

# ── 2. The default stack is the main daemon only ────────────────────────────
svcs="$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["services"])))' "$T/default.json")"
[ "$svcs" = "paseo" ] && ok "default services: paseo" \
                      || bad "default services: '$svcs' (expected only paseo)"

# ── 3. AI Router settings reach every daemon ────────────────────────────────
missing="$(python3 - "$T/satellites.json" <<'PY'
import json, sys
want = {"AI_ROUTER_URL": "https://router.test", "AI_ROUTER_KEY": "k-test",
        "AI_ROUTER_TOKEN": "t-test", "AI_ROUTER_CONSOLE_URL": "https://console.test"}
out = []
for name, svc in sorted(json.load(open(sys.argv[1]))["services"].items()):
    if not name.startswith("paseo"):
        continue
    env = svc.get("environment") or {}
    bad = [k for k, v in want.items() if env.get(k) != v]
    if bad:
        out.append(f"{name}: {','.join(bad)}")
print("; ".join(out))
PY
)"
n="$(python3 -c 'import json,sys; print(sum(1 for s in json.load(open(sys.argv[1]))["services"] if s.startswith("paseo")))' "$T/satellites.json")"
[ -z "$missing" ] && ok "AI_ROUTER_* reach all $n daemons (main + satellites)" \
                  || bad "AI_ROUTER_* missing or wrong: $missing"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
