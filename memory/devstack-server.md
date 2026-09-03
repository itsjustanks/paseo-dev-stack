---
name: devstack-server
description: The devstack container host — what runs here, how the pieces reach each other, and the traps
metadata:
  type: reference
---

This machine runs the **devstack** compose stack: Paseo (agent orchestration),
9router (model routing), and optionally a Cloudflare tunnel.

- Everything runs as the non-root `paseo` user (uid 1000). Agents refuse
  elevated permission modes as root.
- Containers reach each other by **service name** on the `devstack` bridge
  network: `http://9router:20128`, `http://paseo:6767`. These do not change
  when the public hostname changes.
- Both ports bind to `127.0.0.1` on the host. The only public entrance is the
  Cloudflare tunnel, which dials outward. Docker's iptables rules bypass UFW,
  so publishing to `0.0.0.0` would expose the app regardless of firewall rules.

**Traps:**
- `/home/paseo` is a Docker volume. Agent CLIs installed into `$HOME` at build
  time get masked when it mounts. They are installed with
  `HOME=/opt/agent-home` and symlinked into `/usr/local/bin`. If a CLI goes
  "not found" after a rebuild, that is what broke — `make doctor` checks it.
- A tunnel hostname must be in `PASEO_HOSTNAMES` or Paseo refuses the
  connection.
- Anything written into `/home/paseo` as root needs `chown -R paseo:paseo`
  afterwards or the daemon cannot read it.
- Headless Chromium needs more than the default 64MB `/dev/shm`; compose sets
  `shm_size: 1gb`.

Repo layout: `~/devstack` — `make up`, `make doctor`, `make shell`.
