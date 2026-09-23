#!/usr/bin/env python3
"""Regression test: devserver-guard must never reap a containerised service.

A router running in its own container (9router, OmniRoute) is a Next app, so
its `next-server (vX)` looked exactly like a workspace dev server. Its parent
chain on the host ends in containerd-shim, the name-based protection never
fired, and the 2h age rule restarted it every 2h (79 restarts on one host).

    python3 tests/test-devserver-guard.py
"""

import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True   # the guard's __pycache__ is tracked; leave it be
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "devserver_guard", os.path.join(HERE, "..", "scripts", "guard", "devserver-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

DAEMON = "a" * 64      # a Paseo daemon container
ROUTER = "b" * 64      # a router's own container
SERVER = "next-server (v15.5.4)"


def proc(pid, ppid, cmd, age_h=0.1):
    return {"pid": pid, "ppid": ppid, "cmd": cmd, "age_h": age_h}


class ContainerOf(unittest.TestCase):
    def test_cgroup_layouts(self):
        cases = {
            f"0::/system.slice/docker-{ROUTER}.scope\n": ROUTER,          # v2, systemd driver
            f"0::/docker/{ROUTER}\n": ROUTER,                             # v2, cgroupfs driver
            f"12:memory:/docker/{ROUTER}\n11:pids:/docker/{ROUTER}\n": ROUTER,  # v1
            f"0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
            f"docker-{ROUTER}.scope\n": ROUTER,                           # rootless
            "0::/user.slice/user-1000.slice/session-4.scope\n": "",      # host shell
            "0::/system.slice/ssh.service\n": "",                         # host service
            "0::/\n": "",                                                 # inside a container
        }
        for text, want in cases.items():
            self.assertEqual(guard.container_of(text), want, text)


class ReapableServers(unittest.TestCase):
    def setUp(self):
        # Parent chains mirror a real host: both containers hang off a shim.
        self.procs = [
            proc(10, 1, "/usr/bin/containerd-shim-runc-v2 -namespace moby -id " + ROUTER),
            proc(11, 10, "node /app/server.js"),
            proc(12, 11, SERVER, age_h=79.0),                   # the router's Next app
            proc(20, 1, "/usr/bin/containerd-shim-runc-v2 -namespace moby -id " + DAEMON),
            proc(21, 20, "node /usr/local/lib/node_modules/@getpaseo/server/dist/"
                         "scripts/supervisor-entrypoint.js"),
            proc(22, 20, "node /opt/next/dist/bin/next dev"),  # reparented to the shim
            proc(23, 22, SERVER, age_h=3.0),                    # an agent's dev server
            proc(30, 1, "pnpm run dev"),
            proc(31, 30, SERVER, age_h=5.0),                    # a dev server on the host
            proc(40, 1, SERVER),                                # cgroup unreadable
        ]
        self.cids = {10: ROUTER, 11: ROUTER, 12: ROUTER,
                     20: DAEMON, 21: DAEMON, 22: DAEMON, 23: DAEMON,
                     30: "", 31: "", 40: None}

    def pids(self):
        return sorted(p["pid"] for p in guard.reapable_servers(self.procs, self.cids.get))

    def test_router_container_is_left_alone(self):
        self.assertNotIn(12, self.pids())

    def test_daemon_and_host_dev_servers_are_still_reaped(self):
        self.assertEqual(self.pids(), [23, 31])

    def test_unknown_cgroup_is_never_touched(self):
        self.assertNotIn(40, self.pids())

    def test_container_without_a_daemon_is_foreign_even_if_it_is_paseo_shaped(self):
        # The daemon container stops (no @getpaseo/server): its leftovers are
        # no longer provably an agent's, so they are skipped rather than guessed.
        procs = [p for p in self.procs if p["pid"] != 21]
        got = sorted(p["pid"] for p in guard.reapable_servers(procs, self.cids.get))
        self.assertEqual(got, [31])

    def test_name_protection_still_applies_on_the_host(self):
        procs = self.procs + [proc(50, 1, "node /usr/local/bin/9router"),
                              proc(51, 50, SERVER, age_h=9.0)]
        cids = {**self.cids, 50: "", 51: ""}
        got = sorted(p["pid"] for p in guard.reapable_servers(procs, cids.get))
        self.assertNotIn(51, got)


if __name__ == "__main__":
    unittest.main(verbosity=2)
