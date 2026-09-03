# devstack — common operations. Run `make` for the list.
SHELL := /bin/bash
DC    := docker compose
.DEFAULT_GOAL := help

.PHONY: help up down restart build rebuild logs ps shell root doctor \
        auth-claude auth-codex auth-kimi auth-cursor auth-all \
        code-tunnel code-tunnel-bg code-tunnel-url \
        tunnel quick-tunnel tunnel-url router memory-push memory-pull \
        browser-test clean nuke

help: ## Show this help
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
	@echo "  next: make auth-all"

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

router: ## Open the 9router dashboard URL
	@echo "http://127.0.0.1:$${NINEROUTER_PORT:-20128}/dashboard"

# ── Auto-memory ─────────────────────────────────────────────────────────────
memory-push: ## Copy ./memory/*.md into the container's live memory store
	@./scripts/sync-memory.sh push
memory-pull: ## Copy the container's memory store back into ./memory
	@./scripts/sync-memory.sh pull

# ── Checks ──────────────────────────────────────────────────────────────────
doctor: ## Verify every tool inside the container
	@./scripts/doctor.sh

browser-test: ## Smoke-test headless agent-browser
	$(DC) exec --user paseo paseo bash -lc \
	  'agent-browser goto https://example.com && agent-browser snapshot | head -20'

clean: ## Remove containers and images, KEEP volumes (credentials survive)
	$(DC) down --rmi local

nuke: ## Remove EVERYTHING including volumes — deletes all agent credentials
	@printf 'This deletes all agent logins and Paseo state. Type YES: ' && read a && [ "$$a" = YES ]
	$(DC) down -v --rmi local
