#!/usr/bin/env bash
# Regression test: CLI updates must survive a container recreate.
#
# In-place updates were done with `npm install -g --prefix /usr/local`, which
# lives in the container's own layer; the systemd unit's `compose down` on
# every reboot then silently rolled every CLI back to the image's version.
# These cases lock in the fix: install once into the shared /opt/npm-global,
# restart daemons one at a time, and have the entrypoint start the daemon from
# the newer server copy.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }

# ── update-clis.sh, against a stand-in for docker ───────────────────────────
# paseo already runs its server from /opt/npm-global; paseo-2 is still on the
# image's copy, so it needs one container restart to switch.
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$*" in
  *" ps "*)                       printf 'paseo\npaseo-2\ncloudflared\n' ;;
  *"npm install"*)                exit "${FAKE_NPM_RC:-0}" ;;
  *" paseo cat /etc/paseo-server-entry") echo /opt/npm-global/lib/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js ;;
  *" paseo-2 cat /etc/paseo-server-entry") echo /usr/local/lib/node_modules/@getpaseo/server/dist/scripts/supervisor-entrypoint.js ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"
export FAKE_LOG="$T/docker.log" PATH="$T/bin:$PATH"

: > "$FAKE_LOG"
bash scripts/update-clis.sh > "$T/out" 2>&1 || true
n="$(grep -c 'npm install' "$FAKE_LOG" || true)"
[ "$n" = 1 ] && ok "installs once (the mount is shared by every daemon)" || bad "npm install ran $n times"
grep 'npm install' "$FAKE_LOG" | grep -q -- '--user paseo' && ok "installs as paseo, never root" \
  || bad "npm install not run as paseo"
grep 'npm install' "$FAKE_LOG" | grep -q -- '--prefix /opt/npm-global' \
  && ! grep -q -- '--prefix /usr/local' "$FAKE_LOG" && ok "installs into /opt/npm-global" \
  || bad "wrong npm prefix"
grep -q 'exec -T --user paseo paseo paseo daemon restart' "$FAKE_LOG" \
  && ok "paseo (already on /opt/npm-global): worker restart" || bad "paseo not worker-restarted"
grep -q 'compose --profile satellites restart paseo-2' "$FAKE_LOG" \
  && ok "paseo-2 (still on the image's server): container restart, to switch" \
  || bad "paseo-2 not container-restarted"
first="$(grep -nE 'daemon restart|restart paseo-2' "$FAKE_LOG" | head -1)"
case "$first" in *"daemon restart"*) ok "one daemon at a time, in order" ;; *) bad "restart order: $first" ;; esac
grep -q cloudflared "$FAKE_LOG" && bad "touched a non-daemon service" || ok "tunnels left alone"

: > "$FAKE_LOG"
FAKE_NPM_RC=1 bash scripts/update-clis.sh > "$T/out2" 2>&1 && bad "npm failure should fail the run" \
  || ok "npm failure fails the run"
grep -q restart "$FAKE_LOG" && bad "restarted after a failed install" || ok "restarts nothing after a failed install"

# ── entrypoint: which server the daemon starts from ─────────────────────────
# Run the entrypoint's own block with its paths pointed at a fixture tree.
if ! command -v node >/dev/null; then echo "  (node not found: entrypoint cases skipped)"; else
  E="$T/e"; mkdir -p "$E/img/dist/scripts" "$E/npm/dist/scripts"
  echo '{"version":"0.9.1"}' > "$E/img/package.json"
  echo 'console.log(1)' > "$E/img/dist/scripts/supervisor-entrypoint.js"
  echo "$E/img/dist/scripts/supervisor-entrypoint.js" > "$E/entry"
  sed -n '/^SERVER_ENTRY=/,/^fi$/p' docker/paseo/entrypoint-devstack.sh \
    | sed -e "s|/etc/paseo-server-entry|$E/entry|" \
          -e "s|/opt/npm-global/lib/node_modules/@getpaseo/server|$E/npm|" \
          -e 's|\[ "$(id -u)" = "0" \] && ||' > "$E/block.sh"
  pick() { (set -euo pipefail; log() { :; }; . "$E/block.sh"; cat "$E/entry"); }
  npm_js() { printf '%s\n' "$1" > "$E/npm/dist/scripts/supervisor-entrypoint.js"; }

  case "$(pick)" in "$E/img/"*) ok "no /opt/npm-global server: the image's" ;; *) bad "picked $(pick)" ;; esac
  echo '{"version":"0.10.0"}' > "$E/npm/package.json"; npm_js 'console.log(2)'
  case "$(pick)" in "$E/npm/"*) ok "newer /opt/npm-global server (0.10.0 > 0.9.1): that one" ;; *) bad "picked $(pick)" ;; esac
  echo '{"version":"0.9.0"}' > "$E/npm/package.json"
  case "$(pick)" in "$E/img/"*) ok "older one left after an image upgrade: never downgrades" ;; *) bad "downgraded" ;; esac
  echo '{"version":"1.0.0"}' > "$E/npm/package.json"; npm_js 'this is ( not js'
  case "$(pick)" in "$E/img/"*) ok "newer but unparsable: the image's" ;; *) bad "picked a broken server" ;; esac
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
