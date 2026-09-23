#!/usr/bin/env bash
# Regression test: make migrate-ai-router strips exactly the 9router leftovers.
#
# On a migrated host, Claude's settings.json still held ANTHROPIC_BASE_URL /
# _AUTH_TOKEN / _DEFAULT_*_MODEL and Codex's config.toml still selected the
# 9router provider (the old `make router-on` output). Both silently override
# the AI Router plugin; one daemon's Codex answered 401 for hours. These cases
# run the real scripts against fixture homes, with a stand-in for docker.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
CORE="$PWD/scripts/lib/router-leftovers.py"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
has()  { grep -qF -- "$2" "$1"; }

# A home as `make router-on` left it, plus things that must survive.
make_home() {
  local h="$1"
  mkdir -p "$h/.claude" "$h/.codex"
  cat > "$h/.claude/settings.json" <<'JSON'
{
  "autoMemoryDirectory": "/home/paseo/.claude/memory",
  "permissions": { "allow": ["Bash(git:*)"] },
  "env": {
    "ANTHROPIC_BASE_URL": "http://9router:20128",
    "ANTHROPIC_AUTH_TOKEN": "sk-9router-secret",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "cc/claude-opus",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "cc/claude-sonnet",
    "KEEP_ME": "1"
  }
}
JSON
  cat > "$h/.codex/config.toml" <<'TOML'
model = "gpt-5"
model_provider = "9router"

[model_providers.9router]
name     = "9router"
base_url = "http://9router:20128/v1"
env_key  = "NINEROUTER_KEY"

[model_providers."9router-responses"]
base_url = "http://9router:20128/v1"

# my own provider — keep this comment
[model_providers.mine]
base_url = "https://example.test/v1"

[profiles.work]
model_provider = "9router"
model = "o4"
TOML
  # Login files. They mention the same names, so an edit would show.
  printf '{"token":"ANTHROPIC_BASE_URL keep"}\n' > "$h/.claude/.credentials.json"
  printf '{"auth":"model_provider = \\"9router\\""}\n' > "$h/.codex/auth.json"
}
sums() { (cd "$1" && find . -type f ! -name '*.bak.*' | sort | xargs cksum) ; }

# ── 1. Strips exactly the leftovers ─────────────────────────────────────────
H="$T/home"; make_home "$H"
logins_before="$(cd "$H" && cksum .claude/.credentials.json .codex/auth.json)"
python3 "$CORE" "$H" > "$T/out1"
s="$H/.claude/settings.json"; c="$H/.codex/config.toml"
if grep -q 'ANTHROPIC_' "$s"; then bad "settings.json still has ANTHROPIC_*"; else ok "settings.json: ANTHROPIC_* routing removed"; fi
has "$s" '"KEEP_ME": "1"' && has "$s" autoMemoryDirectory && has "$s" 'Bash(git:*)' \
  && ok "settings.json: every other key kept" || bad "settings.json lost unrelated keys"
if grep -q '9router' "$c"; then bad "config.toml still mentions 9router: $(grep 9router "$c" | tr '\n' ' ')"
else ok "config.toml: provider, both 9router tables and the profile's provider removed"; fi
has "$c" 'model = "gpt-5"' && has "$c" '[model_providers.mine]' && has "$c" 'https://example.test/v1' \
  && has "$c" '# my own provider — keep this comment' && has "$c" '[profiles.work]' && has "$c" 'model = "o4"' \
  && ok "config.toml: other providers, profiles and comments kept" || bad "config.toml lost unrelated content"
[ "$(ls "$H/.claude"/settings.json.bak.* "$H/.codex"/config.toml.bak.* 2>/dev/null | wc -l | tr -d ' ')" = 2 ] \
  && has "$(ls "$H/.claude"/settings.json.bak.*)" 'sk-9router-secret' \
  && ok "one backup per changed file, holding the original" || bad "backups missing or wrong"
[ "$(cd "$H" && cksum .claude/.credentials.json .codex/auth.json)" = "$logins_before" ] \
  && ok "login files untouched" || bad "a login file changed"
grep -q 'sk-9router-secret' "$T/out1" && bad "summary printed the token" || ok "summary never prints the token"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$s" && ok "settings.json is still valid JSON" \
  || bad "settings.json is no longer valid JSON"

# ── 2. Idempotent ───────────────────────────────────────────────────────────
before="$(sums "$H")"
python3 "$CORE" "$H" > "$T/out2"
[ "$(sums "$H")" = "$before" ] && [ "$(find "$H" -name '*.bak.*' | wc -l | tr -d ' ')" = 2 ] \
  && ok "second run changes nothing and makes no backup" || bad "second run changed files"
[ "$(grep -c ' clean$' "$T/out2")" = 2 ] && ok "second run reports both files clean" \
  || bad "second run output: $(tr '\n' '|' < "$T/out2")"

# ── 3. --check reports without writing ──────────────────────────────────────
H2="$T/home2"; make_home "$H2"; before="$(sums "$H2")"
rc=0; python3 "$CORE" --check "$H2" > /dev/null || rc=$?
[ "$rc" = 1 ] && [ "$(sums "$H2")" = "$before" ] && ok "--check exits 1 on leftovers and writes nothing" \
  || bad "--check rc=$rc or it wrote"
rc=0; python3 "$CORE" --check "$H" > /dev/null || rc=$?
[ "$rc" = 0 ] && ok "--check exits 0 once clean" || bad "--check rc=$rc on a clean home"

# ── 4. Missing and unreadable files are left alone ──────────────────────────
H3="$T/home3"; mkdir -p "$H3/.claude"; echo '{ not json' > "$H3/.claude/settings.json"
python3 "$CORE" "$H3" > "$T/out3"
[ "$(cat "$H3/.claude/settings.json")" = '{ not json' ] && has "$T/out3" 'left alone' \
  && has "$T/out3" 'absent' && ok "broken JSON left alone; a missing file is reported absent" \
  || bad "broken or missing files mishandled: $(tr '\n' '|' < "$T/out3")"

# ── 5. The wrapper covers every running daemon ──────────────────────────────
# Stand-ins: docker runs the in-container command locally, with /home/paseo
# mapped to a fixture home per service; paseo keeps a plugin list per home.
mkdir -p "$T/bin" "$T/homes"
make_home "$T/homes/paseo"; make_home "$T/homes/paseo-2"
echo agent-link-9router > "$T/homes/paseo/.plugins"; : > "$T/homes/paseo-2/.plugins"
mkdir -p "$T/homes/paseo/.paseo/plugins/9router/apps/paseo"   # the old image's copy
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
shift; [ "$1" = "--profile" ] && shift 2           # compose --profile satellites
case "$1" in
  ps)   printf 'paseo\ncloudflared\npaseo-2\n'; exit 0 ;;
  exec) shift
        while [ "${1#-}" != "$1" ]; do [ "$1" = --user ] && shift; shift; done
        svc="$1"; shift
        args=(); for a in "$@"; do [ "$a" = /home/paseo ] && a="$FAKE_HOMES/$svc"; args+=("$a"); done
        SVC="$svc" exec "${args[@]}" ;;
esac
EOF
cat > "$T/bin/paseo" <<'EOF'
#!/usr/bin/env bash
f="$FAKE_HOMES/$SVC/.plugins"
case "$1 $2" in
  "plugin ls")     echo "PLUGIN STATUS"; sed 's/$/ running/' "$f" ;;
  "plugin remove") grep -vx "$3" "$f" > "$f.tmp" || true; mv "$f.tmp" "$f" ;;
esac
EOF
chmod +x "$T/bin/docker" "$T/bin/paseo"
export FAKE_LOG="$T/docker.log" FAKE_HOMES="$T/homes" PATH="$T/bin:$PATH"

bash scripts/migrate-ai-router.sh > "$T/w1" 2>&1 || true
for d in paseo paseo-2; do
  grep -q 'ANTHROPIC_' "$T/homes/$d/.claude/settings.json" || grep -q 9router "$T/homes/$d/.codex/config.toml" \
    && bad "$d not migrated" || ok "$d migrated"
done
grep -q cloudflared "$FAKE_LOG" && bad "touched a non-daemon service" || ok "tunnels and other services skipped"
[ ! -s "$T/homes/paseo/.plugins" ] && grep -qE 'plugin agent-link-9router +removed' "$T/w1" \
  && ok "old plugin removed where it was registered" || bad "plugin not removed: $(tr '\n' '|' < "$T/w1")"
[ ! -e "$T/homes/paseo/.paseo/plugins/9router" ] \
  && ls -d "$T/homes/paseo/.paseo"/9router-plugin.bak.* >/dev/null 2>&1 \
  && ok "old vendored copy moved aside, not deleted" || bad "vendored copy not moved aside"
grep -q -- '--user paseo' "$FAKE_LOG" && ! grep -q -- '--user root' "$FAKE_LOG" \
  && ok "runs as paseo, never root" || bad "ran as the wrong user"

rc=0; bash scripts/migrate-ai-router.sh --check > "$T/w2" 2>&1 || rc=$?
[ "$rc" = 0 ] && has "$T/w2" 'clean: no 9router routing left' && ok "--check across daemons is clean after a run" \
  || bad "--check after migrate: rc=$rc $(tail -3 "$T/w2" | tr '\n' '|')"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
