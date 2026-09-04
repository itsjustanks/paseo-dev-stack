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
| **Cloud CLIs** | doctl · cloudflared · wrangler · vercel · netlify · flyctl · supabase · gh |
| **Dev tools** | git · Node 22 · Python 3 + uv · ripgrep · jq · build-essential |
| **Memory guards** | Reaps runaway Next dev servers and trims the caches that feed them |
| **Control panel** | `make tui` — services, memory, logins, tunnels in one screen |

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

## Watching the browser remotely

`agent-browser` runs headless, but you can watch what it sees — and click and
type into it — from another machine:

```bash
make browser-open U=https://example.com   # open a page
make browser-view                         # open the live viewer locally
```

The stream is a WebSocket on `127.0.0.1` only, so reach it over SSH:

```bash
ssh -N -L 9223:127.0.0.1:9223 paseo@<host>
```

> agent-browser binds that socket to the **container's** loopback with no
> bind-address option, so Docker cannot publish it directly — a `-p` mapping
> connects to nothing and the client gets `ECONNRESET`. The image runs a tiny
> bridge (`0.0.0.0:9224 → 127.0.0.1:9223`) so the port is publishable; the host
> side stays bound to localhost.

Tune bandwidth with `AGENT_BROWSER_STREAM_QUALITY` and the `MAX_WIDTH`/
`MAX_HEIGHT` caps — at 1280×720, quality 80 is ~54KB/frame and quality 20 at
640×360 is ~9KB.

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

## Staying current

```bash
make version        # installed version (repo + image)
make update         # what a newer release would change — nothing is touched
make update-apply   # pull, merge new .env keys, rebuild, restart
```

The `.env` merge only **appends keys you do not have**; your existing values
are never rewritten, including ones containing `=`, `#`, or spaces. Docker
volumes are never touched, so agent logins survive every update.

Releases publish a prebuilt image to `ghcr.io/itsjustanks/paseo-dev-stack`.

> **First release only:** GHCR packages are created **private**. After the first
> tag, make it public at
> `github.com/users/itsjustanks/packages/container/paseo-dev-stack/settings`
> → *Change visibility* → Public. Until then `docker pull` fails for everyone
> (including you, without a token), and the stack silently falls back to
> building locally — which still works, just slower.

Both `linux/amd64` and `linux/arm64` are built, each on a **native** runner and
then merged into one manifest — not via QEMU emulation. The image installs five
agent CLIs from `curl | bash` installers plus an `npm install -g`; emulated,
every one of those runs interpreted and the build goes from ~10 minutes to over
an hour.

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
make tui                      the control panel
make pair                     Paseo pairing link
make agents                   list installed agent CLIs
make autotune                 size memory to this host
make update                   check for a newer release
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

## The control panel

```bash
pds            # from anywhere, as any user — including root
make tui       # from inside the repo
```

`pds` is installed to `/usr/local/bin`. It finds the deployment, then
re-executes as the user that owns it — so running it as root does **not**
create root-owned files, which is the usual way this kind of stack breaks
(the daemon runs as uid 1000 and then cannot read its own state).

Seven tabs, switched with `1`-`7` or `Tab`:

| | Tab | What you do there |
|---|---|---|
| `1` | status | services, health, ports; `u` up, `d` down, `r` restart, `l` logs, `s` shell |
| `2` | memory | host + container memory, dev servers; `K` kill one, `g` guards |
| `3` | auth | which agent CLIs are logged in; `Enter` one, `A` all of them |
| `4` | tunnels | `q` quick, `n` named, `v` vscode, `c` copy URL, `x` stop |
| `5` | logs | live tail; `f` follow, `s` pick service |
| `6` | doctor | full verification, run in place |
| `7` | guards | memory-guard timers and recent reaps |

`?` shows every key. Interactive actions (agent logins, shells) hand the
terminal to the real program and take it back cleanly on exit.

One screen for the whole stack: live service health, host and per-container
memory, running dev servers, public tunnel URLs, and single-key actions for
everything below. It is plain Python + curses — no `pip install`, nothing to
break on a fresh box.

Interactive actions (agent logins, shells, log tails) hand the terminal over to
the real program and take it back cleanly when you exit.

## Agents

Four agent CLIs ship in the image: **Claude Code**, **Codex**, **Kimi Code**,
and **Cursor Agent**. Log in to each once — credentials live on the volume and
survive restarts and rebuilds:

```bash
make auth-all         # or: make auth-claude / auth-codex / auth-kimi / auth-cursor
```

### Adding more

```bash
make agents                                    # what is installed
make add-agent M=npm P=opencode-ai             # install now (this container)
make add-agent M=npm P=opencode-ai PERSIST=1   # ...and bake into the next build
make add-agent M=curl P=https://example.com/install.sh
```

`--persist` records npm packages in `EXTRA_NPM_PACKAGES`. For a `curl`
installer, add a `RUN` line to the Dockerfile following the existing pattern —
install with `HOME=$AGENT_HOME`, then symlink into `/usr/local/bin`, so the
`/home/paseo` volume cannot mask it.

## Model routing with 9router

9router holds several subscriptions, tracks each one's quota, and falls back
when one runs out. It is the **stock upstream image** — this repo only sets its
documented environment variables.

```bash
make router-status    # what is routed
make router-key       # mint an API key into .env
make router-on        # route claude + codex through it
make router-off       # back to each CLI's own login
```

These call **9router's own API**, which owns CLI wiring: it writes
`~/.claude/settings.json` and `~/.codex/config.toml` and can cleanly undo both.
Hand-editing those files would fight it, so this repo never does.

Kimi and Cursor speak vendor-specific protocols with no base-URL override, so
they always use their own logins. **Paseo's own preloaded providers are never
modified** — the bundled plugin adds a separate `9Router` provider alongside
them.

> 9router refuses remote logins while its password is the shipped default, and
> in Docker every login is remote. Compose passes `NINEROUTER_PASSWORD` as
> `INITIAL_PASSWORD` on first boot so the dashboard is reachable at all.

## Multiple daemons

Run extra Paseo daemons that share the same 9router pool:

```bash
make satellites          # starts paseo-2 (:6768) and paseo-3 (:6769)
make satellites-down
```

Each satellite is **fully isolated**: its own state volume (agents,
credentials, history), its own workspace directory, its own port and pairing
identity. Nothing is shared except the read-only config/memory seeds and the
router itself — so subscriptions are pooled while projects stay separate.

Seeded config is written **only on first boot and only when absent**, so a
daemon with its own Claude settings keeps them. `DEVSTACK_NO_SEED=1` skips
seeding entirely.

## Pairing

```bash
make pair
```

Prints a pairing link via Paseo's relay, so a phone or another laptop can reach
the daemon **without any public port**. Treat the link like a password.

## Memory guards

A Next dev server's memory is **native** — Turbopack is Rust, so it lives
outside the V8 heap and `NODE_OPTIONS=--max-old-space-size` cannot bound it. One
was measured at 21GB. Worse, `next dev` supervises `next-server` and restarts it
when it dies, so a ballooning server becomes an infinite grow → get killed →
respawn loop. Killing the child alone never works; the parent must go first.

Three layers handle this:

Size the stack to the host automatically:

```bash
make autotune          # show the recommendation
make autotune-write    # apply it to .env
```

It gives the agent container almost everything — on a 32GB box, 28GB — while
keeping a reserve (the larger of 1GB or 5%) so that when something *does* blow
up, the host still has enough memory to run sshd and docker and let you restart
things. Without that reserve an OOM takes the whole box down.

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
