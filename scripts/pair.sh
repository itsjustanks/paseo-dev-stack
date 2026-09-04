#!/usr/bin/env bash
# Print the Paseo pairing link / QR for this deployment.
#
# `paseo daemon pair` emits a link pointing at the daemon's OWN address. Inside
# a container that address is the container's, which no phone or laptop can
# reach — so we also print the routes that actually work from outside.
set -euo pipefail
cd "$(dirname "$0")/.."
DC="docker compose"

port="$(grep -E '^PASEO_PORT=' .env 2>/dev/null | cut -d= -f2)"; port="${port:-6767}"

# --relay is required: without it the daemon refuses to emit a pairing link
# ("Relay pairing is disabled for this daemon"). Relay is what lets a phone or
# a laptop on another network reach this daemon without a public port.
RELAY=""
[ "${1:-}" = "--no-relay" ] || RELAY="--relay"

echo "── pairing ──"
$DC exec -T --user paseo paseo bash -lc "paseo daemon pair $RELAY 2>&1" || {
  echo "  could not reach the daemon — is it running? (make up)"; exit 1; }

echo
echo "── reaching this daemon from another device ──"
echo
echo "  1. SSH tunnel (works anywhere, nothing public):"
echo "       ssh -N -L ${port}:127.0.0.1:${port} ${USER:-paseo}@<this-host>"
echo "       then pair against http://127.0.0.1:${port}"
echo

url="$($DC logs cloudflared-quick 2>/dev/null \
       | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
if [ -n "$url" ]; then
  echo "  2. Public tunnel (live now):"
  echo "       $url"
else
  echo "  2. Public tunnel (not running):"
  echo "       make quick-tunnel     # throwaway URL, no account, NO AUTH"
  echo "       make tunnel           # named Cloudflare tunnel"
fi
echo
echo "  Whichever hostname you pair against MUST be in PASEO_HOSTNAMES in .env,"
echo "  or the daemon rejects the connection with 'Invalid Host header'."
