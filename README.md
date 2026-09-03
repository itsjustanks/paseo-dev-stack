# devstack

One repo that stands up a complete AI coding environment — on a fresh cloud
server, in a CI/CD pipeline, or on your Mac — with a single command.

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/devstack/main/install.sh | sudo bash
```

That creates the service user, installs Docker, adds swap, configures the
firewall, builds the image, and starts everything. Then:

```bash
cd ~/devstack
make auth-all      # log in to each agent CLI
make doctor        # verify every component
make quick-tunnel  # get a public URL
```

## Install targets

**DigitalOcean / any cloud — paste into "User data" at droplet creation:**

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/OWNER/devstack/main/install.sh | bash
```

The droplet comes up with the whole stack running. Generated passwords are left
in `/root/devstack-credentials.txt`, and a `devstack.service` systemd unit
brings it back after a reboot. Pre-seed anything you like:

```bash
#!/bin/bash
export PASEO_PASSWORD='...' TUNNEL_TOKEN='eyJ...' PASEO_HOSTNAMES='paseo.you.com'
curl -fsSL https://raw.githubusercontent.com/OWNER/devstack/main/install.sh | bash
```

**Existing server / CI-CD pipeline** (elest.io, Coolify, a runner — anything with
Docker):

```bash
git clone https://github.com/OWNER/devstack && cd devstack
sudo ./install.sh                 # full host setup
# or, if the host is already prepared:
cp .env.example .env && $EDITOR .env && make up
```

**macOS** (Docker Desktop, OrbStack, or Colima):

```bash
git clone https://github.com/OWNER/devstack && cd devstack
./install.sh                      # no sudo, no user/firewall changes
```

The installer detects the OS and skips privileged host setup on a Mac.

## What you get

| Component | What it is |
|---|---|
| **Paseo** | Agent orchestration UI on `:6767`, running agents as the non-root `paseo` user |
| **9router** | Model routing / multi-account failover on `:20128` |
| **Cloudflare Tunnel** | Public HTTPS with **no inbound firewall hole** — named or throwaway |
| **agent-browser** | Headless Chromium for agents, Chrome baked into the image |
| **Auto-memory** | Claude Code's persistent memory, seeded from `./memory/` and kept on a volume |
| **VS Code dev tunnels** | `code tunnel` → edit the box from vscode.dev in a browser |
| **9router Paseo plugin** | Accounts, quotas and models in the Paseo sidebar |
| **Agent CLIs** | Claude Code · Codex · Kimi Code · Cursor Agent |
| **Dev tools** | Supabase CLI · gh · git · Node 22 · Python 3 + uv · ripgrep · jq |

## Why it is built this way

**Agents can't run as root.** Claude Code and Codex refuse elevated/bypass
permission modes as root, so both the host bootstrap and the container run
everything as an unprivileged `paseo` user — uid 1000 on both sides, so
bind-mounted files line up. Ubuntu cloud images ship an `ubuntu` user already
holding uid 1000; the bootstrap moves it aside (only when it has no running
processes) so `paseo` can claim it. Opt out with `DEVSTACK_TAKE_UID1000=0`.

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
make code-tunnel              VS Code dev tunnel -> vscode.dev
make quick-tunnel             public URL, no account needed
make nuke                     delete everything incl. credentials
```

### VS Code dev tunnels

Edit the server from a browser, with no inbound port and no VPN:

```bash
make code-tunnel        # device login, then prints a vscode.dev/tunnel/... URL
make code-tunnel-bg     # same, backgrounded
make code-tunnel-url    # print the URL again
```

The tunnel is Microsoft's own; the container dials out to it. Your code at
`/workspace` and every agent CLI are available in that browser IDE.

### 9router Paseo plugin

The image vendors [paseo-plugin-9router](https://github.com/itsjustanks/paseo-plugin-9router)
and the entrypoint registers it on first boot (into `~/.paseo`, which is on the
volume — so it cannot be done at build time). It adds a **9Router** sidebar
panel: setup checklist, per-account quota bars, parked-account recovery, and the
model list. Pin a version with `--build-arg PLUGIN_9ROUTER_REF=v1.2.3`.

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
