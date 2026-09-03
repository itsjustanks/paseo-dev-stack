#!/usr/bin/env bash
# Verify every component of the stack. Exits non-zero if anything is broken.
set -uo pipefail
cd "$(dirname "$0")/.."
DC="docker compose"; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
note() { printf '  \033[33m·\033[0m %s\n' "$*"; }

echo "── containers ──"
for s in paseo 9router; do
  st="$($DC ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s="$s" '$1==s{print $2}')"
  [ "$st" = running ] && ok "$s running" || bad "$s not running (state: ${st:-absent})"
done

echo "── agent CLIs ──"
for t in "claude --version" "codex --version" "kimi --version" \
         "cursor-agent --version" "supabase --version" "gh --version" \
         "agent-browser --version" "node --version" "python3 --version" \
         "uv --version" "git --version"; do
  bin="${t%% *}"
  out="$($DC exec -T --user paseo paseo bash -lc "$t" 2>&1 | head -1)"
  if [ $? -eq 0 ] && [ -n "$out" ]; then ok "$bin — $out"; else bad "$bin — ${out:-not found}"; fi
done

echo "── persistence (survives the /home/paseo volume mount) ──"
for p in /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/cursor-agent; do
  $DC exec -T --user paseo paseo test -e "$p" 2>/dev/null \
    && ok "$p present" || bad "$p MISSING — volume masking bug"
done

echo "── 9router ──"
code="$($DC exec -T --user paseo paseo bash -lc \
  'curl -s -o /dev/null -w "%{http_code}" http://9router:20128/api/health' 2>/dev/null)"
[ "$code" = 200 ] && ok "reachable from the agent container (HTTP $code)" \
                  || bad "not reachable from the agent container (HTTP ${code:-none})"
grep -q '^NINEROUTER_KEY=.\+' .env 2>/dev/null \
  && ok "NINEROUTER_KEY set in .env" \
  || note "NINEROUTER_KEY empty — agents will use their own OAuth login"

echo "── auto-memory ──"
n="$($DC exec -T --user paseo paseo bash -lc \
  'ls -1 /home/paseo/.claude/memory/*.md 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')"
[ "${n:-0}" -gt 0 ] && ok "$n memory file(s)" || note "memory store empty (make memory-push)"

echo "── headless browser ──"
if $DC exec -T --user paseo paseo bash -lc \
     'agent-browser goto https://example.com >/dev/null 2>&1 && agent-browser snapshot 2>/dev/null | head -3' \
     | grep -qi 'example'; then ok "agent-browser rendered a page"
else bad "agent-browser could not render (check shm_size / seccomp)"; fi

echo "── tunnel ──"
if $DC ps --format '{{.Service}}' 2>/dev/null | grep -q cloudflared; then
  ok "a cloudflared container is running"
  $DC logs cloudflared-quick 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
else note "no tunnel running (make tunnel | make quick-tunnel)"; fi

echo
[ $fail -eq 0 ] && echo "all checks passed" || echo "some checks FAILED"
exit $fail
