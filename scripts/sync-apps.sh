#!/usr/bin/env bash
# Applies apps.yml to the VPS. Idempotent. Runs in GitHub Actions (or locally, with yq + gh).
#
# Required env: VPS_HOST, DOKKU_DOMAIN
# Optional env (to write deploy secrets into each app's repo):
#   GH_TOKEN, DOKKU_CI_SSH_KEY, VPS_KNOWN_HOSTS
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VPS_HOST:?}" "${DOKKU_DOMAIN:?}"
APPS_FILE="${APPS_FILE:-apps.yml}"

# Every value passed here is validated below, so no extra shell escaping is needed over ssh.
dk() { ssh "root@$VPS_HOST" -- dokku "$@"; }
summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; echo "$*"; }
fail() { echo "::error file=$APPS_FILE::$*"; exit 1; }
field() { yq "$1" "$APPS_FILE"; }
sorted() { tr ' ' '\n' | sed '/^$/d' | sort -u | xargs; }

count=$(field '.apps | length')
summary "### Apps ($count)"
summary "| App | URLs | Port | Memory | Repo secrets |"
summary "|---|---|---|---|---|"

for ((i = 0; i < count; i++)); do
  a=".apps[$i]"
  name=$(field "$a.name // \"\"")
  sub=$(field "$a.subdomain // \"$name\"")
  domains=$(field "$a.domains // [] | join(\" \")")
  port=$(field "$a.port // .defaults.port // 5000")
  memory=$(field "$a.memory // .defaults.memory // \"\"")
  retire=$(field "$a.wait_to_retire // .defaults.wait_to_retire // 30")
  repo=$(field "$a.repo // \"\"")
  [[ -n "$domains" ]] || domains="$sub.$DOKKU_DOMAIN"

  # Validation (also keeps the remote shell safe)
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || fail "apps[$i]: invalid name '$name' (lowercase letters, digits and '-')"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail "$name: invalid port '$port'"
  [[ "$retire" =~ ^[0-9]+$ ]] || fail "$name: invalid wait_to_retire '$retire'"
  [[ -z "$memory" || "$memory" =~ ^[0-9]+[bkmg]?$ ]] || fail "$name: invalid memory '$memory' (e.g. 256m, 1g)"
  [[ -z "$repo" || "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "$name: invalid repo '$repo' (owner/name)"
  for d in $domains; do
    [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fail "$name: invalid domain '$d'"
  done
  domains=$(sorted <<<"$domains")

  echo "::group::$name"

  if ! dk apps:exists "$name" >/dev/null 2>&1; then
    dk apps:create "$name"
  fi

  # Domains (if they changed and HTTPS was already on, re-issue the certificate)
  current=$(dk domains:report "$name" --domains-app-vhosts | sorted)
  https=$(dk letsencrypt:active "$name" 2>/dev/null | xargs || true)
  if [[ "$current" != "$domains" ]]; then
    # shellcheck disable=SC2086
    dk domains:set "$name" $domains
    if [[ "$https" == "true" ]]; then
      dk letsencrypt:enable "$name" --force
    fi
  fi

  # Ports (keep 443 when HTTPS is already active)
  if [[ "$https" == "true" ]]; then
    dk ports:set "$name" "http:80:$port" "https:443:$port"
  else
    dk ports:set "$name" "http:80:$port"
  fi

  # Zero downtime on small machines: the old container is retired N seconds after the new one takes over
  dk checks:set "$name" wait-to-retire "$retire"

  if [[ -n "$memory" ]]; then
    dk resource:limit "$name" --memory "$memory"
  else
    dk resource:limit-clear "$name" >/dev/null 2>&1 || true
  fi

  secrets="—"
  if [[ -n "$repo" ]]; then
    if [[ -n "${GH_TOKEN:-}" && -n "${DOKKU_CI_SSH_KEY:-}" && -n "${VPS_KNOWN_HOSTS:-}" ]]; then
      if gh secret set DOKKU_HOST --repo "$repo" --body "$VPS_HOST" &&
         gh secret set DOKKU_SSH_KEY --repo "$repo" < <(printf '%s\n' "$DOKKU_CI_SSH_KEY") &&
         gh secret set DOKKU_KNOWN_HOSTS --repo "$repo" --body "$VPS_KNOWN_HOSTS"; then
        secrets="✅ $repo"
      else
        secrets="⚠️ failed (does $repo exist? does the token have access?)"
      fi
    else
      secrets="⚠️ missing GH_TOKEN/DOKKU_CI_SSH_KEY/VPS_KNOWN_HOSTS"
    fi
  fi

  echo "::endgroup::"
  urls=$(for d in $domains; do printf 'https://%s ' "$d"; done)
  summary "| \`$name\` | ${urls% } | $port | ${memory:-no limit} | $secrets |"
done
