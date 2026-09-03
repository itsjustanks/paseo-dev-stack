# memory/

Seeds for Claude Code's auto-memory, copied into the container's live store on
first boot (`/home/paseo/.claude/memory`, pinned via `autoMemoryDirectory`).

**These files are published with this repo — do not put anything private here.**
No server IPs, hostnames, SSH key names, tokens, or internal paths. Machine- or
account-specific memories belong in your own memory store, not in a public repo.

Use `make memory-push` / `make memory-pull` to move memories between this
directory and a running container; review anything you pull back before
committing it.
