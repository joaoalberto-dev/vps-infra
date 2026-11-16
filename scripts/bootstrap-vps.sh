#!/usr/bin/env bash
# Prepares a fresh VPS: basic hardening + Dokku installation.
# Runs ON the VPS, as root. Idempotent: safe to run again.
#
# Normally run by the "Bootstrap VPS" workflow. Manually:
#   ssh root@VPS "DOKKU_DOMAIN=... LETSENCRYPT_EMAIL=... bash -s" < scripts/bootstrap-vps.sh
#
# Required env: DOKKU_DOMAIN, LETSENCRYPT_EMAIL
# Optional env: DOKKU_TAG (Dokku version), SWAP_SIZE (e.g. 2G; 0 disables)
set -euo pipefail

DOKKU_TAG="${DOKKU_TAG:-v0.38.34}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
: "${DOKKU_DOMAIN:?set DOKKU_DOMAIN (e.g. example.com)}"
: "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL}"

export DEBIAN_FRONTEND=noninteractive
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Must run as root."; exit 1; }

log "Updating packages"
apt-get update -y
apt-get upgrade -y
apt-get install -y ufw fail2ban unattended-upgrades curl wget ca-certificates

log "Automatic security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades

if [[ "$SWAP_SIZE" != "0" ]]; then
  log "Swap (${SWAP_SIZE}) — cushions memory spikes during deploys"
  if ! swapon --show | grep -q '/swapfile'; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  fi
fi

log "Firewall (UFW): SSH, HTTP and HTTPS only"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

log "Fail2ban (protects SSH against brute force)"
systemctl enable --now fail2ban

log "Installing Dokku ${DOKKU_TAG}"
if ! command -v dokku >/dev/null 2>&1; then
  wget -qNP /tmp "https://dokku.com/install/${DOKKU_TAG}/bootstrap.sh"
  DOKKU_TAG="$DOKKU_TAG" bash /tmp/bootstrap.sh
else
  echo "Dokku already installed: $(dokku version)"
fi

log "Global domain: ${DOKKU_DOMAIN}"
dokku domains:set-global "$DOKKU_DOMAIN"

log "Granting root's SSH keys access to the dokku user"
if [[ -s /root/.ssh/authorized_keys ]]; then
  i=0
  while read -r key; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    i=$((i + 1))
    body="$(awk '{print $2}' <<<"$key")"
    if ! grep -qF "$body" /home/dokku/.ssh/authorized_keys 2>/dev/null; then
      echo "$key" | dokku ssh-keys:add "admin-root-$i" || true
    fi
  done < /root/.ssh/authorized_keys
fi

log "Let's Encrypt plugin"
if ! dokku plugin:installed letsencrypt; then
  dokku plugin:install https://github.com/dokku/dokku-letsencrypt.git
fi
dokku letsencrypt:set --global email "$LETSENCRYPT_EMAIL"
dokku letsencrypt:cron-job --add

log "Hardening SSH"
if [[ -s /root/.ssh/authorized_keys ]]; then
  # The "00-" prefix makes this file load before e.g. 50-cloud-init.conf
  # (in sshd, the first definition of each option wins).
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t && systemctl reload ssh
  echo "Password login DISABLED (SSH keys only)."
else
  echo "⚠️  /root/.ssh/authorized_keys is empty — password login was NOT disabled."
  echo "    Add your SSH key to the server and run this script again."
fi

log "Done! Dokku $(dokku version | awk '{print $NF}') is installed."
