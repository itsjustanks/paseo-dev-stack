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
