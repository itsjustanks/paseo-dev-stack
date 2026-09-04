#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# devstack — one-command install. Works as a DigitalOcean / Hetzner / any-cloud
# user-data (cloud-init) script, in an elest.io-style CI/CD pipeline, or by hand
# on a fresh box.
#
#   REMOTE (cloud-init user-data — paste into "User data" at droplet creation):
#     #!/bin/bash
#     curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | bash
#
#   REMOTE (existing server):
#     curl -fsSL https://raw.githubusercontent.com/itsjustanks/paseo-dev-stack/main/install.sh | sudo bash
#
#   LOCAL (from a clone, incl. macOS with Docker Desktop/Colima/OrbStack):
#     ./install.sh
#
# Env knobs (all optional):
#   DEVSTACK_REPO      git URL to clone            (default: this repo)
#   DEVSTACK_REF       branch/tag                  (default: main)
#   DEVSTACK_USER      service user on Linux       (default: paseo)
#   DEVSTACK_DIR       install path                (default: ~USER/devstack)
#   PASEO_PASSWORD     UI password                 (default: generated)
#   TUNNEL_TOKEN       Cloudflare named tunnel     (default: none)
#   PASEO_HOSTNAMES    public hostname(s)          (default: none)
#   DEVSTACK_NO_START  set to 1 to install but not start
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEVSTACK_REPO="${DEVSTACK_REPO:-https://github.com/itsjustanks/paseo-dev-stack}"
DEVSTACK_REF="${DEVSTACK_REF:-main}"
DEVSTACK_USER="${DEVSTACK_USER:-paseo}"

log()  { printf '\033[1;36m[devstack]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# `tr < /dev/urandom | head -c 24` makes head exit first, so tr dies of SIGPIPE
# (141). With `set -o pipefail` that is a FATAL pipeline failure, and the script
# aborts here — silently skipping the credentials file. It is nondeterministic:
# tr sometimes finishes writing its buffer before head closes the pipe, which is
# why this survived earlier runs. Read a fixed block instead: no pipe, no race.
gen_pw() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 4096 /dev/urandom) | cut -c1-24
}

OS="$(uname -s)"

# ─── macOS: local dev, no user/firewall/swap management ─────────────────────
if [ "$OS" = "Darwin" ]; then
  log "macOS detected — local install (no privileged setup)"
  command -v docker >/dev/null || die "Docker not found. Install Docker Desktop, OrbStack, or Colima first."
  docker compose version >/dev/null 2>&1 || die "'docker compose' not available. Docker Desktop and OrbStack ship it; with Colima run: brew install docker-compose"
  docker info >/dev/null 2>&1 || die "Docker is installed but not running."

  # If we are already inside a clone, use it; otherwise clone next to cwd.
  if [ -f "./docker-compose.yml" ] && [ -d "./docker/paseo" ]; then
    TARGET="$(pwd)"; log "using this clone: $TARGET"
  else
    TARGET="${DEVSTACK_DIR:-$PWD/paseo-dev-stack}"
    if [ -d "$TARGET/.git" ]; then
      log "updating $TARGET"; git -C "$TARGET" pull --ff-only || warn "pull failed; using existing checkout"
    else
      log "cloning into $TARGET"; git clone -q -b "$DEVSTACK_REF" "$DEVSTACK_REPO" "$TARGET"
    fi
  fi
  cd "$TARGET"

  if [ ! -f .env ]; then
    cp .env.example .env
    pw="${PASEO_PASSWORD:-$(gen_pw)}"
    # macOS sed needs the -i '' form; GNU sed does not. Use a portable rewrite.
    tmp="$(mktemp)"; sed "s|^PASEO_PASSWORD=.*|PASEO_PASSWORD=${pw}|" .env > "$tmp" && mv "$tmp" .env
    log "generated PASEO_PASSWORD=${pw}"
  fi
  mkdir -p workspace

  if [ "${DEVSTACK_NO_START:-0}" = "1" ]; then log "install only (DEVSTACK_NO_START=1)"; exit 0; fi
  log "building and starting (first build takes a few minutes)"
  docker compose up -d --build
  echo
  log "Paseo:   http://127.0.0.1:$(grep -E '^PASEO_PORT=' .env | cut -d= -f2 || echo 6767)"
  log "9router: http://127.0.0.1:$(grep -E '^NINEROUTER_PORT=' .env | cut -d= -f2 || echo 20128)"
  log "next: make auth-all && make doctor"
  exit 0
fi

# ─── Linux ──────────────────────────────────────────────────────────────────
[ "$OS" = "Linux" ] || die "unsupported OS: $OS"
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "run as root, or install sudo"
  log "re-executing with sudo"
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
command -v apt-get >/dev/null || die "this installer supports Debian/Ubuntu (apt) hosts"

# cloud-init can race us for the apt lock on a fresh boot. Wait it out.
for i in $(seq 1 60); do
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    if [ "$i" = 1 ]; then log "waiting for another apt process (cloud-init) to finish"; fi
    sleep 5
  else break; fi
done

log "installing git"
apt-get update -qq
apt-get install -y -qq --no-install-recommends git ca-certificates curl >/dev/null

DEVSTACK_DIR="${DEVSTACK_DIR:-/home/${DEVSTACK_USER}/paseo-dev-stack}"
STAGE=/opt/paseo-dev-stack-src
if [ -f "$(dirname "$0")/docker-compose.yml" ]; then
  STAGE="$(cd "$(dirname "$0")" && pwd)"; log "installing from local checkout: $STAGE"
else
  log "fetching $DEVSTACK_REPO@$DEVSTACK_REF"
  rm -rf "$STAGE"
  git clone -q --depth 1 -b "$DEVSTACK_REF" "$DEVSTACK_REPO" "$STAGE" \
    || die "clone failed — is $DEVSTACK_REPO reachable and public?"
fi

log "running bootstrap (user, docker, swap, firewall)"
DEVSTACK_USER="$DEVSTACK_USER" bash "$STAGE/scripts/bootstrap-server.sh"

# Place the repo in the service user's home.
if [ "$STAGE" != "$DEVSTACK_DIR" ]; then
  mkdir -p "$(dirname "$DEVSTACK_DIR")"
  rm -rf "$DEVSTACK_DIR"
  cp -r "$STAGE" "$DEVSTACK_DIR"
fi
chown -R "$DEVSTACK_USER:$DEVSTACK_USER" "$DEVSTACK_DIR"
sudo -u "$DEVSTACK_USER" mkdir -p "$DEVSTACK_DIR/workspace"

# ─── .env ───────────────────────────────────────────────────────────────────
cd "$DEVSTACK_DIR"
if [ ! -f .env ]; then
  sudo -u "$DEVSTACK_USER" cp .env.example .env
  pw="${PASEO_PASSWORD:-$(gen_pw)}"
  rpw="$(gen_pw)"
  sudo -u "$DEVSTACK_USER" sed -i \
    -e "s|^PASEO_PASSWORD=.*|PASEO_PASSWORD=${pw}|" \
    -e "s|^NINEROUTER_PASSWORD=.*|NINEROUTER_PASSWORD=${rpw}|" .env
  # NOTE: `[ -n "$x" ] && cmd` evaluates to FALSE when x is empty, and under
  # `set -e` that aborts the script — silently skipping the credentials file
  # written just below. Use if/fi, never the && form, for optional steps.
  if [ -n "${PASEO_HOSTNAMES:-}" ]; then
    sudo -u "$DEVSTACK_USER" sed -i "s|^PASEO_HOSTNAMES=.*|PASEO_HOSTNAMES=${PASEO_HOSTNAMES}|" .env
  fi
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    sudo -u "$DEVSTACK_USER" sed -i "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=${TUNNEL_TOKEN}|" .env
  fi
  # Credentials are also written where a human can find them after a headless
  # cloud-init run, since the console output is long gone by then.
  printf 'PASEO_PASSWORD=%s\nNINEROUTER_PASSWORD=%s\n' "$pw" "$rpw" > /root/paseo-dev-stack-credentials.txt
  chmod 600 /root/paseo-dev-stack-credentials.txt
  log "credentials written to /root/paseo-dev-stack-credentials.txt"

  # Size the container to this host: give it almost everything, keeping a
  # reserve so an OOM cannot take the box down with it.
  if [ -x scripts/autotune-memory.sh ]; then
    sudo -u "$DEVSTACK_USER" ./scripts/autotune-memory.sh --write 2>&1 | sed 's/^/    /' || warn "autotune failed"
  fi
fi

# ─── pds launcher on PATH ───────────────────────────────────────────────────
# So `pds` works when you ssh in as root: it locates the deployment and
# re-executes as the owning user, which stops root from creating root-owned
# files inside the repo (the daemon then cannot read its own state).
if [ -f "$DEVSTACK_DIR/scripts/pds" ]; then
  install -m 0755 "$DEVSTACK_DIR/scripts/pds" /usr/local/bin/pds
  log "installed /usr/local/bin/pds  (run: pds)"
fi

# ─── systemd unit: survive reboots ──────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/paseo-dev-stack.service <<UNIT
[Unit]
Description=paseo-dev-stack (Paseo + 9router)
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${DEVSTACK_USER}
WorkingDirectory=${DEVSTACK_DIR}
ExecStart=/usr/bin/docker compose up -d --build
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable paseo-dev-stack.service >/dev/null 2>&1 || true
  log "systemd unit installed (paseo-dev-stack.service)"
fi

if [ "${DEVSTACK_NO_START:-0}" = "1" ]; then
  log "install only (DEVSTACK_NO_START=1). Start with: systemctl start paseo-dev-stack"
  exit 0
fi

log "building and starting — first build takes several minutes"
sudo -u "$DEVSTACK_USER" -H docker compose up -d --build

echo
cat <<BANNER
  ✅ paseo-dev-stack is up

     Paseo   : http://127.0.0.1:$(grep -E '^PASEO_PORT=' .env | cut -d= -f2 || echo 6767)   (bound to localhost by design)
     9router : http://127.0.0.1:$(grep -E '^NINEROUTER_PORT=' .env | cut -d= -f2 || echo 20128)
     creds   : /root/paseo-dev-stack-credentials.txt

  Reach it from your laptop (no public port is open):
     ssh -N -L 6767:127.0.0.1:6767 ${DEVSTACK_USER}@<this-host>

  Or expose it properly:
     cd ${DEVSTACK_DIR}
     make quick-tunnel          # throwaway URL, no account, NO AUTH
     make tunnel                # named Cloudflare tunnel (set TUNNEL_TOKEN first)
     make code-tunnel           # VS Code dev tunnel -> vscode.dev

  Then:
     make auth-all              # log in to each agent CLI
     make doctor                # verify everything
BANNER
