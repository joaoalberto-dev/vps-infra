# vps-infra

Turn a cheap VPS into a small PaaS with [**Dokku**](https://dokku.com), managed entirely from **GitHub Actions**.

```
this repo ──(Actions)──▶ VPS: bootstrap, apps, domains, memory limits
app repo  ──(Actions)──▶ docker build ─▶ ghcr.io ─▶ Dokku (git:from-image) ─▶ https://<app>.example.com
```

- **Apps as code:** declare apps in `apps.yml`, push, and they are created on the server.
- **No builds on the VPS:** images are built on GitHub runners, so a 1 vCPU / 1–4 GB box is enough.
- **Zero-downtime deploys, automatic HTTPS** (Let's Encrypt), and basic hardening (UFW, fail2ban, key-only SSH, unattended upgrades, swap).
- Nothing runs on your machine except `init-github.sh`, once.

## Requirements

- A VPS running **Ubuntu 22.04/24.04** (any provider) with root SSH access.
- A domain with a **wildcard DNS record** pointing to the VPS: `A *.example.com → <VPS IP>`. Every new app then gets a subdomain with no DNS changes.
- [`gh`](https://cli.github.com/) installed and logged in (`gh auth login`), only for the one-time setup.

## Layout

| File | Purpose |
|---|---|
| `apps.yml` | **App declarations.** Edit and push; the workflow applies them to the VPS |
| `.github/workflows/bootstrap.yml` | Prepares the VPS: hardening, Dokku, Let's Encrypt, ghcr.io login and deploy key. Manual and idempotent |
| `.github/workflows/sync-apps.yml` | Applies `apps.yml`. Runs on every push that changes it, or manually |
| `.github/workflows/deploy-dokku.yml` | **Reusable** build-and-deploy workflow, called by your app repos |
| `examples/deploy.yml` | The workflow to copy into each app repo |
| `scripts/bootstrap-vps.sh` | Runs on the VPS during bootstrap |
| `scripts/sync-apps.sh` | Runs during sync |
| `scripts/init-github.sh` | One-time setup: generates keys and writes the secrets and variables |

## Setup (once)

1. Click **Use this template** (or fork), then clone your copy.
2. `cp .env.example .env`, fill it in and run `scripts/init-github.sh`.
3. Authorize the root key the script prints on the VPS (your provider's "SSH keys" page, or `ssh-copy-id`).
4. If your repo is **private**: *Settings → Actions → General → Access* → "Accessible from repositories owned by the user", so your app repos can call `deploy-dokku.yml`.
5. **Actions → Bootstrap VPS → Run workflow** (takes 5–10 minutes).

> ⚠️ The bootstrap disables SSH password login, but **only** if it finds a key in `/root/.ssh/authorized_keys`. Make sure you can log in with your own key too.

### Secrets and variables

`init-github.sh` sets all of these for you.

| Name | Type | What it is |
|---|---|---|
| `VPS_HOST` | variable | VPS IP or hostname |
| `VPS_KNOWN_HOSTS` | variable | VPS host key (protects against MITM) |
| `DOKKU_DOMAIN` | variable | Base domain, e.g. `example.com` |
| `LETSENCRYPT_EMAIL` | variable | Email for Let's Encrypt notices |
| `GHCR_USER` | variable | GitHub user that owns the images |
| `DOKKU_TAG` | variable (optional) | Dokku version to install |
| `SWAP_SIZE` | variable (optional) | Swap file size, default `2G`; `0` disables it |
| `VPS_SSH_KEY` | secret | **Root** key, used only by this repo's workflows |
| `DOKKU_CI_SSH_KEY` | secret | Deploy key (`dokku` user, not root), copied into your app repos |
| `GHCR_TOKEN` | secret (optional) | [Classic PAT](https://github.com/settings/tokens/new?scopes=read:packages&description=dokku-ghcr) with `read:packages`, so the VPS can pull **private** images. Fine-grained tokens don't work with ghcr.io |
| `GH_ADMIN_TOKEN` | secret (optional) | [Fine-grained PAT](https://github.com/settings/personal-access-tokens/new) with access to your app repos and *Secrets: Read and write*, so Sync can write their deploy secrets. Without it, set them by hand |

## Adding an app

1. In the app's repo, add a `Dockerfile` and copy [`examples/deploy.yml`](examples/deploy.yml) to `.github/workflows/deploy.yml`. Replace `YOUR-USER` and `app:`.
2. Declare the app in `apps.yml` and push:
   ```yaml
   apps:
     - name: my-api
       memory: 512m
       repo: YOUR-USER/my-api
   ```
   **Sync apps** creates the app in Dokku and writes the `DOKKU_*` secrets into the app's repo.
3. Push to `main` in the app's repo. It goes live at `https://my-api.example.com`, and HTTPS is enabled on the first deploy.

See the comments in [`apps.yml`](apps.yml) for every field: custom domains, port, memory, and so on.

## Operations

- **Logs:** `ssh dokku@VPS logs my-api -t`
- **Environment variables:** `ssh dokku@VPS config:set my-api KEY=value` (restarts the app)
- **Rollback:** re-run the deploy workflow of an earlier commit (*Actions → Deploy → Re-run*).
- **Database:** `ssh root@VPS dokku plugin:install https://github.com/dokku/dokku-postgres.git`, then `ssh dokku@VPS postgres:create my-db` and `ssh dokku@VPS postgres:link my-db my-api` (injects `DATABASE_URL`).
- **Deleting an app:** removing it from `apps.yml` deletes nothing, on purpose. To delete: `ssh root@VPS dokku apps:destroy my-api --force`
- **Upgrading Dokku:** change the `DOKKU_TAG` variable (or the default in `scripts/bootstrap-vps.sh`) and run Bootstrap again.

## Small servers

- Dokku itself uses very little (nginx + Docker).
- During a deploy, the old and new containers run side by side for `wait_to_retire` seconds (30 by default). The swap file absorbs that spike.
- Set `memory` on each app so one app can't take down the others.

## License

[MIT](LICENSE)
