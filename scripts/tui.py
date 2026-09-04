#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# devstack control panel — an interactive TUI for the whole stack.
#
#   ./scripts/devstack-tui.py        or        make tui
#
# WHY PYTHON + STDLIB CURSES (and nothing else)
#
#   The selling point of this repo is one command on a fresh box. Anything that
#   needs `pip install` or `npm install` at first run can fail on a fresh box,
#   and then the control panel — the thing meant to make the stack legible —
#   becomes the first thing that breaks.
#
#     * python3 is ALREADY a guaranteed runtime: bootstrap-server.sh installs it
#       on the host, the image has it, and scripts/guard/*.py are already Python.
#       Zero new runtimes, zero new packages.
#     * `curses` ships inside CPython's stdlib on Linux and macOS (it is built
#       against the system ncurses). `apt-get install python3` pulls
#       libpython3.x-stdlib, which contains _curses. Nothing to install.
#     * Terminal handoff — suspending the UI so `docker compose exec -it ...
#       claude` can own the tty — is a first-class, documented curses operation
#       (def_prog_mode / endwin / refresh). See handoff() below.
#
#   Rejected, with the actual cost of each:
#     textual   — pip install (+rich, markdown-it-py, platformdirs, ...). On
#                 Ubuntu 24.04+ PEP 668 makes a bare `pip install` an ERROR
#                 (externally-managed-environment), so it needs a venv or
#                 --break-system-packages. That is a first-run failure mode.
#     node+ink  — needs Node ON THE HOST. Node 22 lives in the CONTAINER here;
#                 the host is only guaranteed docker + python3 + bash. Plus a
#                 node_modules tree per checkout.
#     go+bubbletea — excellent, but needs either a Go toolchain on the box or
#                 four prebuilt binaries (linux/amd64, linux/arm64,
#                 darwin/amd64, darwin/arm64) committed to a public repo plus a
#                 release pipeline. Kills "clone and run".
#     bash+dialog/whiptail — `dialog` is not installed on Ubuntu Server by
#                 default and NEITHER exists on macOS. Also modal-only: no live
#                 refresh, no non-blocking input, no background polling.
#     bash+fzf  — fzf is installed nowhere by default, and it is a picker, not
#                 a dashboard. No live status.
#
# CONCURRENCY MODEL
#   The UI thread NEVER calls docker. Every docker/systemd/ps probe runs on a
#   background collector thread with its own interval and its own timeout, and
#   publishes into a lock-guarded State. The UI reads the last snapshot and
#   shows a spinner + "stale" marker while a collector is mid-flight. A hung
#   docker daemon therefore slows down a NUMBER on screen, never the keyboard.
#
#   Long non-interactive commands (up --build, doctor, logs -f) stream into a
#   pane via Streamer. Interactive TTY programs (agent logins, shells, the VS
#   Code tunnel) take the terminal over via handoff().
# ─────────────────────────────────────────────────────────────────────────────
from __future__ import annotations

import curses
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "devstack control panel"
IS_MAC = sys.platform == "darwin"

# Strip ANSI/OSC so docker's coloured output does not render as literal escapes.
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


# ══ small helpers ════════════════════════════════════════════════════════════

def clean(s: str) -> str:
    """Make an arbitrary line safe to hand to curses."""
    s = ANSI_RE.sub("", s)
    return "".join(ch if (ch == " " or ch.isprintable()) else " " for ch in s)


def human_bytes(n: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit in ("B", "K") else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}T"


def human_dur(seconds: float) -> str:
    seconds = int(max(0, seconds))
    d, seconds = divmod(seconds, 86400)
    h, seconds = divmod(seconds, 3600)
    m, s = divmod(seconds, 60)
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def parse_docker_ts(ts: str):
    """
    Docker emits RFC3339 with NANOsecond precision ('...T09:00:00.123456789Z').
    datetime.fromisoformat only accepts up to microseconds on older Pythons, so
    truncate the fraction to 6 digits ourselves rather than depending on the
    interpreter version (this file has to run on Debian 12's 3.11 and on
    whatever Homebrew put on the Mac).
    """
    if not ts or ts.startswith("0001-"):
        return None
    ts = ts.strip().replace("Z", "+00:00")
    ts = re.sub(r"\.(\d{1,6})\d*(?=[+-]\d{2}:\d{2}$)", lambda m: "." + m.group(1), ts)
    try:
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def sh(cmd, timeout=15, cwd=ROOT, env=None, stdin_null=True):
    """
    Run a command, capture output, and GUARANTEE it cannot hang a collector.

    `start_new_session=True` puts the child in its own process group so that on
    timeout we can kill the WHOLE group -- `subprocess.run(timeout=)` alone only
    kills the direct child, which leaks helpers. Note macOS has no `timeout(1)`
    binary, so this has to be done in-process anyway.

    Returns (returncode, combined_output). rc == -1 means "could not run",
    rc == -2 means "timed out".
    """
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.Popen(
            cmd, cwd=cwd, env=e,
            stdin=subprocess.DEVNULL if stdin_null else None,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True, text=True, errors="replace",
        )
    except (FileNotFoundError, PermissionError, OSError) as exc:
        return -1, str(exc)
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out or ""
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        try:
            out, _ = p.communicate(timeout=3)
        except Exception:
            out = ""
        return -2, (out or "") + "\n[timed out]"


# ══ configuration read from the repo ═════════════════════════════════════════

def load_env() -> dict:
    """Minimal .env reader. No dependency, no shell, tolerant of junk."""
    env = {}
    for name in (".env", ".env.example"):
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            continue
        try:
            with open(path, "r", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    # .env wins; .env.example only fills gaps.
                    if name == ".env" or k not in env:
                        env[k] = v
        except OSError:
            pass
        if name == ".env":
            env["__HAS_ENV__"] = "1"
    return env


class Svc:
    """A compose service, plus the fallback container name from the compose file."""

    def __init__(self, service, container, blurb, profile=None, port_key=None,
                 default_port=None):
        self.service = service
        self.container = container
        self.blurb = blurb
        self.profile = profile          # compose profile needed to start it
        self.port_key = port_key        # .env key holding its host port
        self.default_port = default_port


SERVICES = [
    Svc("paseo", "paseo-dev-stack-paseo", "Paseo daemon + agent CLIs",
        port_key="PASEO_PORT", default_port=6767),
    Svc("9router", "paseo-dev-stack-9router", "model routing / multi-account",
        port_key="NINEROUTER_PORT", default_port=20128),
    Svc("cloudflared", "paseo-dev-stack-tunnel", "named Cloudflare tunnel",
        profile="tunnel"),
    Svc("cloudflared-quick", "paseo-dev-stack-tunnel-quick", "quick tunnel (no auth)",
        profile="quick-tunnel"),
]

# Where each agent CLI parks its credentials on the /home/paseo volume. The TUI
# reports `?` rather than guessing when a CLI's layout is not one we know.
AUTH_TOOLS = [
    ("claude", "Claude Code", "claude",
     ["/home/paseo/.claude/.credentials.json", "/home/paseo/.config/claude/.credentials.json"],
     "/home/paseo/.claude.json", "oauthAccount",
     "claude"),
    ("codex", "Codex", "codex",
     ["/home/paseo/.codex/auth.json"], None, None,
     "codex login"),
    ("kimi", "Kimi Code", "kimi",
     ["/home/paseo/.kimi/auth.json", "/home/paseo/.kimi/config.json",
      "/home/paseo/.config/kimi/auth.json"], None, None,
     "kimi"),
    ("cursor", "Cursor Agent", "cursor-agent",
     ["/home/paseo/.cursor/cli-config.json", "/home/paseo/.local/share/cursor-agent/auth.json"],
     None, None,
     "cursor-agent login"),
]


# ══ shared state ═════════════════════════════════════════════════════════════

class State:
    """
    Everything the UI draws. Written only by collectors, read only by the UI,
    both under `lock`. Each field carries its own freshness + error so a single
    broken probe degrades one panel instead of the whole screen.
    """

    def __init__(self):
        self.lock = threading.RLock()
        self.env = load_env()
        self.docker_ok = None            # None = unknown yet
        self.docker_msg = "checking docker..."
        self.compose_cmd = None          # ['docker','compose'] or ['docker-compose']
        self.services = {}               # service -> dict
        self.ports = {}                  # label -> bool reachable
        self.hostmem = {}
        self.cstats = {}                 # container name -> (usage, limit, pct)
        self.devservers = []
        self.auth = {}                   # tool -> 'ok'|'no'|'?'|'--'
        self.tunnels = {"quick": "", "named": "", "vscode": ""}
        self.guards = {"lines": [], "log": []}
        self.admin = {"version": "?", "image": "?", "latest": "", "update": "",
                      "daemons": [], "router": {}}
        self.busy = set()                # names of in-flight collectors
        self.notes = deque(maxlen=200)   # activity log shown in the footer/help
        self.stamps = {}                 # collector -> last successful epoch

    # -- convenience, all take the lock themselves -----------------------------
    def note(self, msg):
        with self.lock:
            self.notes.append((time.time(), clean(msg)[:400]))

    def mark(self, key, busy):
        with self.lock:
            (self.busy.add if busy else self.busy.discard)(key)
            if not busy:
                self.stamps[key] = time.time()

    def age(self, key):
        with self.lock:
            t = self.stamps.get(key)
        return None if t is None else time.time() - t

    def port(self, key, default):
        with self.lock:
            raw = self.env.get(key) or ""
        try:
            return int(raw)
        except (TypeError, ValueError):
            return default


ST = State()


# ══ probes ═══════════════════════════════════════════════════════════════════

def detect_docker():
    """
    Three distinct failure modes, three distinct messages -- 'docker not found',
    'daemon not running' and 'compose plugin missing' need different fixes and
    the panel should say which one it is.
    """
    if not shutil.which("docker"):
        with ST.lock:
            ST.docker_ok, ST.docker_msg, ST.compose_cmd = False, "docker is not installed on this host", None
        return
    rc, out = sh(["docker", "version", "--format", "{{.Server.Version}}"], timeout=8)
    if rc != 0:
        msg = "docker daemon is not reachable"
        if IS_MAC:
            msg += " — start Docker Desktop / OrbStack / `colima start`"
        else:
            msg += " — try: sudo systemctl start docker"
        with ST.lock:
            ST.docker_ok, ST.docker_msg, ST.compose_cmd = False, msg, None
        return
    server = out.strip().splitlines()[-1] if out.strip() else "?"
    cc = None
    if sh(["docker", "compose", "version"], timeout=8)[0] == 0:
        cc = ["docker", "compose"]
    elif shutil.which("docker-compose"):
        cc = ["docker-compose"]
    with ST.lock:
        ST.docker_ok = True
        ST.compose_cmd = cc
        ST.docker_msg = (f"docker {server}" + ("" if cc else
                         "  •  compose plugin MISSING — falling back to plain docker"))


def dc(*args, timeout=20):
    """Run a compose subcommand. Returns (rc, out); rc -1 if compose is absent."""
    with ST.lock:
        cc = ST.compose_cmd
    if not cc:
        return -1, "docker compose is not available"
    return sh(list(cc) + list(args), timeout=timeout)


def collect_services():
    """
    Prefer `compose ps` (knows about profiles and project scoping). Fall back to
    `docker inspect` on the container_name values baked into docker-compose.yml
    so the panel still works if the compose plugin is missing.
    """
    found = {}
    rc, out = dc("ps", "--all", "--format", "json", timeout=20)
    if rc == 0 and out.strip():
        rows = []
        txt = out.strip()
        # Compose v2.21+ emits NDJSON; older builds emit one JSON array.
        if txt.startswith("["):
            try:
                rows = json.loads(txt)
            except json.JSONDecodeError:
                rows = []
        else:
            for line in txt.splitlines():
                line = line.strip()
                if line.startswith("{"):
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        for r in rows:
            name = r.get("Service") or r.get("Name") or ""
            found[name] = {
                "state": (r.get("State") or "").lower(),
                "status": r.get("Status") or "",
                "container": r.get("Name") or "",
                "health": (r.get("Health") or "").lower(),
                "exit": r.get("ExitCode"),
            }

    fmt = ("{{.State.Status}}\x1f{{if .State.Health}}{{.State.Health.Status}}{{else}}{{end}}"
           "\x1f{{.State.StartedAt}}\x1f{{.RestartCount}}\x1f{{.State.ExitCode}}")
    for s in SERVICES:
        row = found.get(s.service, {})
        rc2, out2 = sh(["docker", "inspect", "--format", fmt, s.container], timeout=10)
        if rc2 == 0 and "\x1f" in out2:
            status, health, started, restarts, exitcode = (out2.strip().split("\x1f") + [""] * 5)[:5]
            started_dt = parse_docker_ts(started)
            row.update({
                "state": status or row.get("state", ""),
                "health": health or row.get("health", ""),
                "restarts": int(restarts) if restarts.isdigit() else 0,
                "uptime": (datetime.now(timezone.utc) - started_dt).total_seconds()
                          if (started_dt and status == "running") else None,
                "exit": exitcode,
                "container": s.container,
                "present": True,
            })
        else:
            row.setdefault("state", "absent")
            row["present"] = bool(row.get("state") and row["state"] != "absent")
            row.setdefault("restarts", 0)
            row.setdefault("uptime", None)
        found[s.service] = row
    with ST.lock:
        ST.services = found


def collect_ports():
    """
    Container 'running' is not the same as 'serving'. This compose file defines
    no healthchecks, so probe the published loopback ports directly -- it is
    instant, needs no docker at all, and is the thing you actually care about.
    """
    res = {}
    for s in SERVICES:
        if not s.port_key:
            continue
        p = ST.port(s.port_key, s.default_port)
        ok = False
        try:
            with socket.create_connection(("127.0.0.1", p), timeout=1.2):
                ok = True
        except OSError:
            ok = False
        res[s.service] = (p, ok)
    bp = ST.port("AGENT_BROWSER_STREAM_PORT", 9223)
    try:
        with socket.create_connection(("127.0.0.1", bp), timeout=1.2):
            res["agent-browser"] = (bp, True)
    except OSError:
        res["agent-browser"] = (bp, False)
    with ST.lock:
        ST.ports = res


def collect_hostmem():
    """Host RAM. /proc on Linux, vm_stat+sysctl on macOS -- no psutil."""
    info = {}
    try:
        if os.path.exists("/proc/meminfo"):
            vals = {}
            with open("/proc/meminfo") as fh:
                for line in fh:
                    k, _, rest = line.partition(":")
                    vals[k] = float(rest.strip().split()[0]) * 1024
            info["total"] = vals.get("MemTotal", 0)
            info["avail"] = vals.get("MemAvailable", vals.get("MemFree", 0))
            info["swap_total"] = vals.get("SwapTotal", 0)
            info["swap_free"] = vals.get("SwapFree", 0)
            info["src"] = "/proc/meminfo"
        else:
            rc, out = sh(["sysctl", "-n", "hw.memsize"], timeout=5)
            total = float(out.strip() or 0) if rc == 0 else 0
            rc, out = sh(["vm_stat"], timeout=5)
            page = 4096
            m = re.search(r"page size of (\d+)", out)
            if m:
                page = int(m.group(1))
            pages = {}
            for line in out.splitlines():
                mm = re.match(r'"?([A-Za-z ()\-]+)"?:\s+(\d+)', line.strip())
                if mm:
                    pages[mm.group(1).strip()] = int(mm.group(2)) * page
            free = pages.get("Pages free", 0)
            spec = pages.get("Pages speculative", 0)
            purge = pages.get("Pages purgeable", 0)
            info["total"] = total
            # macOS "available" ~= free + speculative + purgeable; the same
            # reclaimable-cache idea MemAvailable encodes on Linux.
            info["avail"] = free + spec + purge
            info["src"] = "vm_stat"
    except Exception as exc:                                  # never kill the UI
        info = {"err": str(exc)}
    with ST.lock:
        ST.hostmem = info


def collect_stats():
    """`docker stats --no-stream` is the slow one (~1-2s). Own thread, own interval."""
    rc, out = sh(["docker", "stats", "--no-stream", "--format",
                  "{{.Name}}\x1f{{.MemUsage}}\x1f{{.MemPerc}}\x1f{{.CPUPerc}}"], timeout=25)
    stats = {}
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\x1f")
            if len(parts) >= 4:
                stats[parts[0].strip()] = (parts[1].strip(), parts[2].strip(), parts[3].strip())
    with ST.lock:
        ST.cstats = stats


DEVSERVER_PROBE = (
    "ps -eo pid=,etimes=,rss=,args= 2>/dev/null | grep -E 'next-server \\(v|next dev' "
    "| grep -v grep || true"
)


def _parse_devservers(text):
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        pid, etimes, rss, args = parts
        try:
            rows.append({
                "pid": int(pid),
                "hours": int(etimes) / 3600.0,
                "gb": int(rss) / 1048576.0,
                "cmd": clean(args)[:120],
            })
        except ValueError:
            continue
    return rows


def collect_devservers():
    """Next dev servers -- these are what actually eat the box. Container first."""
    rows = []
    rc, out = dc("exec", "-T", "--user", "paseo", "paseo", "bash", "-lc",
                 DEVSERVER_PROBE, timeout=20)
    if rc == 0:
        rows += [dict(r, where="container") for r in _parse_devservers(out)]
    rc, out = sh(["bash", "-lc", DEVSERVER_PROBE], timeout=10)
    if rc == 0:
        rows += [dict(r, where="host") for r in _parse_devservers(out)]
    with ST.lock:
        ST.devservers = rows


def _auth_probe_script():
    """
    One exec, not four. Emits `tool=state` lines where state is:
      ok  credentials on the /home/paseo volume    no  installed, not logged in
      ?   installed, layout unknown to us          --  CLI not installed
    """
    parts = ["set -u"]
    for key, _label, binname, files, jsonfile, jsonkey, _cmd in AUTH_TOOLS:
        tests = " ; ".join(f'[ -s "{f}" ] && {{ echo "{key}=ok"; exit 0; }}' for f in files)
        extra = ""
        if jsonfile and jsonkey:
            extra = f'grep -q "{jsonkey}" "{jsonfile}" 2>/dev/null && {{ echo "{key}=ok"; exit 0; }};'
        parts.append(
            f'( command -v {binname} >/dev/null 2>&1 || {{ echo "{key}=--"; exit 0; }};'
            f' {extra} {tests} ; echo "{key}=no" )'
        )
    return "\n".join(parts)


def collect_auth():
    rc, out = dc("exec", "-T", "--user", "paseo", "paseo", "bash", "-lc",
                 _auth_probe_script(), timeout=25)
    res = {}
    if rc == 0:
        for line in out.splitlines():
            if "=" in line:
                k, _, v = line.strip().partition("=")
                if k in {t[0] for t in AUTH_TOOLS}:
                    res[k] = v.strip()
    if not res:
        res = {t[0]: "?" for t in AUTH_TOOLS}
    with ST.lock:
        ST.auth = res


def collect_tunnels():
    t = {"quick": "", "named": "", "vscode": ""}
    rc, out = dc("logs", "--tail", "400", "cloudflared-quick", timeout=20)
    if rc == 0:
        urls = re.findall(r"https://[a-z0-9-]+\.trycloudflare\.com", out)
        if urls:
            t["quick"] = urls[-1]
    with ST.lock:
        named_running = ST.services.get("cloudflared", {}).get("state") == "running"
        hostnames = ST.env.get("PASEO_HOSTNAMES", "")
    if named_running:
        first = next((h.strip() for h in hostnames.split(",") if h.strip() and not h.startswith(".")), "")
        t["named"] = f"https://{first}" if first else "(running — hostname set in Cloudflare)"
    rc, out = dc("exec", "-T", "--user", "paseo", "paseo", "bash", "-lc",
                 'grep -oE "https://vscode\\.dev/tunnel/[^ ]+" /home/paseo/.vscode-tunnel.log '
                 '2>/dev/null | tail -1 || true', timeout=20)
    if rc == 0 and "vscode.dev" in out:
        t["vscode"] = out.strip().splitlines()[-1].strip()
    with ST.lock:
        ST.tunnels = t


def collect_guards():
    """systemd timers are Linux-only; say so on a Mac instead of showing an error."""
    lines, log = [], []
    if shutil.which("systemctl"):
        rc, out = sh(["systemctl", "list-timers", "--all", "--no-pager"], timeout=10)
        if rc == 0:
            hits = [clean(l) for l in out.splitlines()
                    if "devserver-guard" in l or "cache-trim" in l]
            lines = hits or ["guards not installed  —  run: make guards"]
        else:
            lines = ["systemctl present but list-timers failed"]
    else:
        lines = ["no systemd on this host (macOS) — guards are Linux-only.",
                 "the dry-run preview below still works everywhere."]
    p = os.path.expanduser("~/.paseo/devserver-guard.log")
    if os.path.exists(p):
        try:
            with open(p, errors="replace") as fh:
                log = [clean(x.rstrip()) for x in deque(fh, maxlen=12)]
        except OSError:
            pass
    with ST.lock:
        ST.guards = {"lines": lines, "log": log or ["(no reaps logged yet)"]}


def collect_admin():
    """Versions, every Paseo daemon on this host, and 9router reachability.

    Deliberately cheap and network-light: the GitHub check is the only remote
    call and it is allowed to fail silently (an offline box must still show the
    rest of the panel).
    """
    info = {"version": "?", "image": "?", "latest": "", "update": "",
            "daemons": [], "router": {}}

    # what this checkout claims to be
    vf = os.path.join(ROOT, "VERSION")
    if os.path.exists(vf):
        try:
            info["version"] = open(vf).read().strip()
        except OSError:
            pass
    rc, out = sh(["git", "-C", ROOT, "describe", "--tags", "--always", "--dirty"], timeout=8)
    if rc == 0 and out.strip():
        info["commit"] = clean(out.strip())

    # what the RUNNING image is — the authoritative answer for a pulled image
    rc, out = sh(["docker", "compose", "exec", "-T", "--user", "paseo", "paseo",
                  "printenv", "PDS_VERSION"], timeout=12)
    info["image"] = clean(out.strip()) if rc == 0 and out.strip() else "not running"

    # latest release. GitHub returns SINGLE-LINE json, so match key AND value.
    rc, out = sh(["curl", "-fsSL", "--max-time", "8",
                  "https://api.github.com/repos/itsjustanks/paseo-dev-stack/releases/latest"],
                 timeout=12)
    if rc == 0:
        m = re.search(r'"tag_name"\s*:\s*"([^"]+)"', out)
        if m:
            info["latest"] = m.group(1)
            cur = info["version"].lstrip("v")
            if info["latest"].lstrip("v") != cur:
                info["update"] = f"update available: {info['latest']}"

    # every paseo daemon on this host, including satellites
    rc, out = sh(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"], timeout=12)
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) < 2 or "paseo" not in parts[0] or "9router" in parts[0]:
                continue
            name, status = parts[0], parts[1]
            ports = parts[2] if len(parts) > 2 else ""
            m = re.search(r"127\.0\.0\.1:(\d+)->6767", ports)
            hostn = ""
            rc2, o2 = sh(["docker", "exec", name, "hostname"], timeout=8)
            if rc2 == 0:
                hostn = clean(o2.strip())
            info["daemons"].append({
                "container": name, "status": status,
                "port": m.group(1) if m else "-", "name": hostn or "?",
            })

    # 9router: reachable, and is anything routed through it
    rc, out = sh(["docker", "compose", "exec", "-T", "--user", "paseo", "paseo",
                  "bash", "-lc",
                  "curl -s -o /dev/null -w '%{http_code}' http://9router:20128/api/health"],
                 timeout=12)
    info["router"]["health"] = clean(out.strip()) if rc == 0 else "000"
    envd = load_env()
    info["router"]["port"] = envd.get("NINEROUTER_PORT") or "20128"
    info["router"]["key"] = "set" if envd.get("NINEROUTER_KEY") else "not set"

    with ST.lock:
        ST.admin = info


# ══ collector scheduling ═════════════════════════════════════════════════════

COLLECTORS = [
    ("services", collect_services, 3.0),
    ("ports", collect_ports, 3.0),
    ("hostmem", collect_hostmem, 2.0),
    ("stats", collect_stats, 6.0),
    ("devservers", collect_devservers, 10.0),
    ("auth", collect_auth, 25.0),
    ("tunnels", collect_tunnels, 12.0),
    ("guards", collect_guards, 20.0),
    ("admin", collect_admin, 45.0),
]

_stop = threading.Event()
_kick = {}          # collector name -> Event, set to force an immediate re-run


def _loop(name, fn, interval):
    ev = _kick[name]
    while not _stop.is_set():
        need_docker = name not in ("hostmem", "guards")
        with ST.lock:
            ok = ST.docker_ok
        if not need_docker or ok:
            ST.mark(name, True)
            try:
                fn()
            except Exception as exc:                          # a probe must never
                ST.note(f"{name} probe failed: {exc}")        # take down the UI
            finally:
                ST.mark(name, False)
        ev.wait(interval)
        ev.clear()


def start_collectors():
    def docker_watch():
        while not _stop.is_set():
            try:
                detect_docker()
            except Exception as exc:
                ST.note(f"docker detect failed: {exc}")
            _stop.wait(10.0)

    threading.Thread(target=docker_watch, daemon=True).start()
    for _ in range(40):                       # let the first detect land (<=2s)
        with ST.lock:
            if ST.docker_ok is not None:
                break
        time.sleep(0.05)
    for name, fn, iv in COLLECTORS:
        _kick[name] = threading.Event()
        threading.Thread(target=_loop, args=(name, fn, iv), daemon=True).start()


def refresh_all():
    for ev in _kick.values():
        ev.set()


# ══ streaming pane: long, non-interactive commands ═══════════════════════════

class Streamer:
    """
    Runs a command with merged stdout/stderr into a ring buffer that the UI
    renders. Used for `logs -f`, `up --build`, `doctor`, guard dry-runs -- i.e.
    everything that is slow and chatty but does NOT need a tty.

    Reads raw bytes and splits on BOTH \\n and \\r so docker's carriage-return
    progress lines advance instead of piling into one enormous line.
    """

    def __init__(self, cmd, title, cwd=ROOT):
        self.cmd = cmd
        self.title = title
        self.lines = deque(maxlen=4000)
        self.done = False
        self.rc = None
        self.proc = None
        self.scroll = 0                # 0 == follow tail
        self._lock = threading.Lock()
        try:
            self.proc = subprocess.Popen(
                cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except (FileNotFoundError, OSError) as exc:
            self.lines.append(f"could not run: {exc}")
            self.done = True
            self.rc = -1
            return
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        fd = self.proc.stdout.fileno()
        buf = b""
        try:
            while True:
                chunk = os.read(fd, 8192)
                if not chunk:
                    break
                buf += chunk
                parts = re.split(rb"[\r\n]", buf)
                buf = parts.pop()
                with self._lock:
                    for p in parts:
                        self.lines.append(clean(p.decode("utf-8", "replace")))
        except (OSError, ValueError):
            pass
        if buf:
            with self._lock:
                self.lines.append(clean(buf.decode("utf-8", "replace")))
        try:
            self.rc = self.proc.wait(timeout=5)
        except Exception:
            self.rc = None
        self.done = True

    def snapshot(self):
        with self._lock:
            return list(self.lines)

    def stop(self):
        """Kill the whole process group -- `docker compose logs -f` forks."""
        if self.proc and self.proc.poll() is None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(self.proc.pid, sig)
                except (ProcessLookupError, PermissionError, OSError):
                    try:
                        self.proc.kill()
                    except Exception:
                        pass
                try:
                    self.proc.wait(timeout=2)
                    break
                except Exception:
                    continue
        self.done = True


# ══ terminal handoff: interactive TTY programs ═══════════════════════════════

def handoff(cmd, banner=None, cwd=ROOT):
    """
    Give the terminal to a full-screen interactive program (claude, codex, a
    shell, `code tunnel`), then take it back cleanly.

    THIS IS THE FIDDLY PART. The sequence, and why each step exists:

      1. curses.def_prog_mode()  — snapshot the CURRENT tty settings (cbreak,
         noecho, keypad, ...) into curses' "program mode" so they can be
         restored verbatim later.
      2. curses.endwin()         — restore the tty to "shell mode": cooked
         input, echo on, cursor visible, and the terminal taken OUT of the
         alternate screen buffer. Without this the child inherits raw/noecho
         and a login prompt shows nothing as you type.
      3. curses.flushinp()       — drop keystrokes already buffered by the TUI
         so a stray keypress does not get eaten by the child's first prompt.
      4. run the child with **inherited stdio** — no PIPEs. The child must have
         the real tty as fd 0/1/2 or it will not detect a terminal and will
         refuse to render (or will refuse to prompt for a login code).
      5. stdscr.refresh()        — curses internally does reset_prog_mode() and
         repaints from scratch. `endwin()` is documented as "temporary"
         precisely so a plain refresh resumes; calling initscr() again would
         leak a whole new screen. Verified: curses.isendwin() is False after.

    SIGINT: while the child owns the terminal, ctrl-C must reach the CHILD, not
    us. start_new_session=False keeps it in our foreground process group, and we
    ignore SIGINT for the duration so the TUI is never killed by a ctrl-C that
    was aimed at the login flow.
    """
    curses.def_prog_mode()
    curses.endwin()
    curses.flushinp()

    old_sigint = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    rc = None
    try:
        os.write(1, b"\x1b[2J\x1b[H")        # clear the shell screen we returned to
        if banner:
            sys.stdout.write(banner.rstrip() + "\n\n")
            sys.stdout.flush()
        try:
            # stdin/stdout/stderr deliberately NOT redirected: the child needs
            # the real tty. This blocks until it exits -- that is the point.
            rc = subprocess.call(cmd, cwd=cwd)
        except FileNotFoundError as exc:
            sys.stdout.write(f"\ncould not run: {exc}\n")
            rc = -1
        sys.stdout.write(f"\n[exit {rc}]  press Enter to return to the panel ")
        sys.stdout.flush()
        try:
            sys.stdin.readline()
        except (KeyboardInterrupt, EOFError, OSError):
            pass
    finally:
        signal.signal(signal.SIGINT, old_sigint)
    return rc


# ══ UI ═══════════════════════════════════════════════════════════════════════

SPIN = "|/-\\"
C_DIM, C_OK, C_WARN, C_BAD, C_HEAD, C_KEY, C_SEL = range(1, 8)


def init_colors():
    try:
        curses.start_color()
        curses.use_default_colors()          # keep the user's transparent bg
    except curses.error:
        return False
    if not curses.has_colors():
        return False
    for pair, fg in ((C_DIM, curses.COLOR_WHITE), (C_OK, curses.COLOR_GREEN),
                     (C_WARN, curses.COLOR_YELLOW), (C_BAD, curses.COLOR_RED),
                     (C_HEAD, curses.COLOR_CYAN), (C_KEY, curses.COLOR_MAGENTA),
                     (C_SEL, curses.COLOR_BLUE)):
        try:
            curses.init_pair(pair, fg, -1)
        except curses.error:
            pass
    return True


class UI:
    TABS = ["status", "memory", "auth", "tunnels", "logs", "doctor", "guards", "admin"]

    def __init__(self, stdscr):
        self.scr = stdscr
        self.tab = 0
        self.sel = 0                 # row cursor inside the active tab
        self.frame = 0
        self.stream = None
        self.color = init_colors()
        self.msg = ""
        self.msg_at = 0.0
        self.confirm = None          # (prompt, callback)

    # -- drawing primitives ---------------------------------------------------
    def attr(self, pair=0, bold=False, dim=False, rev=False):
        a = curses.color_pair(pair) if (self.color and pair) else 0
        if bold:
            a |= curses.A_BOLD
        if dim:
            a |= curses.A_DIM
        if rev:
            a |= curses.A_REVERSE
        return a

    def put(self, y, x, text, pair=0, bold=False, dim=False, rev=False):
        """
        Clipped write. curses raises on the last cell of the last line, and
        on any out-of-range coordinate -- during a resize both happen, so every
        write is guarded rather than the screen being redrawn defensively.
        """
        h, w = self.scr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        text = clean(str(text))
        if x < 0:
            text, x = text[-x:], 0
        room = w - x - 1
        if room <= 0:
            return
        try:
            self.scr.addnstr(y, x, text, room, self.attr(pair, bold, dim, rev))
        except curses.error:
            pass

    def hline(self, y, ch="─", pair=C_DIM):
        h, w = self.scr.getmaxyx()
        if 0 <= y < h:
            self.put(y, 0, ch * (w - 1), pair, dim=True)

    def flash(self, text):
        self.msg, self.msg_at = text, time.time()
        ST.note(text)

    # -- chrome ---------------------------------------------------------------
    def header(self):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            ok, dmsg, busy = ST.docker_ok, ST.docker_msg, set(ST.busy)
            has_env = ST.env.get("__HAS_ENV__") == "1"
        spin = SPIN[self.frame % 4] if busy else " "
        self.put(0, 0, f" {APP} ", C_HEAD, bold=True, rev=True)
        dot = "●" if ok else ("○" if ok is False else "◌")
        self.put(0, len(APP) + 3, f"{dot} {dmsg}", C_OK if ok else C_BAD, bold=True)
        self.put(0, w - 14, f"{spin} {'busy' if busy else 'idle'}", C_DIM, dim=True)

        if not has_env:
            self.put(1, 0, " no .env — copy .env.example to .env and set PASEO_PASSWORD "
                           "(compose will refuse to start without it) ", C_WARN, bold=True, rev=True)

        y = 2 if not has_env else 1
        x = 0
        for i, name in enumerate(self.TABS):
            label = f" {i+1}·{name} "
            self.put(y, x, label, C_HEAD if i == self.tab else C_DIM,
                     bold=(i == self.tab), rev=(i == self.tab), dim=(i != self.tab))
            x += len(label) + 1
        self.hline(y + 1)
        return y + 2

    def footer(self):
        h, w = self.scr.getmaxyx()
        self.hline(h - 2)
        if self.confirm:
            self.put(h - 1, 0, f" {self.confirm[0]}  [y/N] ", C_WARN, bold=True, rev=True)
            return
        if self.msg and time.time() - self.msg_at < 6:
            self.put(h - 1, 0, f" {self.msg} ", C_KEY, bold=True)
            return
        keys = {
            0: "u up  d down  r restart  B rebuild  l logs  s shell  ↑↓ pick",
            1: "R refresh  K kill dev server  g guards",
            2: "Enter log in  A log in to all  ↑↓ pick",
            3: "q quick  n named  v vscode  c copy url  x stop tunnels",
            4: "↑↓ scroll  PgUp/PgDn  f follow  x stop  s pick service",
            5: "Enter run doctor  x stop",
            6: "Enter dry-run  i install (linux)",
        }.get(self.tab, "")
        self.put(h - 1, 0, f" {keys}   ·   Tab switch  ? help  Q quit ", C_DIM, dim=True)

    # -- tabs -----------------------------------------------------------------
    def tab_status(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            svcs, ports, cstats = dict(ST.services), dict(ST.ports), dict(ST.cstats)
        age = ST.age("services")
        stale = "  (stale)" if age and age > 12 else ""
        self.put(y, 2, f"SERVICES{stale}", C_HEAD, bold=True)
        y += 1
        self.put(y, 2, f"{'':2}{'service':<20}{'state':<12}{'uptime':<10}"
                       f"{'restarts':<10}{'port':<14}{'memory':<18}", C_DIM, dim=True)
        y += 1
        for i, s in enumerate(SERVICES):
            row = svcs.get(s.service, {})
            state = row.get("state") or "absent"
            pair, mark = {
                "running": (C_OK, "●"), "restarting": (C_WARN, "◐"),
                "created": (C_WARN, "○"), "paused": (C_WARN, "‖"),
                "exited": (C_BAD, "✗"), "dead": (C_BAD, "✗"),
            }.get(state, (C_DIM, "·"))
            if state == "absent":
                state = "not created"
            up = human_dur(row["uptime"]) if row.get("uptime") else "—"
            rst = row.get("restarts", 0)
            pinfo = "—"
            if s.service in ports:
                p, alive = ports[s.service]
                pinfo = f"{p} {'open' if alive else 'closed'}"
            mem = "—"
            cs = cstats.get(row.get("container") or s.container)
            if cs:
                mem = f"{cs[0].replace(' ', '')} ({cs[1]})"
            sel = (i == self.sel)
            self.put(y, 0, "▸" if sel else " ", C_KEY, bold=True)
            self.put(y, 2, mark, pair, bold=True)
            self.put(y, 4, f"{s.service:<20}", C_HEAD if sel else 0, bold=sel)
            self.put(y, 24, f"{state:<12}", pair)
            self.put(y, 36, f"{up:<10}", C_DIM, dim=True)
            self.put(y, 46, f"{rst:<10}", C_BAD if rst > 3 else C_DIM,
                     bold=rst > 3, dim=rst <= 3)
            self.put(y, 56, f"{pinfo:<14}",
                     C_OK if pinfo.endswith("open") else (C_DIM if pinfo == "—" else C_WARN))
            self.put(y, 70, mem, C_DIM, dim=True)
            y += 1
            if sel and y < h - 4:
                extra = s.blurb + (f"   [profile: {s.profile}]" if s.profile else "")
                self.put(y, 6, extra, C_DIM, dim=True)
                y += 1
        y += 1
        self.hline(y); y += 1
        self.put(y, 2, "ENDPOINTS", C_HEAD, bold=True); y += 1
        pp = ST.port("PASEO_PORT", 6767)
        np_ = ST.port("NINEROUTER_PORT", 20128)
        bp = ST.port("AGENT_BROWSER_STREAM_PORT", 9223)
        for label, url, alive in (
            ("Paseo UI", f"http://127.0.0.1:{pp}", ports.get("paseo", (0, False))[1]),
            ("9router", f"http://127.0.0.1:{np_}/dashboard", ports.get("9router", (0, False))[1]),
            ("browser stream", f"ws://127.0.0.1:{bp}", ports.get("agent-browser", (0, False))[1]),
        ):
            self.put(y, 4, f"{'●' if alive else '○'} {label:<16}", C_OK if alive else C_DIM,
                     bold=alive, dim=not alive)
            self.put(y, 26, url, C_KEY if alive else C_DIM, dim=not alive)
            y += 1
        return y

    def tab_memory(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            hm, cstats, devs = dict(ST.hostmem), dict(ST.cstats), list(ST.devservers)
        self.put(y, 2, "HOST MEMORY", C_HEAD, bold=True); y += 1
        if hm.get("err"):
            self.put(y, 4, f"unavailable: {hm['err']}", C_WARN); y += 1
        elif hm.get("total"):
            total, avail = hm["total"], hm.get("avail", 0)
            used = total - avail
            frac = used / total if total else 0
            barw = max(10, min(46, w - 34))
            filled = int(barw * frac)
            pair = C_OK if frac < 0.75 else (C_WARN if frac < 0.9 else C_BAD)
            self.put(y, 4, "[", C_DIM, dim=True)
            self.put(y, 5, "█" * filled, pair, bold=True)
            self.put(y, 5 + filled, "░" * (barw - filled), C_DIM, dim=True)
            self.put(y, 5 + barw, "]", C_DIM, dim=True)
            self.put(y, 8 + barw, f"{human_bytes(used)} / {human_bytes(total)} used"
                                  f"   {human_bytes(avail)} available", pair)
            y += 1
            if hm.get("swap_total"):
                sw_used = hm["swap_total"] - hm.get("swap_free", 0)
                self.put(y, 4, f"swap {human_bytes(sw_used)} / {human_bytes(hm['swap_total'])}",
                         C_WARN if sw_used > 0.5 * hm["swap_total"] else C_DIM, dim=True)
                y += 1
            self.put(y, 4, f"source: {hm.get('src', '?')}", C_DIM, dim=True); y += 1
        else:
            self.put(y, 4, "reading...", C_DIM, dim=True); y += 1

        y += 1
        with ST.lock:
            limit_raw = ST.env.get("PASEO_MEM_LIMIT", "0")
        # NOTE: built with concatenation, not a multi-line f-string expression.
        # A newline INSIDE the braces of an f-string is PEP 701 and needs
        # Python 3.12+; the container is Debian 12 (3.11), so it must not appear.
        uncapped = limit_raw in ("", "0")
        warn = "  — unlimited, one runaway next-server can take the host down"
        self.put(y, 2, "CONTAINERS", C_HEAD, bold=True)
        self.put(y, 16, "(PASEO_MEM_LIMIT=" + (limit_raw or "0") +
                        (warn if uncapped else "") + ")",
                 C_WARN if uncapped else C_DIM, dim=not uncapped)
        y += 1
        if not cstats:
            self.put(y, 4, "no running containers (or docker stats unavailable)", C_DIM, dim=True)
            y += 1
        for name, (usage, pct, cpu) in sorted(cstats.items()):
            try:
                pv = float(pct.rstrip("%"))
            except ValueError:
                pv = 0.0
            pair = C_OK if pv < 70 else (C_WARN if pv < 90 else C_BAD)
            self.put(y, 4, f"{name:<32}", C_DIM)
            self.put(y, 36, f"{usage:<24}", pair)
            self.put(y, 60, f"{pct:>7} mem", pair, bold=pv >= 90)
            self.put(y, 72, f"{cpu:>8} cpu", C_DIM, dim=True)
            y += 1

        y += 1
        self.put(y, 2, "NEXT DEV SERVERS", C_HEAD, bold=True)
        self.put(y, 20, "(these are what actually eat the box — K to kill the selected one)",
                 C_DIM, dim=True)
        y += 1
        if not devs:
            self.put(y, 4, "none running", C_DIM, dim=True); y += 1
        for i, d in enumerate(devs):
            if y >= h - 3:
                self.put(y, 4, f"... {len(devs) - i} more", C_DIM, dim=True)
                break
            sel = (i == self.sel)
            pair = C_OK if d["gb"] < 4 else (C_WARN if d["gb"] < 10 else C_BAD)
            self.put(y, 2, "▸" if sel else " ", C_KEY, bold=True)
            self.put(y, 4, f"pid {d['pid']:<8}", C_DIM)
            self.put(y, 16, f"{d['gb']:>6.1f}GB", pair, bold=d["gb"] >= 10)
            self.put(y, 26, f"{d['hours']:>6.1f}h", C_WARN if d["hours"] > 2 else C_DIM,
                     dim=d["hours"] <= 2)
            self.put(y, 34, f"[{d['where']}]", C_DIM, dim=True)
            self.put(y, 46, d["cmd"], C_HEAD if sel else 0, dim=not sel)
            y += 1
        return y

    def tab_auth(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            auth = dict(ST.auth)
            paseo_state = ST.services.get("paseo", {}).get("state")
        self.put(y, 2, "AGENT CLI LOGINS", C_HEAD, bold=True)
        self.put(y, 22, "credentials live on the paseo-home volume — they survive "
                        "restart, rebuild and image updates", C_DIM, dim=True)
        y += 2
        if paseo_state != "running":
            self.put(y, 4, "the paseo container is not running — start it on the status tab "
                           "(u) before logging in", C_WARN, bold=True)
            y += 2
        for i, (key, label, binname, _f, _jf, _jk, cmd) in enumerate(AUTH_TOOLS):
            st = auth.get(key, "?")
            mark, pair, text = {
                "ok": ("●", C_OK, "authenticated"),
                "no": ("○", C_WARN, "NOT logged in"),
                "--": ("·", C_DIM, "CLI not installed in the image"),
            }.get(st, ("?", C_DIM, "unknown (probe could not read the container)"))
            sel = (i == self.sel)
            self.put(y, 2, "▸" if sel else " ", C_KEY, bold=True)
            self.put(y, 4, mark, pair, bold=True)
            self.put(y, 6, f"{label:<16}", C_HEAD if sel else 0, bold=sel)
            self.put(y, 24, f"{text:<44}", pair)
            self.put(y, 68, f"$ {cmd}", C_DIM, dim=True)
            y += 1
        y += 1
        self.hline(y); y += 1
        self.put(y, 2, "Enter", C_KEY, bold=True)
        self.put(y, 8, "hand the terminal to the selected CLI's interactive login. The panel "
                       "suspends,", C_DIM, dim=True); y += 1
        self.put(y, 8, "the CLI gets the real tty (it needs one for the device-code flow), and "
                       "the panel", C_DIM, dim=True); y += 1
        self.put(y, 8, "comes back when you exit it.", C_DIM, dim=True); y += 1
        self.put(y, 2, "A", C_KEY, bold=True)
        self.put(y, 8, "walk every CLI in turn.   ", C_DIM, dim=True)
        self.put(y, 34, "s", C_KEY, bold=True)
        self.put(y, 36, "shell into the container as paseo.", C_DIM, dim=True)
        return y + 1

    def tab_tunnels(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            t = dict(ST.tunnels)
            svcs = dict(ST.services)
            has_token = bool((ST.env.get("TUNNEL_TOKEN") or "").strip())
            hostnames = ST.env.get("PASEO_HOSTNAMES", "")
        self.put(y, 2, "PUBLIC ACCESS", C_HEAD, bold=True); y += 2
        rows = [
            ("quick tunnel", "cloudflared-quick", t["quick"],
             "throwaway *.trycloudflare.com — NO AUTH in front of it, dev only", "q"),
            ("named tunnel", "cloudflared", t["named"],
             "needs TUNNEL_TOKEN in .env" if not has_token else "token present in .env", "n"),
            ("vscode tunnel", None, t["vscode"],
             "runs inside the container; survives restarts once logged in", "v"),
        ]
        for i, (label, svc, url, blurb, key) in enumerate(rows):
            running = (svcs.get(svc, {}).get("state") == "running") if svc else bool(url)
            sel = (i == self.sel)
            self.put(y, 2, "▸" if sel else " ", C_KEY, bold=True)
            self.put(y, 4, "●" if running else "○", C_OK if running else C_DIM, bold=running)
            self.put(y, 6, f"{label:<16}", C_HEAD if sel else 0, bold=sel)
            self.put(y, 24, f"[{key}]", C_KEY, bold=True)
            self.put(y, 30, url or ("starting..." if running else "not running"),
                     C_OK if url else C_DIM, bold=bool(url), dim=not url)
            y += 1
            self.put(y, 6, blurb, C_DIM, dim=True)
            y += 2
        self.hline(y); y += 1
        self.put(y, 2, "PASEO_HOSTNAMES", C_HEAD, bold=True)
        self.put(y, 20, hostnames or "(empty)", C_DIM if hostnames else C_WARN,
                 dim=bool(hostnames))
        y += 1
        self.put(y, 4, "Paseo rejects unknown Host headers. Starting a quick tunnel here adds "
                       "its hostname", C_DIM, dim=True); y += 1
        self.put(y, 4, "to .env and restarts paseo automatically — same as `make quick-tunnel`.",
                 C_DIM, dim=True); y += 2
        bp = ST.port("AGENT_BROWSER_STREAM_PORT", 9223)
        self.put(y, 2, "AGENT BROWSER STREAM", C_HEAD, bold=True); y += 1
        self.put(y, 4, f"ws://127.0.0.1:{bp}", C_KEY, bold=True)
        self.put(y, 4 + 26, "  press c to print it for copying", C_DIM, dim=True); y += 1
        self.put(y, 4, f"remote:  ssh -N -L {bp}:127.0.0.1:{bp} <user>@<this-host>",
                 C_DIM, dim=True)
        return y + 1

    def tab_stream(self, y, title, empty_hint):
        """Shared renderer for the logs and doctor panes."""
        h, w = self.scr.getmaxyx()
        avail = h - y - 2
        if not self.stream:
            self.put(y, 2, title, C_HEAD, bold=True); y += 2
            for line in empty_hint:
                self.put(y, 4, line, C_DIM, dim=True); y += 1
            return y
        lines = self.stream.snapshot()
        status = ("running" if not self.stream.done
                  else f"finished (exit {self.stream.rc})")
        pair = (C_WARN if not self.stream.done
                else (C_OK if self.stream.rc == 0 else C_BAD))
        self.put(y, 2, self.stream.title, C_HEAD, bold=True)
        self.put(y, 2 + len(self.stream.title) + 2, f"— {status}", pair, bold=True)
        follow = self.stream.scroll == 0
        self.put(y, w - 26, "FOLLOW" if follow else "PAUSED (f to follow)",
                 C_OK if follow else C_WARN, bold=True)
        y += 1
        self.hline(y); y += 1
        total = len(lines)
        end = total - self.stream.scroll
        start = max(0, end - avail)
        for line in lines[start:max(start, end)]:
            lp = 0
            low = line.lower()
            if "error" in low or "fail" in low or "✗" in line:
                lp = C_BAD
            elif "warn" in low or "·" in line:
                lp = C_WARN
            elif "✓" in line or "ok" == low.strip():
                lp = C_OK
            self.put(y, 1, line, lp)
            y += 1
        return y

    def tab_guards(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            g = dict(ST.guards)
        self.put(y, 2, "MEMORY / DISK GUARDS", C_HEAD, bold=True)
        self.put(y, 26, "reap runaway Next dev servers and trim caches", C_DIM, dim=True)
        y += 2
        for line in g.get("lines", []):
            pair = C_OK if "devserver-guard.timer" in line or "cache-trim.timer" in line else C_WARN
            self.put(y, 4, line[:w - 6], pair)
            y += 1
        y += 1
        self.put(y, 2, "RECENT REAPS", C_HEAD, bold=True); y += 1
        for line in g.get("log", [])[-10:]:
            self.put(y, 4, line, C_DIM, dim=True); y += 1
        y += 1
        self.hline(y); y += 1
        if self.stream:
            return self.tab_stream(y, "", [])
        self.put(y, 2, "Enter", C_KEY, bold=True)
        self.put(y, 8, "dry-run both guards here — shows exactly what they WOULD kill/delete, "
                       "kills nothing", C_DIM, dim=True); y += 1
        if not IS_MAC:
            self.put(y, 2, "i", C_KEY, bold=True)
            self.put(y, 8, "install the systemd timers (runs sudo — hands the terminal over)",
                     C_DIM, dim=True)
        else:
            self.put(y, 4, "install is Linux-only; on macOS use the dry-run to inspect.",
                     C_DIM, dim=True)
        return y + 1

    def tab_admin(self, y):
        h, w = self.scr.getmaxyx()
        with ST.lock:
            a = dict(ST.admin)

        self.put(y, 2, "VERSION", C_HEAD, bold=True); y += 1
        self.put(y, 4, f"repo   {a.get('version','?')}")
        if a.get("commit"):
            self.put(y, 26, f"({a['commit']})", C_DIM, dim=True)
        y += 1
        self.put(y, 4, f"image  {a.get('image','?')}"); y += 1
        if a.get("latest"):
            if a.get("update"):
                self.put(y, 4, a["update"], C_WARN, bold=True)
            else:
                self.put(y, 4, f"latest {a['latest']}  (up to date)", C_OK)
            y += 1
        y += 1

        self.put(y, 2, "DAEMONS ON THIS HOST", C_HEAD, bold=True)
        self.put(y, 26, "each is isolated: own state, workspace and pairing identity",
                 C_DIM, dim=True)
        y += 2
        ds = a.get("daemons", [])
        if not ds:
            self.put(y, 4, "none running", C_DIM, dim=True); y += 1
        for i, d in enumerate(ds):
            sel = (i == self.sel and self.TABS[self.tab] == "admin")
            up = "Up" in d.get("status", "")
            self.put(y, 2, "▸" if sel else " ", C_KEY, bold=True)
            self.put(y, 4, "●" if up else "○", C_OK if up else C_BAD)
            self.put(y, 6, d.get("name", "?")[:20].ljust(21), bold=sel)
            self.put(y, 28, f":{d.get('port','-')}".ljust(8), C_KEY)
            self.put(y, 37, d.get("status", "")[:30], C_DIM, dim=True)
            self.put(y, 69, d.get("container", "")[:w - 71], C_DIM, dim=True)
            y += 1
        y += 1

        r = a.get("router", {})
        self.put(y, 2, "9ROUTER", C_HEAD, bold=True); y += 1
        okr = r.get("health") == "200"
        self.put(y, 4, "●" if okr else "○", C_OK if okr else C_BAD)
        self.put(y, 6, "reachable from the agent container" if okr
                 else f"NOT reachable (http {r.get('health','?')})",
                 0 if okr else C_BAD)
        y += 1
        self.put(y, 6, f"api key {r.get('key','?')}", C_DIM, dim=True); y += 1
        self.put(y, 6, f"dashboard http://127.0.0.1:{r.get('port','20128')}/dashboard",
                 C_KEY); y += 2

        self.hline(y); y += 1
        if self.stream:
            return self.tab_stream(y, "", [])

        for key, desc in (
            ("Enter", "check for updates (dry run — shows what would change)"),
            ("U", "apply the update: pull, merge new .env keys, rebuild, restart"),
            ("N", "new daemon — adds an isolated satellite for another tenant"),
            ("S", "start the satellite daemons defined in .env"),
            ("D", "9router dashboard over a tunnel (reachable from anywhere)"),
            ("p", "pairing link for the selected daemon"),
        ):
            self.put(y, 2, key, C_KEY, bold=True)
            self.put(y, 8, desc, C_DIM, dim=True)
            y += 1
        return y

    def draw_help(self):
        h, w = self.scr.getmaxyx()
        box = [
            "",
            "  devstack control panel",
            "",
            "  Tab / 1-8      switch tab            ↑ ↓ / j k    move the row cursor",
            "  R              force-refresh everything",
            "  Q or ctrl-C    quit (background containers keep running)",
            "",
            "  status   u start (build if needed)   d stop the stack",
            "           r restart selected          B rebuild image, no cache",
            "           l logs for selected         s shell into paseo as `paseo`",
            "           o open the selected URL in a browser",
            "",
            "  memory   K kill the selected dev server (parent supervisor first)",
            "",
            "  auth     Enter log in to the selected CLI    A every CLI in turn",
            "",
            "  tunnels  q quick   n named   v vscode   x stop cloudflared",
            "           c print URLs plainly so the terminal can copy them",
            "",
            "  logs     s pick a service   f follow/pause   PgUp/PgDn scroll   x stop",
            "",
            "  admin    Enter check for updates      U apply the update",
            "           N new isolated daemon        S start the satellites",
            "           D 9router dashboard tunnel   p pairing link for the selected",
            "",
            "  Interactive programs (logins, shells, vscode tunnel) take the whole",
            "  terminal: the panel suspends, they get the real tty, and the panel",
            "  returns when they exit.",
            "",
            "  press any key to close",
            "",
        ]
        bw = min(w - 4, max(len(l) for l in box) + 4)
        bh = min(h - 2, len(box) + 2)
        top, left = max(0, (h - bh) // 2), max(0, (w - bw) // 2)
        for i in range(bh):
            self.put(top + i, left, " " * bw, C_SEL, rev=True)
        for i, line in enumerate(box[:bh - 1]):
            self.put(top + 1 + i, left + 1, line.ljust(bw - 2), C_SEL, rev=True,
                     bold=line.strip().startswith("devstack"))

    # -- main draw ------------------------------------------------------------
    def draw(self):
        self.scr.erase()
        y = self.header()
        name = self.TABS[self.tab]
        try:
            if name == "status":
                self.tab_status(y)
            elif name == "memory":
                self.tab_memory(y)
            elif name == "auth":
                self.tab_auth(y)
            elif name == "tunnels":
                self.tab_tunnels(y)
            elif name == "logs":
                self.tab_stream(y, "LOGS", [
                    "no stream running.",
                    "press s to pick a service, or l on the status tab.",
                ])
            elif name == "doctor":
                self.tab_stream(y, "DOCTOR", [
                    "press Enter to run scripts/doctor.sh.",
                    "it verifies containers, every agent CLI, 9router reachability,",
                    "auto-memory, the headless browser, plugins and the guards.",
                ])
            elif name == "guards":
                self.tab_guards(y)
            elif name == "admin":
                self.tab_admin(y)
        except curses.error:
            pass                      # a resize mid-draw; the next frame is fine
        self.footer()
        if self.confirm and self.confirm[0].startswith("__help__"):
            self.draw_help()
        self.scr.noutrefresh()
        curses.doupdate()


# ══ actions ══════════════════════════════════════════════════════════════════

class Actions:
    def __init__(self, ui):
        self.ui = ui

    # -- helpers --------------------------------------------------------------
    def compose(self, *args):
        with ST.lock:
            cc = ST.compose_cmd
        return (list(cc) + list(args)) if cc else None

    def stream(self, args, title):
        cmd = self.compose(*args)
        if not cmd:
            self.ui.flash("docker compose is not available")
            return
        if self.ui.stream:
            self.ui.stream.stop()
        self.ui.stream = Streamer(cmd, title)
        self.ui.flash(f"running: {title}")

    def stream_raw(self, cmd, title, tab=None):
        if self.ui.stream:
            self.ui.stream.stop()
        self.ui.stream = Streamer(cmd, title)
        if tab is not None:
            self.ui.tab = tab
        self.ui.flash(f"running: {title}")

    def interactive(self, args, banner, tab_note=""):
        cmd = self.compose(*args)
        if not cmd:
            self.ui.flash("docker compose is not available")
            return
        handoff(cmd, banner)
        refresh_all()
        self.ui.flash(f"returned from {tab_note or ' '.join(args[-2:])}")

    def selected_service(self):
        return SERVICES[max(0, min(self.ui.sel, len(SERVICES) - 1))]

    # -- env editing (quick tunnel needs it) ----------------------------------
    @staticmethod
    def add_hostname(host):
        """
        Append a hostname to PASEO_HOSTNAMES in .env. Written via a temp file +
        os.replace so a crash mid-write cannot leave a truncated .env -- losing
        PASEO_PASSWORD would make the whole stack refuse to start.
        """
        path = os.path.join(ROOT, ".env")
        if not os.path.exists(path):
            return False, "no .env"
        try:
            with open(path, errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError as exc:
            return False, str(exc)
        out, seen = [], False
        for line in lines:
            if line.startswith("PASEO_HOSTNAMES="):
                seen = True
                cur = line.split("=", 1)[1].strip()
                hosts = [h for h in (x.strip() for x in cur.split(",")) if h]
                if host in hosts:
                    return True, "already allowed"
                hosts.append(host)
                out.append("PASEO_HOSTNAMES=" + ",".join(hosts))
            else:
                out.append(line)
        if not seen:
            out.append(f"PASEO_HOSTNAMES={host}")
        tmp = path + ".tmp"
        try:
            with open(tmp, "w") as fh:
                fh.write("\n".join(out) + "\n")
            os.replace(tmp, path)
        except OSError as exc:
            return False, str(exc)
        with ST.lock:
            ST.env = load_env()
        return True, "added"

    def start_quick_tunnel(self):
        """
        Same contract as `make quick-tunnel`, but off the UI thread: bring the
        profile up, poll the logs for the URL, allowlist the hostname, restart
        paseo so it accepts that Host header.
        """
        def worker():
            ST.note("quick tunnel: starting cloudflared-quick")
            rc, out = dc("--profile", "quick-tunnel", "up", "-d", "cloudflared-quick", timeout=120)
            if rc != 0:
                ST.note(f"quick tunnel failed to start: {out.strip()[-200:]}")
                return
            url = ""
            for _ in range(30):
                rc, out = dc("logs", "--tail", "300", "cloudflared-quick", timeout=20)
                if rc == 0:
                    urls = re.findall(r"https://[a-z0-9-]+\.trycloudflare\.com", out)
                    if urls:
                        url = urls[-1]
                        break
                time.sleep(2)
            if not url:
                ST.note("quick tunnel: no URL yet — check logs for cloudflared-quick")
                return
            ok, how = self.add_hostname(url[len("https://"):])
            ST.note(f"quick tunnel: {url}  (hostname {how})")
            if ok and how == "added":
                ST.note("restarting paseo so it accepts the new Host header")
                dc("up", "-d", "paseo", timeout=120)
            refresh_all()

        threading.Thread(target=worker, daemon=True).start()
        self.ui.flash("starting quick tunnel — the URL appears here when ready")

    def start_named_tunnel(self):
        with ST.lock:
            token = (ST.env.get("TUNNEL_TOKEN") or "").strip()
        if not token:
            self.ui.flash("TUNNEL_TOKEN is not set in .env — use q for a throwaway tunnel")
            return
        self.stream(["--profile", "tunnel", "up", "-d", "cloudflared"], "named tunnel up")

    def stop_tunnels(self):
        def worker():
            for prof, svc in (("quick-tunnel", "cloudflared-quick"), ("tunnel", "cloudflared")):
                dc("--profile", prof, "stop", svc, timeout=60)
                dc("--profile", prof, "rm", "-f", svc, timeout=60)
            ST.note("tunnels stopped")
            refresh_all()
        threading.Thread(target=worker, daemon=True).start()
        self.ui.flash("stopping tunnels...")

    def copy_urls(self):
        """
        There is no portable clipboard here (a headless droplet has no pbcopy and
        no X11 for xclip). Instead: try the OS clipboard, and ALWAYS also drop
        out of curses and print the URLs plainly, so the terminal's own
        select-and-copy -- which works over ssh, mosh and tmux -- can take them.
        """
        with ST.lock:
            t = dict(ST.tunnels)
        bp = ST.port("AGENT_BROWSER_STREAM_PORT", 9223)
        pp = ST.port("PASEO_PORT", 6767)
        np_ = ST.port("NINEROUTER_PORT", 20128)
        urls = [
            ("paseo (local)", f"http://127.0.0.1:{pp}"),
            ("9router", f"http://127.0.0.1:{np_}/dashboard"),
            ("browser stream", f"ws://127.0.0.1:{bp}"),
            ("quick tunnel", t.get("quick") or "(not running)"),
            ("named tunnel", t.get("named") or "(not running)"),
            ("vscode tunnel", t.get("vscode") or "(not running)"),
        ]
        blob = "\n".join(f"{k:<16} {v}" for k, v in urls)
        best = t.get("quick") or t.get("vscode") or f"http://127.0.0.1:{pp}"
        for tool in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"]):
            if shutil.which(tool[0]):
                try:
                    subprocess.run(tool, input=best, text=True, timeout=5)
                    break
                except Exception:
                    pass
        handoff(["true"], banner=blob + "\n\nselect with the mouse to copy.")

    def open_url(self, url):
        opener = "open" if IS_MAC else "xdg-open"
        if shutil.which(opener):
            sh([opener, url], timeout=5)
            self.ui.flash(f"opened {url}")
        else:
            self.ui.flash(f"no browser opener on this host — {url}")

    def kill_devserver(self):
        with ST.lock:
            devs = list(ST.devservers)
        if not devs:
            self.ui.flash("no dev servers running")
            return
        d = devs[max(0, min(self.ui.sel, len(devs) - 1))]

        def do_kill():
            # Kill the PARENT supervisor's group: `next dev` restarts
            # `next-server` when it dies, so killing only the child loops
            # forever (see scripts/guard/devserver-guard.py).
            if d["where"] == "host":
                rc, out = sh(["bash", "-lc",
                              f"kill -TERM -- -$(ps -o pgid= {d['pid']} | tr -d ' ') "
                              f"2>/dev/null || kill -TERM {d['pid']}"], timeout=10)
            else:
                rc, out = dc("exec", "-T", "--user", "paseo", "paseo", "bash", "-lc",
                             f"kill -TERM -- -$(ps -o pgid= {d['pid']} | tr -d ' ') "
                             f"2>/dev/null || kill -TERM {d['pid']}", timeout=15)
            ST.note(f"killed dev server pid {d['pid']} ({d['where']}) rc={rc}")
            time.sleep(1.5)
            refresh_all()

        self.ui.confirm = (f"kill {d['where']} dev server pid {d['pid']} "
                           f"({d['gb']:.1f}GB)?",
                           lambda: threading.Thread(target=do_kill, daemon=True).start())

    # -- key dispatch ---------------------------------------------------------
    def handle(self, key, ch):
        ui = self.ui
        tab = ui.TABS[ui.tab]

        # global -------------------------------------------------------------
        if ch in ("R",):
            refresh_all()
            ui.flash("refreshing all probes")
            return True
        if ch == "?":
            ui.confirm = ("__help__", None)
            return True

        # status ---------------------------------------------------------------
        if tab == "status":
            s = self.selected_service()
            if ch == "u":
                self.stream(["up", "-d", "--build"], "compose up -d --build")
                ui.tab = ui.TABS.index("logs")
                return True
            if ch == "d":
                ui.confirm = ("stop the whole stack? (volumes and logins are kept)",
                              lambda: self.stream(["down"], "compose down"))
                return True
            if ch == "r":
                args = (["--profile", s.profile] if s.profile else []) + ["restart", s.service]
                self.stream(args, f"restart {s.service}")
                return True
            if ch == "B":
                ui.confirm = ("rebuild the agent image from scratch? (slow, no cache)",
                              lambda: (self.stream(["build", "--no-cache"], "build --no-cache"),
                                       setattr(ui, "tab", ui.TABS.index("logs"))))
                return True
            if ch == "l":
                args = (["--profile", s.profile] if s.profile else []) + \
                       ["logs", "-f", "--tail", "200", s.service]
                self.stream(args, f"logs: {s.service}")
                ui.tab = ui.TABS.index("logs")
                return True
            if ch == "s":
                self.interactive(["exec", "--user", "paseo", "paseo", "bash", "-l"],
                                 "── shell in the paseo container (exit to return) ──",
                                 "shell")
                return True
            if ch == "o":
                if s.service == "paseo":
                    self.open_url(f"http://127.0.0.1:{ST.port('PASEO_PORT', 6767)}")
                elif s.service == "9router":
                    self.open_url(f"http://127.0.0.1:{ST.port('NINEROUTER_PORT', 20128)}/dashboard")
                else:
                    ui.flash("no local URL for that service")
                return True

        # memory ---------------------------------------------------------------
        if tab == "memory":
            if ch == "K":
                self.kill_devserver()
                return True
            if ch == "g":
                ui.tab = ui.TABS.index("guards")
                return True

        # auth -----------------------------------------------------------------
        if tab == "auth":
            if key in (curses.KEY_ENTER, 10, 13):
                idx = max(0, min(ui.sel, len(AUTH_TOOLS) - 1))
                key_, label, _bin, _f, _jf, _jk, cmd = AUTH_TOOLS[idx]
                self.interactive(
                    ["exec", "-it", "--user", "paseo", "paseo"] + shlex.split(cmd),
                    f"── {label} login ──\n"
                    f"follow the prompts. credentials are written to the paseo-home volume\n"
                    f"and survive restarts, rebuilds and image updates.\n"
                    f"quit the CLI (ctrl-C or /exit) to come back to the panel.",
                    label)
                return True
            if ch == "A":
                for key_, label, _b, _f, _jf, _jk, cmd in AUTH_TOOLS:
                    self.interactive(
                        ["exec", "-it", "--user", "paseo", "paseo"] + shlex.split(cmd),
                        f"── {label} login ──  (exit to move on to the next CLI)", label)
                refresh_all()
                return True
            if ch == "s":
                self.interactive(["exec", "--user", "paseo", "paseo", "bash", "-l"],
                                 "── shell in the paseo container ──", "shell")
                return True

        # tunnels --------------------------------------------------------------
        if tab == "tunnels":
            if ch == "q":
                self.start_quick_tunnel()
                return True
            if ch == "n":
                self.start_named_tunnel()
                return True
            if ch == "v":
                self.interactive(
                    ["exec", "-it", "--user", "paseo", "paseo", "bash", "-lc",
                     "code tunnel --accept-server-license-terms --name devstack "
                     "2>&1 | tee -a /home/paseo/.vscode-tunnel.log"],
                    "── VS Code dev tunnel ──\n"
                    "follow the device-login prompt; the vscode.dev URL is printed below it.\n"
                    "ctrl-C to stop the tunnel and return to the panel.",
                    "vscode tunnel")
                return True
            if ch == "x":
                self.stop_tunnels()
                return True
            if ch == "c":
                self.copy_urls()
                return True

        # logs -----------------------------------------------------------------
        if tab == "logs":
            if ch == "s":
                ui.tab = ui.TABS.index("status")
                ui.flash("pick a service with ↑↓ then press l")
                return True
            if ch == "f" and ui.stream:
                ui.stream.scroll = 0
                return True
            if ch == "x" and ui.stream:
                ui.stream.stop()
                ui.flash("stopped")
                return True

        # doctor ---------------------------------------------------------------
        if tab == "doctor":
            if key in (curses.KEY_ENTER, 10, 13):
                self.stream_raw(["bash", os.path.join(ROOT, "scripts", "doctor.sh")],
                                "doctor")
                return True
            if ch == "x" and ui.stream:
                ui.stream.stop()
                return True

        # guards ---------------------------------------------------------------
        if tab == "guards":
            if key in (curses.KEY_ENTER, 10, 13):
                script = (
                    'echo "── devserver-guard (dry run) ──"; '
                    'DEVSERVER_GUARD_DRY_RUN=1 DEVSERVER_GUARD_STDOUT=1 '
                    f'python3 {shlex.quote(os.path.join(ROOT, "scripts/guard/devserver-guard.py"))} || true; '
                    'echo; echo "── cache-trim (dry run) ──"; '
                    'CACHE_TRIM_DRY_RUN=1 CACHE_TRIM_STDOUT=1 '
                    f'CACHE_TRIM_ROOTS={shlex.quote(os.path.join(ROOT, "workspace"))} '
                    f'python3 {shlex.quote(os.path.join(ROOT, "scripts/guard/cache-trim.py"))} || true'
                )
                self.stream_raw(["bash", "-lc", script], "guards — dry run")
                return True
            if ch == "i" and not IS_MAC:
                self.interactive_raw()
                return True

        # admin ----------------------------------------------------------------
        if tab == "admin":
            with ST.lock:
                daemons = list(ST.admin.get("daemons", []))
                router = dict(ST.admin.get("router", {}))

            if key in (curses.KEY_ENTER, 10, 13):
                self.stream_raw(["bash", os.path.join(ROOT, "scripts", "update.sh")],
                                "checking for updates (dry run)")
                return True

            if ch == "U":
                # Applying an update rebuilds and restarts, so confirm first —
                # containers go down for a minute. Volumes are never touched.
                ui.confirm = (
                    "apply the update? rebuilds and restarts (credentials are kept)",
                    lambda: self.stream_raw(
                        ["bash", os.path.join(ROOT, "scripts", "update.sh"), "--apply"],
                        "updating"))
                return True

            if ch == "S":
                # --no-build for the same reason new-daemon.sh uses it: this
                # image carries five agent CLIs and Chromium, and compiling it
                # beside a live stack is what OOM-killed a 31GB host. If the
                # image is missing, say so rather than starting a build here.
                c = self.compose("--profile", "satellites", "up", "-d", "--no-build")
                if c:
                    self.stream_raw(c, "starting satellite daemons")
                return True

            if ch == "N":
                # A new tenant is a new satellite: its own volume, workspace,
                # port and pairing identity. The script edits .env and brings it
                # up, and it needs a name, so hand over the terminal.
                handoff(["bash", os.path.join(ROOT, "scripts", "new-daemon.sh")],
                        "── add a daemon ──")
                refresh_all()
                return True

            if ch == "D":
                port = router.get("port", "20128")
                handoff(["bash", "-lc",
                         f"cd {shlex.quote(ROOT)} && "
                         f"bash scripts/router-tunnel.sh {shlex.quote(str(port))}"],
                        "── 9router dashboard tunnel ──")
                refresh_all()
                return True

            if ch == "p" and daemons:
                d = daemons[min(ui.sel, len(daemons) - 1)]
                handoff(["docker", "exec", "-it", "--user", "paseo", d["container"],
                         "paseo", "daemon", "pair", "--relay"],
                        f"── pairing link for {d.get('name', d['container'])} ──")
                return True
        return False

    def interactive_raw(self):
        """Guard install needs sudo, so it needs the real tty for the password."""
        env_line = (f"sudo DEVSTACK_USER=${{DEVSTACK_USER:-paseo}} "
                    f"WORKSPACE_ROOT={shlex.quote(os.path.join(ROOT, 'workspace'))} "
                    f"bash {shlex.quote(os.path.join(ROOT, 'scripts/guard/install-guards.sh'))}")
        handoff(["bash", "-lc", env_line],
                "── installing the memory/disk guards (sudo) ──")
        refresh_all()


# ══ main loop ════════════════════════════════════════════════════════════════

def main(stdscr):
    curses.curs_set(0)
    stdscr.nodelay(True)          # getch returns -1 instead of blocking, so the
    stdscr.timeout(200)           # screen keeps refreshing while nothing is typed
    stdscr.keypad(True)           # decode arrows/PgUp into KEY_* constants
    ui = UI(stdscr)
    act = Actions(ui)
    start_collectors()

    last_draw = 0.0
    while True:
        now = time.time()
        # Redraw at ~5fps, or immediately after a keypress. Cheap: everything
        # drawn is already in memory, no subprocess is ever touched here.
        if now - last_draw > 0.2:
            ui.frame += 1
            ui.draw()
            last_draw = now

        try:
            key = stdscr.getch()
        except KeyboardInterrupt:
            break
        if key == -1:
            continue

        ch = chr(key) if 32 <= key < 127 else ""

        # a pending confirm/help swallows the next key
        if ui.confirm:
            prompt, cb = ui.confirm
            ui.confirm = None
            if prompt == "__help__":
                ui.draw()
                continue
            if ch in ("y", "Y") and cb:
                cb()
            else:
                ui.flash("cancelled")
            ui.draw()
            continue

        if key == curses.KEY_RESIZE:
            # curses already resized its internal structures; just repaint.
            ui.draw()
            continue

        if ch in ("Q",) or key == 17:                 # Q or ctrl-Q
            break
        if key == 9 or ch == "\t":                    # Tab
            ui.tab = (ui.tab + 1) % len(ui.TABS)
            ui.sel = 0
            continue
        if key == curses.KEY_BTAB:                    # shift-Tab
            ui.tab = (ui.tab - 1) % len(ui.TABS)
            ui.sel = 0
            continue
        if ch and ch.isdigit() and ch != "0":
            i = int(ch) - 1
            if i < len(ui.TABS):
                ui.tab = i
                ui.sel = 0
            continue

        # scrolling in a stream pane, row cursor everywhere else
        if key in (curses.KEY_UP,) or ch == "k":
            if ui.TABS[ui.tab] in ("logs", "doctor") and ui.stream:
                ui.stream.scroll = min(len(ui.stream.lines), ui.stream.scroll + 1)
            else:
                ui.sel = max(0, ui.sel - 1)
            continue
        if key in (curses.KEY_DOWN,) or ch == "j":
            if ui.TABS[ui.tab] in ("logs", "doctor") and ui.stream:
                ui.stream.scroll = max(0, ui.stream.scroll - 1)
            else:
                ui.sel += 1
            continue
        if key == curses.KEY_PPAGE and ui.stream:
            ui.stream.scroll = min(len(ui.stream.lines), ui.stream.scroll + 20)
            continue
        if key == curses.KEY_NPAGE and ui.stream:
            ui.stream.scroll = max(0, ui.stream.scroll - 20)
            continue

        act.handle(key, ch)

    # -- teardown -------------------------------------------------------------
    _stop.set()
    if ui.stream:
        ui.stream.stop()


def cli():
    if not sys.stdout.isatty() or not sys.stdin.isatty():
        print("devstack-tui needs an interactive terminal.\n"
              "over ssh: make sure you did not pass -T.\n"
              "for scripting, use the make targets instead (make help).", file=sys.stderr)
        return 2
    if os.environ.get("TERM", "") in ("", "dumb"):
        print("TERM is unset or 'dumb' — try:  TERM=xterm-256color make tui", file=sys.stderr)
        return 2
    try:
        curses.wrapper(main)          # wrapper restores the terminal even on a
    except KeyboardInterrupt:         # traceback, which is the whole reason to
        pass                          # use it rather than initscr() by hand
    except curses.error as exc:
        print(f"curses failed: {exc}\n"
              "the terminal may be too small (needs ~80x20) or TERM may be wrong.",
              file=sys.stderr)
        return 1
    finally:
        _stop.set()
    return 0


if __name__ == "__main__":
    sys.exit(cli())
