# devstack

One repo that stands up a complete AI coding environment — on a fresh cloud
server, in a CI/CD pipeline, or on your Mac — with a single command.

```bash
curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | sudo bash
```

That creates the service user, installs Docker, adds swap, configures the
firewall, builds the image, and starts everything. Then:

```bash
cd ~/paseo-dev-stack
make auth-all      # log in to each agent CLI
make doctor        # verify every component
make quick-tunnel  # get a public URL
```

## Prerequisites

| | Needed | Notes |
|---|---|---|
| **Cloud server** | Ubuntu/Debian, 4GB+ RAM, 20GB+ disk | The installer adds everything else. 8GB+ if you run dev servers — a single Next dev server uses 6-11GB while compiling. |
| **Existing host** | Docker Engine 24+ and the compose **plugin** | `docker compose version` must work. `docker-compose` (the old standalone binary) is not enough. |
| **macOS** | Docker Desktop, OrbStack, or Colima | Colima needs `brew install docker-compose` separately; Desktop and OrbStack bundle it. |
| **All** | git, ~10GB free for the image | The build pulls Chrome (~150MB) and several toolchains. |
| **Optional** | Cloudflare account | Only for a *named* tunnel. `make quick-tunnel` needs no account. |

Nothing else is required up front. Agent logins happen after the stack is up,
interactively, via `make auth-all`.

## Install by device

**Fresh Ubuntu/Debian server (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | sudo bash
```

**DigitalOcean / Hetzner / any cloud — paste into "User data" at creation:**

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | bash
```

**macOS (Docker Desktop / OrbStack / Colima):**

```bash
git clone https://github.com/itsjustanks/paseo-dev-stack
cd paseo-dev-stack && ./install.sh          # no sudo; skips user/firewall/swap setup
```

**Already-provisioned host or CI/CD runner:**

```bash
git clone https://github.com/itsjustanks/paseo-dev-stack && cd paseo-dev-stack
cp .env.example .env && $EDITOR .env        # set PASEO_PASSWORD
make up
```

**Windows:** use WSL2 and follow the Ubuntu instructions inside it.

## Install targets

**DigitalOcean / any cloud — paste into "User data" at droplet creation:**

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | bash
```

The droplet comes up with the whole stack running. Generated passwords are left
in `/root/paseo-dev-stack-credentials.txt`, and a `devstack.service` systemd unit
brings it back after a reboot. Pre-seed anything you like:

```bash
#!/bin/bash
export PASEO_PASSWORD='...' TUNNEL_TOKEN='eyJ...' PASEO_HOSTNAMES='paseo.you.com'
curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | bash
```

**Existing server / CI-CD pipeline** (elest.io, Coolify, a runner — anything with
Docker):

```bash
git clone https://github.com/itsjustanks/paseo-dev-stack && cd paseo-dev-stack
sudo ./install.sh                 # full host setup
# or, if the host is already prepared:
cp .env.example .env && $EDITOR .env && make up
```

**macOS** (Docker Desktop, OrbStack, or Colima):

```bash
git clone https://github.com/itsjustanks/paseo-dev-stack && cd paseo-dev-stack
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
| **Memory guards** | Reaps runaway Next dev servers and trims the caches that feed them |

## Repo layout

Declarative where it can be, with each concern in its own file — nothing is a
monolithic shell script.

```
docker-compose.yml        the stack: services, ports, volumes, networks
.env.example              every knob, documented (copy to .env)
docker/paseo/
  Dockerfile              the agent image
  entrypoint-devstack.sh  first-boot seeding, then hands off to Paseo's entrypoint
  agent-env.sh            shell env for interactive sessions
config/                   seed config, copied in on first boot only
  claude/settings.json    auto-memory dir, permissions, output style
  codex/config.toml       9router provider block
memory/                   auto-memory seeds, version-controlled
scripts/
  bootstrap-server.sh     host prep: user, docker, swap, firewall
  doctor.sh               verifies every component; exits non-zero on failure
  sync-memory.sh          memory push/pull between repo and container
  guard/
    devserver-guard.py    reaps ballooned/stale/orphaned Next dev servers
    cache-trim.py         trims .next/dev and stale .turbo caches
    install-guards.sh     installs both as systemd timers
install.sh                thin entrypoint: detects OS, delegates to the above
Makefile                  the command surface (make up / doctor / tunnel ...)
```

Change behaviour by editing `.env` or `docker-compose.yml`, not by forking a
script. `make doctor` is the test suite.

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

## Memory guards

A Next dev server's memory is **native** — Turbopack is Rust, so it lives
outside the V8 heap and `NODE_OPTIONS=--max-old-space-size` cannot bound it. One
was measured at 21GB. Worse, `next dev` supervises `next-server` and restarts it
when it dies, so a ballooning server becomes an infinite grow → get killed →
respawn loop. Killing the child alone never works; the parent must go first.

Three layers handle this:

| Layer | What it does |
|---|---|
| `PASEO_MEM_LIMIT` | cgroup ceiling on the whole container — the only *hard* cap |
| `devserver-guard` | every 60s, reaps dev servers that balloon (>12GB), go stale (>2h), get orphaned, or pile up under real memory pressure |
| `cache-trim` | daily, removes `.next/dev` and stale `.turbo/cache` — also a memory fix, since Turbopack memory-maps that cache at startup |

```bash
make guards          # install the systemd timers (Linux host)
make guards-status   # timers + recent reaps
make guards-dry      # preview what they WOULD do, changing nothing
make mem             # host, container, and dev-server memory right now
```

The guard is deliberately conservative:

- It **never** touches Paseo, 9router, an agent CLI, or a VS Code tunnel —
  matched on the **parent chain**, not just the process's own command line.
  (9router's dashboard is itself a Next app, so a naive matcher reaps the live
  model router every 60s and every routed agent loses its connection.)
- The 12GB cap is not arbitrary: a first compile legitimately uses 6-11GB, so
  a 6GB cap kills it mid-compile and surfaces as "next-server keeps crashing".
  Age is what actually catches leaks — a leak stays big, a compile only spikes.
- Count-based reaping only fires under **real pressure**; two idle servers are
  harmless.
- A failed process scan **aborts the pass** rather than guessing. Collapsing
  "no match" and "scan failed" into one empty list is how a watchdog
  half-kills a live process tree.

On macOS these run as launchd agents outside this repo; `make guards-dry` and
`make mem` still work there.

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
