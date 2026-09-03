#!/usr/bin/env bash
# Install the memory/disk guards as systemd timers on the host.
#
# These are the Linux port of the macOS launchd agents. They exist because a
# Next dev server's memory is native (Turbopack is Rust), so NODE_OPTIONS
# cannot bound it and the kernel OOM killer picks the wrong victim.
#
#   devserver-guard  every 60s  — reaps ballooned/stale/orphaned dev servers
#   cache-trim       daily 04:30 — removes .next/dev and stale .turbo entries
#
# Both are conservative: they never touch Paseo, 9router, or an agent CLI, and
# they abort the pass rather than guess when a process scan fails.
set -euo pipefail

USER_NAME="${DEVSTACK_USER:-paseo}"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/usr/local/lib/devstack

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0)"; exit 1; }
command -v systemctl >/dev/null || { echo "no systemd; skipping guard install"; exit 0; }
id -u "$USER_NAME" >/dev/null 2>&1 || { echo "user $USER_NAME does not exist"; exit 1; }

install -d "$DEST"
install -m 0755 "$SRC/devserver-guard.py" "$SRC/cache-trim.py" "$DEST/"

WORKSPACE="${WORKSPACE_ROOT:-/home/$USER_NAME/devstack/workspace}"

cat > /etc/systemd/system/devserver-guard.service <<UNIT
[Unit]
Description=Reap ballooned/stale Next dev servers
[Service]
Type=oneshot
User=${USER_NAME}
Environment=DEVSERVER_GUARD_MAX_GB=${DEVSERVER_GUARD_MAX_GB:-12.0}
Environment=DEVSERVER_GUARD_MAX_AGE_H=${DEVSERVER_GUARD_MAX_AGE_H:-2.0}
Environment=DEVSERVER_GUARD_MAX_SERVERS=${DEVSERVER_GUARD_MAX_SERVERS:-1}
Environment=DEVSERVER_GUARD_MIN_AVAIL_GB=${DEVSERVER_GUARD_MIN_AVAIL_GB:-6.0}
ExecStart=/usr/bin/python3 ${DEST}/devserver-guard.py
UNIT

cat > /etc/systemd/system/devserver-guard.timer <<UNIT
[Unit]
Description=Run devserver-guard every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/cache-trim.service <<UNIT
[Unit]
Description=Trim .next/dev and stale .turbo caches
[Service]
Type=oneshot
User=${USER_NAME}
IOSchedulingClass=idle
Nice=15
Environment=CACHE_TRIM_ROOTS=${WORKSPACE}
ExecStart=/usr/bin/python3 ${DEST}/cache-trim.py
UNIT

cat > /etc/systemd/system/cache-trim.timer <<UNIT
[Unit]
Description=Daily cache trim
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now devserver-guard.timer cache-trim.timer >/dev/null
echo "guards installed: devserver-guard.timer (60s), cache-trim.timer (daily 04:30)"
echo "  logs: /home/${USER_NAME}/.paseo/{devserver-guard,cache-trim}.log"
