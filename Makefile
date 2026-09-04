# devstack — common operations. Run `make` for the list.
SHELL := /bin/bash
DC    := docker compose
.DEFAULT_GOAL := help

.PHONY: tui help up down restart build rebuild logs ps shell root doctor \
        auth-claude auth-codex auth-kimi auth-cursor auth-all \
        code-tunnel code-tunnel-bg code-tunnel-url \
        tunnel quick-tunnel tunnel-url router memory-push memory-pull \
        guards guards-status guards-dry mem autotune autotune-write \
        agents add-agent router-status router-key router-on router-off \
        version update update-apply pair satellites satellites-down \
        browser-open browser-stream browser-view browser-test clean nuke

tui: ## Interactive control panel (start here)
	@python3 scripts/tui.py

help: ## Show this help
	@echo
	@printf "  \033[1;36mmake tui\033[0m   ← interactive control panel for everything below\n"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

.env:
	@cp .env.example .env
	@echo "created .env from example — EDIT IT (set PASEO_PASSWORD) then re-run"
	@exit 1

up: .env ## Build if needed and start the stack
	$(DC) up -d --build
	@$(MAKE) --no-print-directory ps
	@echo
	@echo "  Paseo   → http://127.0.0.1:$${PASEO_PORT:-6767}"
	@echo "  9router → http://127.0.0.1:$${NINEROUTER_PORT:-20128}  (dashboard pw: see .env)"
	@printf "  next: \033[1;36mmake tui\033[0m  (or: make auth-all)\n"

down: ## Stop the stack (volumes and credentials are kept)
	$(DC) down

restart: ## Restart services
	$(DC) restart

build: .env ## Build the agent image
	$(DC) build

rebuild: .env ## Rebuild the agent image from scratch (no cache)
	$(DC) build --no-cache

logs: ## Tail all logs (make logs S=paseo for one service)
	$(DC) logs -f --tail=100 $(S)

ps: ## Show container status
	@$(DC) ps

shell: ## Interactive shell in the agent container as `paseo`
	$(DC) exec --user paseo paseo bash -l

root: ## Root shell in the agent container (for apt installs)
	$(DC) exec --user root paseo bash -l

# ── Agent authentication ────────────────────────────────────────────────────
# Each opens an interactive login. Credentials land on the /home/paseo volume
# and survive restarts, rebuilds, and image updates.
auth-claude: ## Log in to Claude Code
	$(DC) exec -it --user paseo paseo claude
auth-codex: ## Log in to Codex
	$(DC) exec -it --user paseo paseo codex login
auth-kimi: ## Log in to Kimi Code
	$(DC) exec -it --user paseo paseo kimi
auth-cursor: ## Log in to Cursor Agent
	$(DC) exec -it --user paseo paseo cursor-agent login
auth-all: ## Log in to every agent CLI, one after another
	@for t in claude codex kimi cursor; do \
	  echo "── $$t ──"; $(MAKE) --no-print-directory auth-$$t || true; done

# ── Tunnels ─────────────────────────────────────────────────────────────────
tunnel: ## Start the named Cloudflare tunnel (needs TUNNEL_TOKEN in .env)
	@grep -qE '^TUNNEL_TOKEN=.+' .env || { echo "TUNNEL_TOKEN is not set in .env — use 'make quick-tunnel' for a throwaway URL"; exit 1; }
	$(DC) --profile tunnel up -d cloudflared
	@echo "remember: add the public hostname to PASEO_HOSTNAMES in .env, then: make restart"

quick-tunnel: ## Start a throwaway trycloudflare.com tunnel (no account, NO AUTH)
	@$(DC) --profile quick-tunnel up -d cloudflared-quick
	@printf 'waiting for the tunnel URL'
	@for i in $$(seq 1 20); do \
	   url=$$($(DC) logs cloudflared-quick 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1); \
	   [ -n "$$url" ] && break; printf '.'; sleep 2; done; echo; \
	 if [ -z "$$url" ]; then echo "no URL yet — make logs S=cloudflared-quick"; exit 1; fi; \
	 host=$${url#https://}; \
	 if grep -q "^PASEO_HOSTNAMES=.*$$host" .env; then \
	   echo "hostname already allowed"; \
	 else \
	   cur=$$(grep '^PASEO_HOSTNAMES=' .env | cut -d= -f2-); \
	   new=$$( [ -n "$$cur" ] && echo "$$cur,$$host" || echo "$$host" ); \
	   tmp=$$(mktemp); sed "s|^PASEO_HOSTNAMES=.*|PASEO_HOSTNAMES=$$new|" .env > $$tmp && mv $$tmp .env; \
	   echo "added $$host to PASEO_HOSTNAMES (Paseo rejects unknown Host headers)"; \
	   $(DC) up -d paseo >/dev/null 2>&1; sleep 6; \
	 fi; \
	 echo; echo "  $$url"; echo

tunnel-url: ## Print the quick-tunnel public URL
	@$(DC) logs cloudflared-quick 2>/dev/null \
	  | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 \
	  || echo "no URL yet — try: make logs S=cloudflared-quick"

# ── VS Code dev tunnel ──────────────────────────────────────────────────────
code-tunnel: ## Start a VS Code dev tunnel (prints a vscode.dev URL to open)
	@echo "Follow the device-login prompt; the tunnel then survives restarts."
	$(DC) exec -it --user paseo paseo code tunnel --accept-server-license-terms --name devstack

code-tunnel-bg: ## Run the VS Code dev tunnel in the background
	$(DC) exec -d --user paseo paseo bash -lc \
	  'code tunnel --accept-server-license-terms --name devstack >> /home/paseo/.vscode-tunnel.log 2>&1'
	@echo "started; URL: make code-tunnel-url"

code-tunnel-url: ## Print the vscode.dev URL for the running tunnel
	@$(DC) exec -T --user paseo paseo bash -lc \
	  'grep -oE "https://vscode.dev/tunnel/[^ ]+" /home/paseo/.vscode-tunnel.log 2>/dev/null | tail -1' \
	  || echo "not started yet — make code-tunnel-bg"

# ── Agents & routing ────────────────────────────────────────────────────────
agents: ## List agent CLIs installed in the container
	@./scripts/add-agent.sh --list

add-agent: ## Install another agent CLI (make add-agent M=npm P=opencode-ai [PERSIST=1])
	@test -n "$(M)" -a -n "$(P)" || { echo "usage: make add-agent M=npm|curl P=<package-or-url> [PERSIST=1]"; exit 1; }
	@./scripts/add-agent.sh $(M) "$(P)" $(if $(PERSIST),--persist,)

router-status: ## Show which CLIs are routed through 9router
	@./scripts/router-connect.sh status

router-key: ## Mint a 9router API key and save it to .env
	@./scripts/router-connect.sh key

router-on: ## Route claude + codex through 9router
	@./scripts/router-connect.sh on

router-off: ## Unroute; each CLI uses its own login
	@./scripts/router-connect.sh off

# ── Memory sizing ───────────────────────────────────────────────────────────
autotune: ## Show RAM-based sizing for this host
	@./scripts/autotune-memory.sh

autotune-write: ## Apply RAM-based sizing to .env
	@./scripts/autotune-memory.sh --write

# ── Pairing & satellites ────────────────────────────────────────────────────
pair: ## Print the Paseo pairing link (relay — no public port needed)
	@./scripts/pair.sh

satellites: ## Start extra Paseo daemons sharing the same 9router pool
	$(DC) --profile satellites up -d
	@echo
	@echo "  paseo-2 -> http://127.0.0.1:$${PASEO_PORT_2:-6768}"
	@echo "  paseo-3 -> http://127.0.0.1:$${PASEO_PORT_3:-6769}"
	@echo "  each has its own state + workspace; all share http://9router:20128"

satellites-down: ## Stop the satellite daemons (their volumes are kept)
	$(DC) --profile satellites stop paseo-2 paseo-3

router: ## Open the 9router dashboard URL
	@echo "http://127.0.0.1:$${NINEROUTER_PORT:-20128}/dashboard"

# ── Auto-memory ─────────────────────────────────────────────────────────────
memory-push: ## Copy ./memory/*.md into the container's live memory store
	@./scripts/sync-memory.sh push
memory-pull: ## Copy the container's memory store back into ./memory
	@./scripts/sync-memory.sh pull

# ── Memory / disk guards ────────────────────────────────────────────────────
guards: ## Install the host memory+disk guards (systemd timers)
	sudo DEVSTACK_USER=$${DEVSTACK_USER:-paseo} WORKSPACE_ROOT=$$(pwd)/workspace \
	  bash scripts/guard/install-guards.sh

guards-status: ## Show guard timers and recent activity
	@systemctl list-timers --all 2>/dev/null | grep -E 'devserver-guard|cache-trim' || echo "guards not installed (make guards)"
	@echo; echo "── recent reaps ──"
	@tail -15 ~/.paseo/devserver-guard.log 2>/dev/null || echo "(no log yet — nothing has needed reaping)"

guards-dry: ## Show what the guards WOULD do right now, without doing it
	@echo "── devserver-guard ──"
	@DEVSERVER_GUARD_DRY_RUN=1 DEVSERVER_GUARD_STDOUT=1 python3 scripts/guard/devserver-guard.py || true
	@echo "── cache-trim ──"
	@CACHE_TRIM_DRY_RUN=1 CACHE_TRIM_STDOUT=1 CACHE_TRIM_ROOTS=$$(pwd)/workspace \
	  python3 scripts/guard/cache-trim.py || true

mem: ## Show memory pressure: host, container, and any dev servers
	@echo "── host ──"; free -h 2>/dev/null | head -2 || vm_stat | head -5
	@echo; echo "── containers ──"; docker stats --no-stream \
	  --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || true
	@echo; echo "── dev servers ──"
	@ps -eo pid=,etimes=,rss=,args= 2>/dev/null | grep -E 'next-server \(v' | grep -v grep \
	  | awk '{printf "  pid %s  %.1fGB  %.1fh  %s\n", $$1, $$3/1048576, $$2/3600, $$4}' \
	  || echo "  none running"

# ── Updates ─────────────────────────────────────────────────────────────────
version: ## Show the installed version
	@printf "  repo:      %s\n" "$$(cat VERSION 2>/dev/null || git describe --tags --always 2>/dev/null || echo unknown)"
	@printf "  image:     %s\n" "$$($(DC) exec -T --user paseo paseo printenv PDS_VERSION 2>/dev/null || echo 'not running')"

update: ## Check for a newer release (dry run)
	@./scripts/update.sh

update-apply: ## Pull, merge .env, rebuild, restart (volumes kept)
	@./scripts/update.sh --apply

# ── Checks ──────────────────────────────────────────────────────────────────
doctor: ## Verify every tool inside the container
	@./scripts/doctor.sh

# ── Remote browser viewing ──────────────────────────────────────────────────
browser-open: ## Open a URL in the headless browser (make browser-open U=https://...)
	@test -n "$(U)" || { echo "usage: make browser-open U=https://example.com"; exit 1; }
	$(DC) exec -T --user paseo paseo bash -lc 'agent-browser open "$(U)"'
	@$(MAKE) --no-print-directory browser-stream

browser-stream: ## Show the agent-browser live stream port and how to reach it
	@port=$$(grep -E '^AGENT_BROWSER_STREAM_PORT=' .env 2>/dev/null | cut -d= -f2); 	 port=$${port:-9223}; 	 $(DC) exec -T --user paseo paseo bash -lc 'agent-browser stream status' 2>/dev/null || true; 	 echo; echo "  stream: ws://127.0.0.1:$$port  (bound to localhost on the host)"; 	 echo "  from another machine, tunnel it first:"; 	 echo "    ssh -N -L $$port:127.0.0.1:$$port $${DEVSTACK_USER:-paseo}@<this-host>"; 	 echo "  then open viewer/browser-view.html (or: make browser-view)"

browser-view: ## Open the live browser viewer in your local web browser
	@port=$$(grep -E '^AGENT_BROWSER_STREAM_PORT=' .env 2>/dev/null | cut -d= -f2); 	 port=$${port:-9223}; 	 url="file://$$(pwd)/viewer/browser-view.html?ws=ws://127.0.0.1:$$port"; 	 (open "$$url" 2>/dev/null || xdg-open "$$url" 2>/dev/null || echo "open: $$url")

browser-test: ## Smoke-test headless agent-browser
	$(DC) exec --user paseo paseo bash -lc \
	  'agent-browser goto https://example.com && agent-browser snapshot | head -20'

clean: ## Remove containers and images, KEEP volumes (credentials survive)
	$(DC) down --rmi local

nuke: ## Remove EVERYTHING including volumes — deletes all agent credentials
	@printf 'This deletes all agent logins and Paseo state. Type YES: ' && read a && [ "$$a" = YES ]
	$(DC) down -v --rmi local
