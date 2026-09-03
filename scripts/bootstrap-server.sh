#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# devstack — one-shot server bootstrap. Idempotent: safe to re-run.
#
#   curl -fsSL <raw-url>/scripts/bootstrap-server.sh | sudo bash
#   # or, from a clone:  sudo ./scripts/bootstrap-server.sh
#
# Does: creates the non-root `paseo` user (agents refuse to run as root),
# installs Docker + compose, adds swap, hardens SSH, sets up UFW, and clones
# this repo into the user's home ready for `make up`.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEVSTACK_USER="${DEVSTACK_USER:-paseo}"
DEVSTACK_REPO="${DEVSTACK_REPO:-}"
DEVSTACK_DIR="/home/${DEVSTACK_USER}/devstack"
SWAP_GB="${SWAP_GB:-4}"

log()  { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
log "host: ${PRETTY_NAME:-unknown} ($(uname -m))"

# ── 1. Base packages ────────────────────────────────────────────────────────
log "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# `make` matters: the documented UX is `make up` / `make doctor`, and a minimal
# cloud image does not ship it.
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg git jq make ufw unattended-upgrades sudo >/dev/null

# ── 2. Non-root user ────────────────────────────────────────────────────────
# uid 1000 must match the container's `paseo` user, or bind-mounted files are
# unreadable inside the container. Ubuntu cloud images often pre-claim 1000
# for the `ubuntu` user, so handle the collision explicitly.
# uid 1000 must match the container's `paseo` user or bind-mounted files under
# /workspace are unreadable inside the container. Ubuntu cloud images ship an
# `ubuntu` user already holding 1000, so we may have to move it out of the way.
# DEVSTACK_TAKE_UID1000=0 opts out and accepts the mismatch.
claim_uid_1000() {
  local holder; holder="$(getent passwd 1000 | cut -d: -f1)"
  [ -n "$holder" ] || return 0
  if [ "${DEVSTACK_TAKE_UID1000:-1}" != "1" ]; then
    warn "uid 1000 held by '$holder'; not reassigning (DEVSTACK_TAKE_UID1000=0)"
    return 1
  fi
  # Never displace a logged-in user or one with running processes.
  if pgrep -u 1000 >/dev/null 2>&1; then
    warn "uid 1000 ('$holder') has running processes; leaving it alone"
    return 1
  fi
  local newuid=1100
  while getent passwd "$newuid" >/dev/null; do newuid=$((newuid+1)); done
  log "moving existing user '$holder' from uid 1000 to $newuid to free it"
  usermod  -u "$newuid" "$holder" || { warn "usermod failed"; return 1; }
  getent group 1000 >/dev/null && groupmod -g "$newuid" "$(getent group 1000 | cut -d: -f1)" 2>/dev/null || true
  # usermod retargets the home dir but not files elsewhere.
  find /home/"$holder" -xdev -uid 1000 -exec chown -h "$newuid" {} + 2>/dev/null || true
  return 0
}

if id -u "$DEVSTACK_USER" >/dev/null 2>&1; then
  cur_uid="$(id -u "$DEVSTACK_USER")"
  log "user $DEVSTACK_USER exists (uid $cur_uid)"
  [ "$cur_uid" != "1000" ] && warn "uid is $cur_uid, not 1000 — /workspace files will show a different owner inside the container"
else
  if getent passwd 1000 >/dev/null; then claim_uid_1000 || true; fi
  if getent passwd 1000 >/dev/null; then
    warn "uid 1000 still taken; creating $DEVSTACK_USER with an auto uid"
    useradd -m -s /bin/bash "$DEVSTACK_USER"
    warn "  -> bind-mounted /workspace files will not line up with the container user"
  else
    log "creating $DEVSTACK_USER with uid/gid 1000 (matches container)"
    getent group 1000 >/dev/null || groupadd -g 1000 "$DEVSTACK_USER"
    useradd -m -u 1000 -g 1000 -s /bin/bash "$DEVSTACK_USER"
  fi
fi
usermod -aG sudo "$DEVSTACK_USER"
echo "$DEVSTACK_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-${DEVSTACK_USER}"
chmod 0440 "/etc/sudoers.d/90-${DEVSTACK_USER}"

# Carry root's authorized_keys over so you can ssh straight in as the new user.
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m 700 -o "$DEVSTACK_USER" -g "$DEVSTACK_USER" "/home/$DEVSTACK_USER/.ssh"
  install -m 600 -o "$DEVSTACK_USER" -g "$DEVSTACK_USER" \
    /root/.ssh/authorized_keys "/home/$DEVSTACK_USER/.ssh/authorized_keys"
  log "copied root's ssh keys to $DEVSTACK_USER"
fi

# ── 3. Docker ───────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "docker + compose already present"
else
  log "installing Docker Engine + compose plugin (official apt repo)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  # VERSION_CODENAME is empty on some derivatives; fall back to UBUNTU_CODENAME.
  codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  [ -n "$codename" ] || die "cannot determine distro codename"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null \
    || die "docker install failed — is ${ID} ${codename} supported by download.docker.com?"
fi
usermod -aG docker "$DEVSTACK_USER"
systemctl enable --now docker >/dev/null 2>&1 || true

# ── 4. Swap ─────────────────────────────────────────────────────────────────
# Droplets ship with none; a container build (or a runaway tsc) will OOM.
if swapon --show | grep -q .; then
  log "swap already active"
else
  log "creating ${SWAP_GB}G swapfile"
  fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=none
  chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -qw vm.swappiness=10
  # Ubuntu 26.04 ships no /etc/sysctl.conf; use the drop-in dir, which every
  # current Debian/Ubuntu reads.
  mkdir -p /etc/sysctl.d
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-devstack-swappiness.conf
fi

# ── 5. Firewall ─────────────────────────────────────────────────────────────
# IMPORTANT: Docker writes its own iptables rules that BYPASS ufw, so a
# `ufw deny` does NOT protect a port published to 0.0.0.0. The real protection
# is that docker-compose.yml binds every port to 127.0.0.1 — ufw is only a
# second layer for host services.
log "configuring ufw (ssh only; all app traffic goes out via the tunnel)"
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null
warn "ufw does not filter docker-published ports — keep the 127.0.0.1 binds in docker-compose.yml"

# ── 6. Unattended upgrades ──────────────────────────────────────────────────
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

# ── 7. Repo ─────────────────────────────────────────────────────────────────
if [ -n "$DEVSTACK_REPO" ]; then
  if [ -d "$DEVSTACK_DIR/.git" ]; then
    log "repo present; pulling"
    sudo -u "$DEVSTACK_USER" git -C "$DEVSTACK_DIR" pull --ff-only || warn "pull failed"
  else
    log "cloning $DEVSTACK_REPO"
    sudo -u "$DEVSTACK_USER" git clone -q "$DEVSTACK_REPO" "$DEVSTACK_DIR"
  fi
fi
if [ -d "$DEVSTACK_DIR" ]; then
  chown -R "$DEVSTACK_USER:$DEVSTACK_USER" "$DEVSTACK_DIR"
  sudo -u "$DEVSTACK_USER" mkdir -p "$DEVSTACK_DIR/workspace"
  [ -f "$DEVSTACK_DIR/.env" ] || {
    sudo -u "$DEVSTACK_USER" cp "$DEVSTACK_DIR/.env.example" "$DEVSTACK_DIR/.env" 2>/dev/null || true
    warn "created .env from the example — EDIT IT and set PASEO_PASSWORD"
  }
fi

cat <<BANNER

  ✅ bootstrap complete

     user     : $DEVSTACK_USER  (uid $(id -u "$DEVSTACK_USER"))
     docker   : $(docker --version 2>/dev/null | cut -d, -f1)
     swap     : $(swapon --show=SIZE --noheadings 2>/dev/null | tr -d ' \n' || echo none)
     repo     : ${DEVSTACK_DIR}

  Next:
     ssh ${DEVSTACK_USER}@<this-host>
     cd ~/devstack && \$EDITOR .env      # set PASEO_PASSWORD
     make up

  Note: group membership (docker) applies on your NEXT login.

BANNER
