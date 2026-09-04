#!/usr/bin/env python3
"""
paseo-dev-stack control panel.

Why stdlib curses and not textual/ink/bubbletea: the entire selling point of
this repo is one command on a fresh box. Anything needing `pip install` or
`npm i` adds a step that can fail (PEP 668 externally-managed environments on
Ubuntu 24.04+ break `pip install --user` outright). Python 3 is guaranteed on
both the host and in the container, and curses is in its stdlib on Linux/macOS.

Design notes:
  * Docker calls are SLOW (100-800ms). They run on a background thread and the
    UI paints from a cached snapshot, so keys never block.
  * Interactive handoff (agent logins, shells, logs) fully tears down curses,
    restores the terminal, runs the child attached to the real tty, then
    rebuilds. Doing this wrong leaves the terminal in raw mode with no echo,
    which looks like a hung shell.
  * Everything degrades: no docker daemon, no .env, missing container, no
    systemd (macOS) are all displayed states, not crashes.
"""

import curses
import json
import os
import shutil
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFRESH = 3.0            # seconds between background polls

# ── data collection (background thread) ─────────────────────────────────────

def sh(cmd, timeout=15):
    """Run a command, return (rc, stdout). Never raises."""
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return 1, str(e)


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.services = []       # [{name, state, status, health}]
        self.stats = {}          # name -> (mem_used, mem_limit, mem_pct, cpu)
        self.host_mem = None     # (used_gb, total_gb, avail_gb)
        self.devservers = []     # [{pid, gb, hours}]
        self.tunnels = []        # [(kind, url)]
        self.err = None
        self.updated = 0
        self.busy = False

    def snapshot(self):
        with self.lock:
            return dict(services=list(self.services), stats=dict(self.stats),
                        host_mem=self.host_mem, devservers=list(self.devservers),
                        tunnels=list(self.tunnels), err=self.err,
                        updated=self.updated, busy=self.busy)


def collect(st):
    """One polling pass. Cheap calls first so the UI fills in progressively."""
    with st.lock:
        st.busy = True

    rc, out = sh(["docker", "compose", "ps", "--format", "json"], timeout=20)
    services, err = [], None
    if rc != 0:
        low = out.lower()
        if "cannot connect" in low or "daemon" in low:
            err = "Docker daemon is not running"
        elif "no configuration file" in low:
            err = "no docker-compose.yml here"
        else:
            err = out.strip().splitlines()[0][:70] if out.strip() else "docker error"
    else:
        # `--format json` emits one JSON object PER LINE (not a JSON array) in
        # compose v2; older builds emit an array. Handle both.
        txt = out.strip()
        rows = []
        if txt.startswith("["):
            try: rows = json.loads(txt)
            except Exception: rows = []
        else:
            for line in txt.splitlines():
                line = line.strip()
                if not line: continue
                try: rows.append(json.loads(line))
                except Exception: pass
        for r in rows:
            services.append({
                "name":   r.get("Service") or r.get("Name", "?"),
                "state":  (r.get("State") or "?").lower(),
                "status": r.get("Status") or "",
                "health": (r.get("Health") or "").lower(),
            })

    stats = {}
    if not err:
        rc, out = sh(["docker", "stats", "--no-stream", "--format",
                      "{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}"], timeout=20)
        if rc == 0:
            for line in out.strip().splitlines():
                parts = line.split("\t")
                if len(parts) >= 4:
                    stats[parts[0]] = (parts[1], parts[2], parts[3])

    host_mem = None
    try:
        if os.path.exists("/proc/meminfo"):
            info = {}
            with open("/proc/meminfo") as f:
                for line in f:
                    k, _, v = line.partition(":")
                    info[k] = int(v.split()[0])
            total = info["MemTotal"] / 1048576
            avail = info.get("MemAvailable", 0) / 1048576
            host_mem = (total - avail, total, avail)
        elif shutil.which("sysctl"):
            rc, out = sh(["sysctl", "-n", "hw.memsize"], timeout=5)
            if rc == 0 and out.strip().isdigit():
                total = int(out.strip()) / 1073741824
                host_mem = (None, total, None)
    except Exception:
        pass

    devs = []
    rc, out = sh(["ps", "-eo", "pid=,etimes=,rss=,args="], timeout=15)
    if rc == 0:
        for line in out.splitlines():
            if "next-server (v" not in line:
                continue
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            try:
                devs.append({"pid": int(parts[0]),
                             "hours": int(parts[1]) / 3600,
                             "gb": int(parts[2]) / 1048576})
            except ValueError:
                pass

    tunnels = []
    rc, out = sh(["docker", "compose", "logs", "--tail", "400",
                  "cloudflared-quick"], timeout=20)
    if rc == 0:
        for line in out.splitlines():
            i = line.find("https://")
            if i >= 0 and "trycloudflare.com" in line:
                url = line[i:].split()[0].strip().rstrip('|,"')
                tunnels.append(("quick", url))
    if tunnels:
        tunnels = [tunnels[-1]]
    for name, label in (("cloudflared", "named"),):
        if any(s["name"] == name and s["state"] == "running" for s in services):
            tunnels.append((label, "(configured hostname)"))

    with st.lock:
        st.services, st.stats, st.host_mem = services, stats, host_mem
        st.devservers, st.tunnels, st.err = devs, tunnels, err
        st.updated = time.time()
        st.busy = False


def poller(st, stop):
    while not stop.is_set():
        try:
            collect(st)
        except Exception as e:
            with st.lock:
                st.err = f"poll failed: {e}"[:70]
                st.busy = False
        stop.wait(REFRESH)


# ── actions ─────────────────────────────────────────────────────────────────

ACTIONS = [
    ("u", "up",            "start / rebuild the stack",        ["docker", "compose", "up", "-d", "--build"], False),
    ("d", "down",          "stop the stack (volumes kept)",    ["docker", "compose", "down"],                False),
    ("r", "restart",       "restart services",                 ["docker", "compose", "restart"],             False),
    ("l", "logs",          "tail logs (interactive)",          None,                                          True),
    ("s", "shell",         "shell in the container",           None,                                          True),
    ("a", "auth",          "log in to an agent CLI",           None,                                          True),
    ("t", "quick tunnel",  "public URL, no account",           ["make", "quick-tunnel"],                     False),
    ("v", "vscode tunnel", "vscode.dev dev tunnel",            ["make", "code-tunnel-bg"],                   False),
    ("b", "browser view",  "open the live browser viewer",     ["make", "browser-view"],                     False),
    ("k", "doctor",        "verify every component",           None,                                          True),
    ("m", "autotune",      "size memory to this host",         ["make", "autotune"],                         True),
    ("9", "router",        "9router status",                   ["make", "router-status"],                    True),
    ("g", "agents",        "list agent CLIs",                  ["make", "agents"],                           True),
]

AGENT_LOGINS = [
    ("claude", ["docker", "compose", "exec", "--user", "paseo", "paseo", "claude"]),
    ("codex",  ["docker", "compose", "exec", "--user", "paseo", "paseo", "codex", "login"]),
    ("kimi",   ["docker", "compose", "exec", "--user", "paseo", "paseo", "kimi"]),
    ("cursor", ["docker", "compose", "exec", "--user", "paseo", "paseo", "cursor-agent", "login"]),
]


def handoff(stdscr, cmd, pause=True):
    """Give the real terminal to a child process, then take it back.

    curses must be fully torn down first: a child sharing a terminal left in
    cbreak/noecho mode gets no line editing and no echo, which reads as a hang.
    """
    curses.def_prog_mode()
    curses.endwin()
    os.system("clear")
    try:
        subprocess.call(cmd, cwd=ROOT)
    except Exception as e:
        print(f"\nfailed: {e}")
    if pause:
        try:
            input("\n[enter] to return to the panel ")
        except (EOFError, KeyboardInterrupt):
            pass
    stdscr.clear()
    curses.reset_prog_mode()
    curses.curs_set(0)
    stdscr.refresh()


def pick(stdscr, title, options):
    """Small centred chooser. Returns the selected index or None."""
    h, w = stdscr.getmaxyx()
    bh, bw = len(options) + 4, max(len(title), max(len(o) for o in options)) + 8
    y, x = max(0, (h - bh) // 2), max(0, (w - bw) // 2)
    win = curses.newwin(bh, bw, y, x)
    win.keypad(True)
    sel = 0
    while True:
        win.erase()
        win.box()
        win.addnstr(0, 2, f" {title} ", bw - 4, curses.A_BOLD)
        for i, o in enumerate(options):
            attr = curses.A_REVERSE if i == sel else curses.A_NORMAL
            win.addnstr(2 + i, 3, o.ljust(bw - 6), bw - 6, attr)
        win.refresh()
        k = win.getch()
        if k in (curses.KEY_UP, ord("k")):
            sel = (sel - 1) % len(options)
        elif k in (curses.KEY_DOWN, ord("j")):
            sel = (sel + 1) % len(options)
        elif k in (curses.KEY_ENTER, 10, 13):
            return sel
        elif k in (27, ord("q")):
            return None


# ── drawing ─────────────────────────────────────────────────────────────────

def draw(stdscr, snap, msg):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    C = curses.color_pair
    row = 0

    def put(y, x, text, attr=0):
        if 0 <= y < h and x < w:
            stdscr.addnstr(y, x, text, max(0, w - x - 1), attr)

    title = " paseo-dev-stack "
    put(row, 0, title + "─" * max(0, w - len(title) - 1), curses.A_BOLD | C(4))
    age = time.time() - snap["updated"] if snap["updated"] else 0
    tag = "polling…" if snap["busy"] else f"{age:.0f}s ago"
    put(row, max(0, w - len(tag) - 2), tag, C(5))
    row += 2

    if snap["err"]:
        put(row, 2, f"⚠ {snap['err']}", C(2) | curses.A_BOLD)
        row += 2

    put(row, 2, "SERVICES", curses.A_BOLD); row += 1
    if not snap["services"] and not snap["err"]:
        put(row, 4, "nothing running — press [u] to start", C(5)); row += 1
    for s in snap["services"]:
        ok = s["state"] == "running"
        dot, col = ("●", C(1)) if ok else ("○", C(2))
        put(row, 4, dot, col)
        put(row, 6, s["name"][:14].ljust(15), curses.A_BOLD if ok else 0)
        # compose ps already embeds "(healthy)" in Status, so only append the
        # Health field when Status does not already carry it.
        status = s["status"]
        if s["health"] and s["health"] not in status.lower():
            status = f"{status} ({s['health']})"
        put(row, 21, status[:34], C(5))
        # docker stats keys on CONTAINER name; compose ps gives SERVICE name.
        for cname, (mem, pct, cpu) in snap["stats"].items():
            if cname.endswith(s["name"]) or s["name"] in cname:
                put(row, 56, f"{mem}  {pct}  cpu {cpu}"[:w - 57], C(4))
                break
        row += 1
    row += 1

    put(row, 2, "MEMORY", curses.A_BOLD); row += 1
    hm = snap["host_mem"]
    if hm and hm[0] is not None:
        used, total, avail = hm
        barw = min(40, max(10, w - 30))
        filled = int(barw * used / total) if total else 0
        col = C(1) if avail > 4 else (C(3) if avail > 1.5 else C(2))
        put(row, 4, "host  [" + "█" * filled + "·" * (barw - filled) + "]", col)
        put(row, 4 + barw + 9, f"{used:.1f}/{total:.0f}GB  {avail:.1f}GB free", col)
    elif hm:
        put(row, 4, f"host  {hm[1]:.0f}GB total", C(5))
    else:
        put(row, 4, "host memory unavailable", C(5))
    row += 1

    if snap["devservers"]:
        for d in snap["devservers"][:3]:
            col = C(2) if d["gb"] > 10 else (C(3) if d["gb"] > 6 else C(1))
            put(row, 4, f"dev server pid {d['pid']}  {d['gb']:.1f}GB  {d['hours']:.1f}h", col)
            row += 1
    else:
        put(row, 4, "no dev servers running", C(5)); row += 1
    row += 1

    if snap["tunnels"]:
        put(row, 2, "PUBLIC", curses.A_BOLD); row += 1
        for kind, url in snap["tunnels"][:3]:
            put(row, 4, f"{kind:<7} {url}", C(4)); row += 1
        row += 1

    put(row, 2, "ACTIONS", curses.A_BOLD); row += 1
    col_w = 34
    cols = max(1, (w - 4) // col_w)
    for i, (key, name, desc, _cmd, _inter) in enumerate(ACTIONS):
        cy = row + i // cols
        cx = 4 + (i % cols) * col_w
        if cy >= h - 2:
            break
        put(cy, cx, f"[{key}]", C(4) | curses.A_BOLD)
        put(cy, cx + 4, f" {name}", curses.A_BOLD)
        put(cy, cx + 5 + len(name) + 1, desc[:col_w - len(name) - 8], C(5))

    foot = msg if msg else "[q] quit   [enter] refresh   arrows in menus"
    put(h - 1, 0, foot.ljust(w - 1)[:w - 1],
        curses.A_REVERSE if msg else C(5))
    stdscr.refresh()


def main(stdscr):
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN,  -1)
    curses.init_pair(2, curses.COLOR_RED,    -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_CYAN,   -1)
    curses.init_pair(5, curses.COLOR_BLUE,   -1)
    stdscr.nodelay(True)
    stdscr.keypad(True)

    st = State()
    stop = threading.Event()
    threading.Thread(target=poller, args=(st, stop), daemon=True).start()

    msg = ""
    try:
        while True:
            draw(stdscr, st.snapshot(), msg)
            time.sleep(0.1)
            try:
                k = stdscr.getch()
            except curses.error:
                k = -1
            if k == -1:
                continue
            msg = ""
            ch = chr(k) if 0 <= k < 256 else ""

            if ch in ("q", "Q"):
                break
            if k in (curses.KEY_ENTER, 10, 13):
                threading.Thread(target=collect, args=(st,), daemon=True).start()
                msg = "refreshing…"
                continue

            if ch == "l":
                snap = st.snapshot()
                names = [s["name"] for s in snap["services"]] or ["paseo"]
                i = pick(stdscr, "logs for", names)
                if i is not None:
                    handoff(stdscr, ["docker", "compose", "logs", "-f",
                                     "--tail", "100", names[i]])
                continue
            if ch == "s":
                handoff(stdscr, ["docker", "compose", "exec", "--user", "paseo",
                                 "paseo", "bash", "-l"], pause=False)
                continue
            if ch == "a":
                i = pick(stdscr, "log in to", [n for n, _ in AGENT_LOGINS])
                if i is not None:
                    handoff(stdscr, AGENT_LOGINS[i][1])
                continue

            known = {a[0] for a in ACTIONS} | {"q", "Q", "l", "s", "a"}
            if ch not in known:
                continue   # swallow stray keys (arrows send multi-byte escapes)
            for key, name, _desc, cmd, interactive in ACTIONS:
                if ch != key or cmd is None:
                    continue
                if interactive:
                    handoff(stdscr, cmd)
                else:
                    msg = f"running {name}…"
                    draw(stdscr, st.snapshot(), msg)
                    rc, out = sh(cmd, timeout=900)
                    tail = [l for l in out.strip().splitlines() if l.strip()]
                    msg = (f"{name}: ok" if rc == 0 else
                           f"{name} FAILED: {tail[-1][:60] if tail else rc}")
                    threading.Thread(target=collect, args=(st,), daemon=True).start()
                break
    finally:
        stop.set()


if __name__ == "__main__":
    if not shutil.which("docker"):
        print("docker not found on PATH", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(os.path.join(ROOT, "docker-compose.yml")):
        print(f"no docker-compose.yml in {ROOT}", file=sys.stderr)
        sys.exit(1)
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
