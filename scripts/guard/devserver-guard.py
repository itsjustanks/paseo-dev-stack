#!/usr/bin/env python3
"""
Dev server guard — Linux/container port.

Paseo workspace scripts (paseo.json -> scripts.*.type == "service") each start a
`next dev`. With several active workspaces that is several Next dev servers, and
three things go wrong:

  1. BALLOON  - Turbopack is Rust, so its memory sits OUTSIDE the V8 heap and
                NODE_OPTIONS=--max-old-space-size cannot bound it. A single
                next-server was observed at 21GB.
  2. RESPAWN  - `next dev` supervises `next-server` and restarts it when it
                dies, so a ballooning server becomes an infinite
                grow -> OOM -> respawn loop. Killing only the child never
                helps; the parent supervisor must go first.
  3. ORPHAN   - closing a workspace does not always stop its service. Seen at
                ppid 1, still running days later.

Any of those starves the box badly enough that Paseo's own health probe times
out. This guard is upstream of that: it removes the cause.

DIFFERENCES FROM THE macOS ORIGINAL
  - Memory comes from /proc/<pid>/status (VmRSS) plus, when the kernel exposes
    it, the process's cgroup memory.current. macOS `top -stats mem` and
    phys_footprint do not exist here.
  - Available memory comes from MemAvailable in /proc/meminfo, which already
    accounts for reclaimable cache — the direct analogue of the vm_stat sum.
  - Scheduling is a systemd timer or the in-container loop, not launchd.

Run once per invocation; schedule it every 60s.
"""

import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
LOG = os.environ.get("DEVSERVER_GUARD_LOG", os.path.join(HOME, ".paseo", "devserver-guard.log"))

# A Next dev server has never completed a first compile below ~6.1GB (observed
# 6.1-11.0GB), so a 6GB cap kills it mid-compile and reads as "next-server keeps
# crashing". 12.0 clears the observed peak. MAX_AGE_HOURS is what actually
# catches leaks: a leak stays big, a compile only spikes.
MAX_FOOTPRINT_GB = float(os.environ.get("DEVSERVER_GUARD_MAX_GB", "12.0"))
MAX_AGE_HOURS    = float(os.environ.get("DEVSERVER_GUARD_MAX_AGE_H", "2.0"))
MAX_SERVERS      = int(os.environ.get("DEVSERVER_GUARD_MAX_SERVERS", "1"))
# Count-based reaping ONLY under real pressure. Two idle dev servers are
# harmless (~200-500MB each); they only balloon once they serve a request.
# Reaping on count alone kills servers nobody needed dead.
MIN_AVAIL_GB     = float(os.environ.get("DEVSERVER_GUARD_MIN_AVAIL_GB", "6.0"))
LOG_MAX_BYTES    = 2_000_000
DRY_RUN          = os.environ.get("DEVSERVER_GUARD_DRY_RUN", "") == "1"

# Only ever act on these. Anything not matching is untouchable.
# The version suffix is what makes it the real process rather than any shell
# whose command line merely mentions the name (a grep, a heredoc, this guard's
# own test harness).
SERVER_RE = re.compile(r"\bnext-server\s+\(v[\d.]+\)")
SUPERVISOR_RE = re.compile(
    r"(node|pnpm|npm|yarn|bun).*(next dev|turbo run dev|run dev|/next\b.*\bdev\b)"
)
# 9router's dashboard is itself a Next app, so its child shows up as
# `next-server (vX)` exactly like a workspace dev server. Without the 9router
# term, this guard reaps the live model router every 60s and every agent CLI
# routed through it loses its connection. 9router supervises itself; it is
# never this guard's business. Match on the PARENT CHAIN too, not just the
# process's own cmdline — that was the bug the first fix missed.
NEVER_KILL_RE = re.compile(
    r"Paseo|paseo|9router|/(claude|codex|kimi)\b|cursor-agent|devin|code tunnel|vscode"
)


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_MAX_BYTES:
            os.replace(LOG, LOG + ".1")
        ts = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG, "a") as f:
            f.write(f"{ts}  {msg}\n")
    except Exception:
        pass
    if os.environ.get("DEVSERVER_GUARD_STDOUT") == "1":
        print(msg, flush=True)


class ProcScanFailed(Exception):
    """Raised when a process scan fails.

    Collapsing "no match" and "scan failed" into the same empty list is how a
    watchdog half-kills a live process tree. Under exactly the thrash this
    guard exists to prevent, scans are the most likely thing to fail — so a
    failed scan aborts the pass instead of reaping.
    """


def available_gb():
    """MemAvailable: what the kernel can hand out without swapping. Returns None
    if unreadable, which callers MUST treat as 'no pressure' — never guess in
    favour of killing."""
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) / (1024 ** 2)  # kB -> GB
    except Exception:
        return None
    return None


def footprint_gb(pid):
    """Best available memory figure for a pid.

    Prefers the cgroup's memory.current when the process is the cgroup's main
    occupant, because that captures Turbopack's native (non-heap) allocations
    the way phys_footprint does on macOS. Falls back to VmRSS.
    """
    try:
        with open(f"/proc/{pid}/status") as f:
            rss = None
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) / (1024 ** 2)
                    break
    except Exception:
        return None
    return rss


def processes():
    """List of {pid, ppid, age_h, cmd} for everything running."""
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid=,ppid=,etimes=,args="],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        raise ProcScanFailed("ps timed out")
    if out.returncode != 0:
        raise ProcScanFailed(f"ps rc={out.returncode}")

    procs = []
    for line in out.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, ppid, etimes, cmd = parts
        try:
            procs.append({
                "pid": int(pid), "ppid": int(ppid),
                "age_h": int(etimes) / 3600.0, "cmd": cmd,
            })
        except ValueError:
            continue
    if not procs:
        raise ProcScanFailed("ps returned nothing")
    return procs


def protected(proc, by_pid):
    """True if this process, or anything in its parent chain, is protected."""
    if NEVER_KILL_RE.search(proc["cmd"]):
        return True
    seen, cur = set(), proc
    while cur and cur["ppid"] > 1 and cur["ppid"] not in seen:
        seen.add(cur["ppid"])
        cur = by_pid.get(cur["ppid"])
        if cur and NEVER_KILL_RE.search(cur["cmd"]):
            return True
    return False


def kill_tree(proc, by_pid, reason):
    """Kill the supervisor first, then the server.

    `next dev` restarts `next-server` on death, so killing the child alone just
    starts the loop again.
    """
    targets = []
    parent = by_pid.get(proc["ppid"])
    if parent and SUPERVISOR_RE.search(parent["cmd"]) and not protected(parent, by_pid):
        targets.append(parent)
    targets.append(proc)

    for t in targets:
        label = f"[{t['pid']}] {t['cmd'][:110]}"
        if DRY_RUN:
            log(f"DRY-RUN would kill {label}  ({reason})")
            continue
        try:
            os.kill(t["pid"], signal.SIGTERM)
            log(f"killed {label}  ({reason})")
        except ProcessLookupError:
            pass
        except Exception as e:
            log(f"failed to kill {label}: {e}")
    if not DRY_RUN:
        time.sleep(3)
        for t in targets:
            try:
                os.kill(t["pid"], 0)
                os.kill(t["pid"], signal.SIGKILL)
                log(f"SIGKILL [{t['pid']}] (did not exit on TERM)")
            except (ProcessLookupError, PermissionError):
                pass


def main():
    try:
        procs = processes()
    except ProcScanFailed as e:
        log(f"scan failed, skipping pass: {e}")
        return 0

    by_pid = {p["pid"]: p for p in procs}
    servers = [p for p in procs if SERVER_RE.search(p["cmd"]) and not protected(p, by_pid)]
    if not servers:
        return 0

    avail = available_gb()
    survivors = []
    for s in servers:
        fp = footprint_gb(s["pid"])
        s["gb"] = fp
        if fp is not None and fp > MAX_FOOTPRINT_GB:
            kill_tree(s, by_pid, f"{fp:.1f}GB > {MAX_FOOTPRINT_GB}GB")
        elif s["age_h"] > MAX_AGE_HOURS:
            kill_tree(s, by_pid, f"age {s['age_h']:.1f}h > {MAX_AGE_HOURS}h")
        elif s["ppid"] == 1:
            kill_tree(s, by_pid, "orphaned (ppid 1)")
        else:
            survivors.append(s)

    # Count rule, pressure-gated. Keep the NEWEST: a server that just started is
    # the one someone just asked for; the older one is the forgotten workspace.
    if len(survivors) > MAX_SERVERS and avail is not None and avail < MIN_AVAIL_GB:
        survivors.sort(key=lambda s: s["age_h"])
        for s in survivors[MAX_SERVERS:]:
            kill_tree(s, by_pid,
                      f"over MAX_SERVERS={MAX_SERVERS} ({len(survivors)} healthy, "
                      f"{avail:.1f}GB available < {MIN_AVAIL_GB}GB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
