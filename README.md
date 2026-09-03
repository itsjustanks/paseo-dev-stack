# devstack

One repo that stands up a complete AI coding environment — on a fresh server or
on your laptop — with a single command.

```bash
sudo ./scripts/bootstrap-server.sh     # fresh server: user, docker, swap, firewall
cp .env.example .env && $EDITOR .env   # set PASEO_PASSWORD
make up                                # build + start everything
make auth-all                          # log in to each agent CLI
make doctor                            # verify
```

## What you get

| Component | What it is |
|---|---|
| **Paseo** | Agent orchestration UI on `:6767`, running agents as the non-root `paseo` user |
| **9router** | Model routing / multi-account failover on `:20128` |
| **Cloudflare Tunnel** | Public HTTPS with **no inbound firewall hole** — named or throwaway |
| **agent-browser** | Headless Chromium for agents, Chrome baked into the image |
| **Auto-memory** | Claude Code's persistent memory, seeded from `./memory/` and kept on a volume |
| **Agent CLIs** | Claude Code · Codex · Kimi Code · Cursor Agent |
| **Dev tools** | Supabase CLI · gh · git · Node 22 · Python 3 + uv · ripgrep · jq |

## Why it is built this way

**Agents can't run as root.** Claude Code and Codex refuse elevated/bypass
permission modes as root, so both the host bootstrap and the container run
everything as an unprivileged `paseo` user (uid 1000 on both sides, so
bind-mounted files line up).

**The `/home/paseo` volume masks build-time installs.** The Paseo base image
declares `VOLUME /home/paseo`, and every agent installer writes into `$HOME`.
Installed normally, the CLIs would vanish the moment the volume mounted. The
image installs them with `HOME=/opt/agent-home` and symlinks binaries into
`/usr/local/bin`, so the volume carries only credentials, config, and memory —
exactly what should persist. `make doctor` asserts this hasn't regressed.

**Nothing is published publicly.** Both ports bind to `127.0.0.1`; the only way
in is the Cloudflare tunnel, which dials outward. This matters because Docker's
iptables rules **bypass UFW** — a `ufw deny` would not protect a port published
to `0.0.0.0`. The 127.0.0.1 binds are the actual protection.

## Configuration

Everything lives in `.env` (gitignored). The essentials:

| Variable | Notes |
|---|---|
| `PASEO_PASSWORD` | **Required.** Web UI / API / websocket auth. |
| `PASEO_HOSTNAMES` | **Required for tunnels.** Your public hostname, or Paseo rejects the connection. |
| `NINEROUTER_KEY` | Mint in the dashboard after first boot, then `make restart`. |
| `TUNNEL_TOKEN` | From Cloudflare Zero Trust → Networks → Tunnels. Blank = use `make quick-tunnel`. |

### Wiring up 9router

Chicken-and-egg: the key only exists after the dashboard is running.

```bash
make up
make router                       # prints the dashboard URL (default pw: 123456 — change it)
# create a key, then put it in .env as NINEROUTER_KEY
make restart
```

Agents then reach it at `http://9router:20128` — the internal service name,
which does not change when the public hostname does.

### Exposing it publicly

**Named tunnel** (persistent hostname, supports Cloudflare Access):

```bash
# Zero Trust → Networks → Tunnels → Create → Docker; copy the token
echo 'TUNNEL_TOKEN=eyJ...'            >> .env
echo 'PASEO_HOSTNAMES=paseo.you.com'  >> .env   # required, or Paseo refuses
make tunnel && make restart
```

Point the tunnel's public hostname at `http://paseo:6767`. Websockets work
without extra configuration.

**Quick tunnel** (no account, random URL, **no authentication** — dev only):

```bash
make quick-tunnel     # prints the trycloudflare.com URL
```

## Auto-memory

Claude Code's auto-memory is plain markdown — a `MEMORY.md` index plus one file
per fact, no database. `settings.json` pins `autoMemoryDirectory` to
`/home/paseo/.claude/memory` so it's stable regardless of workspace path.

```bash
make memory-push    # ./memory/  -> container
make memory-pull    # container  -> ./memory/   (then commit)
```

Only `MEMORY.md` (first 200 lines / 25KB) loads at session start; topic files
are read on demand.

## Commands

Run `make` for the full list. Most-used:

```
make up | down | restart      start / stop / restart
make shell                    shell in the container as paseo
make root                     root shell (apt installs)
make logs S=paseo             tail one service
make doctor                   verify every component
make browser-test             smoke-test headless Chromium
make nuke                     delete everything incl. credentials
```

## Troubleshooting

**Agent CLI "not found" after a rebuild** — the volume-masking guard failed.
`make doctor` reports it; check the `HOME=/opt/agent-home` lines in the Dockerfile.

**Paseo refuses a tunnel connection** — the hostname isn't in `PASEO_HOSTNAMES`.
Add it and `make restart`.

**Headless Chromium crashes** — needs more than the default 64MB `/dev/shm`;
compose sets `shm_size: 1gb`.

**Empty workspace list after a restart** — ownership on `/home/paseo`. The
entrypoint fixes it on boot; if you wrote files in as root, `make root` then
`chown -R paseo:paseo /home/paseo`.

**Credentials gone after `make clean`** — they shouldn't be; `clean` keeps
volumes. Only `make nuke` deletes them.
