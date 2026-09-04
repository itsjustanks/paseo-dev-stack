#!/usr/bin/env python3
"""
agent-browser stream bridge.

agent-browser binds its live-view WebSocket to LOCALHOST ONLY, by design:

    "If --port is omitted, agent-browser binds an available localhost port
     automatically and reports it back."

There is no bind-address option. Inside a container that means Docker cannot
publish the port at all — the socket is on the container's 127.0.0.1, so a
`-p 9223:9223` mapping connects to nothing and the client gets ECONNRESET.
(Verified: a WebSocket handshake from inside the container returns real
1280x720 JPEG frames; the same handshake from the host is reset.)

This bridge listens on 0.0.0.0 inside the container and forwards raw bytes to
the agent-browser stream on 127.0.0.1. It is protocol-agnostic — it never parses
WebSocket frames, so it passes both the upgrade handshake and the binary frames
through untouched, in both directions (the stream also accepts input events, so
the client->server direction must work for pair browsing).

Only the container's own loopback is exposed this way; the published port on the
HOST is still bound to 127.0.0.1 by docker-compose, so nothing reaches the
public internet without an SSH tunnel or the Cloudflare tunnel.
"""

import os
import selectors
import socket
import sys
import threading

# The bridge MUST listen on a different port from the one agent-browser uses.
# On Linux, binding 0.0.0.0:P conflicts with an existing 127.0.0.1:P listener
# (SO_REUSEADDR does not help — that is SO_REUSEPORT, and agent-browser does not
# set it), so reusing the same number gives EADDRINUSE. Docker maps the host's
# published port to the bridge port, so the number difference is invisible.
LISTEN_HOST = os.environ.get("STREAM_BRIDGE_LISTEN", "0.0.0.0")
TARGET_HOST = "127.0.0.1"
TARGET_PORT = int(os.environ.get("AGENT_BROWSER_STREAM_PORT", "9223"))
LISTEN_PORT = int(os.environ.get("AGENT_BROWSER_STREAM_BRIDGE_PORT",
                                 str(TARGET_PORT + 1)))


def pump(src, dst):
    """Copy bytes one way until either side closes."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        # Half-close so the peer sees EOF instead of hanging.
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        upstream = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10)
    except OSError:
        # No session open yet is the normal case, not an error worth crashing on.
        try:
            client.close()
        except OSError:
            pass
        return
    upstream.settimeout(None)
    client.settimeout(None)
    t = threading.Thread(target=pump, args=(client, upstream), daemon=True)
    t.start()
    pump(upstream, client)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((LISTEN_HOST, LISTEN_PORT))
    except OSError as e:
        print(f"stream-bridge: cannot bind {LISTEN_HOST}:{LISTEN_PORT}: {e}",
              file=sys.stderr, flush=True)
        return 1
    srv.listen(16)
    print(f"stream-bridge: {LISTEN_HOST}:{LISTEN_PORT} -> "
          f"{TARGET_HOST}:{TARGET_PORT}", flush=True)
    while True:
        try:
            client, _addr = srv.accept()
        except OSError:
            continue
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
