#!/usr/bin/env python3
"""
Cache trim — Linux/container port.

Disk is the other half of the dev-server problem. Two caches nothing evicts:

  <app>/.next/dev      Turbopack's DEV-SERVER cache. Observed 35GB in one app
                       and 12GB in another, while the real build output beside
                       it (.next/server) was 185MB — i.e. 99% of .next was dev
                       scratch. Deleting ONLY .next/dev preserves build output.
  <repo>/.turbo/cache  Observed 85GB, entries months old, one manifest 28MB.

Both are gitignored, so both are free to delete. Neither is Paseo's doing, but
Paseo multiplies them: every worktree is a full checkout growing its own.

An oversized .next/dev is not just disk. Turbopack memory-maps a large part of
it at startup, which is a big part of why a dev server reaches 9-10GB within 90
seconds — so trimming an oversized cache is also a MEMORY fix, which is why this
ships next to devserver-guard rather than as a generic disk cleaner.

Run daily. Safe to run while things are up: it skips caches belonging to a
running dev server unless they are stale.
"""

import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
LOG = os.environ.get("CACHE_TRIM_LOG", os.path.join(HOME, ".paseo", "cache-trim.log"))

ROOTS = [p for p in os.environ.get(
    "CACHE_TRIM_ROOTS", f"/workspace:{HOME}/projects:{HOME}/workspace"
).split(":") if p and os.path.isdir(p)]

NEXT_DEV_MAX_AGE_DAYS = float(os.environ.get("CACHE_TRIM_NEXT_AGE_DAYS", "3"))
NEXT_DEV_MAX_SIZE_GB  = float(os.environ.get("CACHE_TRIM_NEXT_MAX_GB", "2.0"))
TURBO_MAX_AGE_DAYS    = float(os.environ.get("CACHE_TRIM_TURBO_AGE_DAYS", "7"))
MAX_DEPTH             = 6
LOG_MAX_BYTES         = 1_000_000
DRY_RUN               = os.environ.get("CACHE_TRIM_DRY_RUN", "") == "1"


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
    if os.environ.get("CACHE_TRIM_STDOUT") == "1":
        print(msg, flush=True)


def dev_servers_running():
    """True if any Next dev server is up. An in-use .next/dev is only removed
    when it is oversized, never merely because it is old."""
    try:
        out = subprocess.run(["ps", "-eo", "args="], capture_output=True,
                             text=True, timeout=20).stdout
    except Exception:
        return True   # cannot tell -> assume yes, i.e. be conservative
    return bool(re.search(r"\bnext-server\s+\(v[\d.]+\)", out))


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path, onerror=lambda e: None):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def find_dirs(root, name):
    """Find directories called `name`, bounded in depth, skipping node_modules
    and .git so a big monorepo does not take minutes to scan."""
    hits = []
    root_depth = root.rstrip("/").count("/")
    for cur, dirs, _files in os.walk(root, onerror=lambda e: None):
        if cur.count("/") - root_depth >= MAX_DEPTH:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
        if name in dirs:
            hits.append(os.path.join(cur, name))
            dirs.remove(name)
    return hits


def newest_mtime(path):
    newest = 0
    for root, _dirs, files in os.walk(path, onerror=lambda e: None):
        for f in files:
            try:
                newest = max(newest, os.lstat(os.path.join(root, f)).st_mtime)
            except OSError:
                pass
    return newest


def trim_next_dev():
    freed = 0
    cutoff = time.time() - NEXT_DEV_MAX_AGE_DAYS * 86400
    in_use = dev_servers_running()
    for root in ROOTS:
        for nxt in find_dirs(root, ".next"):
            d = os.path.join(nxt, "dev")
            if not os.path.isdir(d):
                continue
            size = dir_size(d)
            stale = newest_mtime(d) < cutoff
            oversized = size > NEXT_DEV_MAX_SIZE_GB * 1024 ** 3
            if not (stale or oversized):
                continue
            if in_use and not oversized:
                continue
            reason = "stale" if stale else f"oversized (>{NEXT_DEV_MAX_SIZE_GB}GB)"
            if DRY_RUN:
                log(f"DRY-RUN would remove {size/1024**3:.1f}GB  {d}  [{reason}]")
            else:
                shutil.rmtree(d, ignore_errors=True)
                log(f"removed {size/1024**3:.1f}GB  {d}  [{reason}]")
            freed += size
    return freed


def trim_turbo():
    freed = 0
    cutoff = time.time() - TURBO_MAX_AGE_DAYS * 86400
    for root in ROOTS:
        for turbo in find_dirs(root, ".turbo"):
            cache = os.path.join(turbo, "cache")
            if not os.path.isdir(cache):
                continue
            n = 0
            for entry in os.listdir(cache):
                p = os.path.join(cache, entry)
                try:
                    if os.lstat(p).st_mtime >= cutoff:
                        continue
                    size = dir_size(p) if os.path.isdir(p) else os.lstat(p).st_size
                except OSError:
                    continue
                if DRY_RUN:
                    freed += size; n += 1
                    continue
                shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.remove(p)
                freed += size; n += 1
            if n:
                verb = "would trim" if DRY_RUN else "trimmed"
                log(f"{verb} {n} .turbo entries older than {TURBO_MAX_AGE_DAYS}d in {cache}")
    return freed


def main():
    if not ROOTS:
        log("no roots to scan (set CACHE_TRIM_ROOTS)")
        return 0
    freed = trim_next_dev() + trim_turbo()
    if freed:
        log(f"reclaimed {freed/1024**3:.1f}GB total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
