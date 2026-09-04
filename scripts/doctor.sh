#!/usr/bin/env bash
# Verify every component of the stack. Exits non-zero if anything is broken.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
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
         "uv --version" "git --version" "npm --version" "pnpm --version" \
         "yarn --version" "bun --version" "doctl version" "cloudflared --version" \
         "wrangler --version" "vercel --version" "flyctl version" "code --version"; do
  bin="${t%% *}"
  # Judge on EXIT CODE, not on the first line: several CLIs print a harmless
  # warning to stderr before the version (codex emits a PATH-alias warning
  # inside a container), and reading line 1 would report a working tool as
  # broken. Filter warning lines out of the version we display.
  out="$($DC exec -T --user paseo paseo bash -lc "$t" 2>&1)"; rc=$?
  ver="$(printf '%s\n' "$out" | grep -viE '^(warning|warn|note):' | grep -v '^$' | head -1)"
  if [ $rc -eq 0 ] && [ -n "$ver" ]; then ok "$bin — $ver"
  else bad "$bin — ${ver:-not found}"; fi
done

echo "── persistence (survives the /home/paseo volume mount) ──"
# `test -e` is NOT enough: it passes on a DANGLING symlink, which is exactly
# how Claude Code broke — its installer linked into /home/paseo/.local/share,
# the volume masked the target, and the link still "existed". Require an
# executable REAL file, and reject any link whose target is inside the volume.
for p in /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/cursor-agent \
         /usr/local/bin/kimi; do
  res="$($DC exec -T --user paseo paseo bash -lc '
    p="'"$p"'"
    [ -e "$p" ] || { echo missing; exit; }
    t="$(readlink -f "$p" 2>/dev/null)"
    [ -x "$t" ] || { echo dangling; exit; }
    case "$t" in /home/paseo/*) echo "involume:$t"; exit ;; esac
    echo ok' 2>/dev/null | tr -d '\r')"
  case "$res" in
    ok)         ok "$p" ;;
    missing)    bad "$p MISSING — volume masking bug" ;;
    dangling)   bad "$p is a DANGLING symlink — its target was masked by the volume" ;;
    involume:*) bad "$p points into the volume (${res#involume:}) — it will vanish on the next 'up'" ;;
    *)          bad "$p — could not verify" ;;
  esac
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
# Counting files only proves our own cp worked. What matters is that Claude
# Code is POINTED at that directory — otherwise the memories are inert.
mem="$($DC exec -T --user paseo paseo bash -lc '
  n=$(ls -1 /home/paseo/.claude/memory/*.md 2>/dev/null | wc -l | tr -d " ")
  d=$(sed -n "s/.*\"autoMemoryDirectory\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      /home/paseo/.claude/settings.json 2>/dev/null | head -1)
  echo "$n|$d"' 2>/dev/null | tr -d '\r')"
n="${mem%%|*}"; dir="${mem##*|}"
if [ "${n:-0}" -gt 0 ] && [ "$dir" = /home/paseo/.claude/memory ]; then
  ok "$n memory file(s), and settings.json points at them"
elif [ "${n:-0}" -gt 0 ]; then
  bad "$n memory file(s) but autoMemoryDirectory is '${dir:-unset}' — they will not load"
else note "memory store empty (make memory-push)"; fi

echo "── headless browser ──"
if $DC exec -T --user paseo paseo bash -lc \
     'agent-browser goto https://example.com >/dev/null 2>&1 && agent-browser snapshot 2>/dev/null | head -3' \
     | grep -qi 'example'; then ok "agent-browser rendered a page"
else bad "agent-browser could not render (check shm_size / seccomp)"; fi

echo "── paseo plugins ──"
# Copying a plugin directory is NOT registration: the daemon only knows about
# it after `paseo plugin add`. Ask the daemon, not the filesystem.
plugs="$($DC exec -T --user paseo paseo bash -lc \
  'paseo plugin ls 2>/dev/null | awk "NR>1 {print \$1, \$2}"' 2>/dev/null | tr -d '\r')"
if [ -n "$plugs" ]; then
  while read -r pid pstate; do
    [ -n "$pid" ] || continue
    case "$pstate" in
      running) ok "plugin: $pid (running)" ;;
      *)       bad "plugin: $pid is '$pstate' — registered but not loaded"
               note "usually: pluginsEnabled is false, or node_modules is missing" ;;
    esac
  done <<< "$plugs"
else
  copied="$($DC exec -T --user paseo paseo bash -lc \
    'ls -1 /home/paseo/.paseo/plugins 2>/dev/null | head -3' 2>/dev/null | tr -d '\r')"
  if [ -n "$copied" ]; then
    bad "plugin files present but NOT registered with the daemon"
    note "fix: docker compose exec --user paseo paseo /usr/local/bin/register-plugins.sh"
  else note "no plugins"; fi
fi

# The daemon defaults pluginsEnabled to FALSE; a plugin then registers but never
# loads, and `paseo plugin reload` answers "Plugins are globally disabled".
pe="$($DC exec -T --user paseo paseo bash -lc \
  'python3 -c "import json,os;print(json.load(open(os.path.expanduser(\"~/.paseo/config.json\"))).get(\"pluginsEnabled\"))"' 2>/dev/null | tr -d '\r')"
[ "$pe" = True ] && ok "pluginsEnabled=true" \
                 || bad "pluginsEnabled=$pe — plugins will never load"

# Where new projects land. Paseo has no projectRoot setting, so the default is
# $HOME — inside the volume, invisible from the host. Warn if projects are there.
stray="$($DC exec -T --user paseo paseo bash -lc \
  'paseo project ls 2>/dev/null | awk "NR>1 && \$4 ~ /^\/home\/paseo/ {print \$2}"' 2>/dev/null | tr -d '\r' | head -3)"
if [ -n "$stray" ]; then
  note "project(s) outside /workspace: $(echo "$stray" | tr '\n' ' ')"
  note "  those live in the volume and are NOT visible on the host — prefer /workspace/<name>"
else ok "all projects are under /workspace (visible on the host)"; fi

echo "── daemon identity ──"
hn="$($DC exec -T --user paseo paseo bash -lc 'hostname' 2>/dev/null | tr -d '\r')"
case "$hn" in
  [0-9a-f]??????????) bad "daemon name is the container id ($hn) — set PASEO_NAME in .env" ;;
  "") note "could not read the daemon hostname" ;;
  *)  ok "daemon name: $hn (shown when pairing)" ;;
esac

echo "── file ownership ──"
# Root-owned files inside the repo or the volume are the single most common
# cause of "the daemon starts but sees nothing".
owner="$(stat -c %U . 2>/dev/null || stat -f %Su .)"
stray="$(find . -maxdepth 2 -user root -not -path './.git/*' 2>/dev/null | head -5)"
if [ -z "$stray" ]; then ok "repo is owned by $owner, no root-owned files"
else
  bad "root-owned files in the repo (the daemon runs as $owner and cannot write these):"
  printf '%s\n' "$stray" | sed 's/^/      /'
  note "fix: sudo chown -R $owner:$owner ."
fi

echo "── memory guards ──"
if command -v systemctl >/dev/null 2>&1; then
  for t in devserver-guard cache-trim; do
    if systemctl is-enabled "$t.timer" >/dev/null 2>&1; then ok "$t.timer enabled"
    else note "$t.timer not installed (make guards)"; fi
  done
else note "no systemd — guards are Linux-host only (run 'make guards-dry' to preview)"; fi
lim="$($DC exec -T --user paseo paseo bash -lc \
  'cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max' 2>/dev/null | tr -d '\r')"
if [ "$lim" = max ] || [ -z "$lim" ]; then
  note "container memory: unlimited (set PASEO_MEM_LIMIT in .env to cap it)"
else ok "container memory capped at $(( lim / 1024 / 1024 / 1024 ))GB"; fi
avail="$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null)"
[ -n "$avail" ] && ok "host memory available: ${avail}GB"

echo "── tunnel ──"
if $DC ps --format '{{.Service}}' 2>/dev/null | grep -q cloudflared; then
  ok "a cloudflared container is running"
  $DC logs cloudflared-quick 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
else note "no tunnel running (make tunnel | make quick-tunnel)"; fi

echo
[ $fail -eq 0 ] && echo "all checks passed" || echo "some checks FAILED"
exit $fail
