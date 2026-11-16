#!/usr/bin/env bash
# The ONLY step that runs on your machine. Run it once.
#   - generates the root SSH key (used by this repo's workflows to manage the VPS)
#   - generates the deploy key (used by your apps' repos to talk to Dokku)
#   - writes every secret and variable into this GitHub repo
#
# Requires: gh (authenticated), this repo already pushed to GitHub, and a filled-in .env.
# Usage: scripts/init-github.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Missing .env — run: cp .env.example .env"; exit 1; }
# shellcheck disable=SC1091
source .env
: "${VPS_HOST:?set VPS_HOST in .env}" "${DOKKU_DOMAIN:?set DOKKU_DOMAIN in .env}" "${LETSENCRYPT_EMAIL:?set LETSENCRYPT_EMAIL in .env}"
GHCR_USER="${GHCR_USER:-$(gh api user -q .login)}"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
KEYS="$HOME/.ssh/${REPO//\//-}"
mkdir -p "$KEYS" && chmod 700 "$KEYS"

for k in root deploy; do
  [[ -f "$KEYS/$k" ]] || ssh-keygen -q -t ed25519 -N "" -C "gh-actions-$k@$REPO" -f "$KEYS/$k"
done

echo "==> Reading the VPS host key"
KNOWN_HOSTS="$(ssh-keyscan -t ed25519 "$VPS_HOST" 2>/dev/null)"
[[ -n "$KNOWN_HOSTS" ]] || { echo "Could not reach $VPS_HOST:22"; exit 1; }

echo "==> Variables in $REPO"
gh variable set VPS_HOST          --body "$VPS_HOST"
gh variable set VPS_KNOWN_HOSTS   --body "$KNOWN_HOSTS"
gh variable set DOKKU_DOMAIN      --body "$DOKKU_DOMAIN"
gh variable set LETSENCRYPT_EMAIL --body "$LETSENCRYPT_EMAIL"
gh variable set GHCR_USER         --body "$GHCR_USER"
[[ -z "${DOKKU_TAG:-}" ]] || gh variable set DOKKU_TAG --body "$DOKKU_TAG"
[[ -z "${SWAP_SIZE:-}" ]] || gh variable set SWAP_SIZE --body "$SWAP_SIZE"

echo "==> Secrets in $REPO"
gh secret set VPS_SSH_KEY      < "$KEYS/root"
gh secret set DOKKU_CI_SSH_KEY < "$KEYS/deploy"

# Tokens are read silently and passed through stdin (never on the command line).
ask_secret() {
  local name="$1" hint="$2" value
  read -rsp "$name ($hint) — paste it, or press Enter to skip: " value; echo
  if [[ -n "$value" ]]; then
    gh secret set "$name" < <(printf '%s' "$value")
  else
    echo "   skipped. Later: gh secret set $name --repo $REPO"
  fi
}

echo
if [[ -t 0 ]]; then
  echo "Now the 2 tokens (see the README for how to create each one):"
  ask_secret GHCR_TOKEN     "classic PAT, scope read:packages — only needed for private images"
  ask_secret GH_ADMIN_TOKEN "fine-grained PAT, Secrets: read and write on your app repos"
else
  echo "⚠️  Non-interactive terminal. Set the tokens yourself:"
  echo "    gh secret set GHCR_TOKEN --repo $REPO"
  echo "    gh secret set GH_ADMIN_TOKEN --repo $REPO"
fi

cat <<EOF

✅ Done. Last manual step: authorize the root key on the VPS.
   Add this public key to /root/.ssh/authorized_keys (most providers have an "SSH keys" page):

$(cat "$KEYS/root.pub")

   (or: ssh-copy-id -i $KEYS/root.pub root@$VPS_HOST)

Then: GitHub → Actions → "Bootstrap VPS" → Run workflow.
The private keys are in $KEYS. They are already stored as secrets, so back them up or delete them.
EOF
