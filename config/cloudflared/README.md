# Cloudflare tunnel routes

With a **named** tunnel (`TUNNEL_TOKEN` set), routes are configured in the
Cloudflare dashboard, not in a file — Zero Trust → Networks → Tunnels → your
tunnel → **Public Hostnames**.

Point each hostname at a container by its **service name** on the compose
network. Docker resolves these internally, so they do not change when your
public hostname does:

| Public hostname | Service | Notes |
|---|---|---|
| `paseo.example.com` | `http://paseo:6767` | The main daemon UI. |
| `router.example.com` | `http://9router:20128` | The 9router dashboard. **Put Cloudflare Access in front of this** — it holds your subscription accounts. |
| `paseo-2.example.com` | `http://paseo-2:6767` | A satellite daemon (`--profile satellites`). |
| `browser.example.com` | `http://paseo:9224` | agent-browser live view (WebSocket; works over the tunnel). |

Then add every hostname to `PASEO_HOSTNAMES` in `.env` and `make restart`, or
Paseo answers `403 {"error":"Invalid Host header"}`.

## Locally-managed tunnel (config file instead of the dashboard)

If you would rather keep routes in git, run `cloudflared tunnel login` and
`cloudflared tunnel create <name>`, drop the credentials JSON in this directory,
and use a `config.yml` like:

```yaml
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: paseo.example.com
    service: http://paseo:6767
  - hostname: router.example.com
    service: http://9router:20128
  - hostname: browser.example.com
    service: http://paseo:9224
  # A catch-all rule is REQUIRED and must be last, or cloudflared refuses to start.
  - service: http_status:404
```

Mount it into the `cloudflared` service and change its command to
`tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`.

**The credentials JSON and `cert.pem` are gitignored — never commit them.**
