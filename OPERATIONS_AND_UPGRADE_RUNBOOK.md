# Twenty CRM — Agency Operations, Backup & Upgrade Runbook

This runbook documents the critical procedures required to operate, back up, and upgrade this Twenty CRM soft-fork across multiple clients over multi-year engagements without data loss or schema corruption.

---

## 1. Cryptographic Key & Secret Escrow (CRITICAL)

Twenty CRM encrypts sensitive workspace credentials—including connected Gmail/Microsoft OAuth tokens, webhook secrets, API secrets, and database-stored configuration variables (`IS_CONFIG_VARIABLES_IN_DB_ENABLED=true`)—using two environment variables:

- `APP_SECRET`
- `ENCRYPTION_KEY`

### Golden Rule
> **Never rotate, regenerate, or lose `APP_SECRET` or `ENCRYPTION_KEY` on an active database.**
> If your server dies and you restore the PostgreSQL database (`kynd_crm`) with a different `APP_SECRET` or `ENCRYPTION_KEY`, Twenty will fail to decrypt stored workspace secrets and OAuth tokens, breaking all connected mailboxes and integrations across every client workspace.

### Action Checklist
1. Store a copy of `.env.production` and `.env.dokploy` in an encrypted password vault (e.g., 1Password / Bitwarden) outside the VPS (`2.25.71.201`).
2. Never commit `.env.production`, `.env.dokploy`, or raw JWT API keys (`TWENTY_API_KEY`) to Git.
3. Rotate any API key that was ever committed to Git history (`Settings → APIs & Webhooks` in Twenty CRM) and inject it into n8n via environment variables (`TWENTY_API_KEY_CLIENT_1`, `TWENTY_WEBHOOK_SECRET`, `BREVO_API_KEY`).

---

## 2. Database & Object Storage Backup Strategy

The `docker-compose.dokploy.yml` stack includes an automated **`pg-backup`** service (`postgres:18-alpine`) that runs daily compressed custom-format dumps (`pg_dump -Fc`) of `PG_DATABASE_URL` into the `twenty-db-backups` volume (`/backups`) with automatic retention (`BACKUP_KEEP_DAYS=14` by default) and maintains `/backups/twenty-crm-latest.dump`.

### Manual Pre-Upgrade Snapshot
Before **every** Twenty version upgrade, trigger an immediate custom-format dump into the backup volume:

```bash
docker exec $(docker ps -qf "name=pg-backup") sh -c 'pg_dump -Fc "$PG_DATABASE_URL" -f "/backups/pre-upgrade-$(date +%Y%m%d-%H%M%S).dump"'
```

### Restoring a Backup
To restore a custom-format `.dump` file into a clean or staging PostgreSQL database:

```bash
docker exec -i $(docker ps -qf "name=pg-backup") sh -c 'pg_restore --clean --if-exists --no-owner -d "$PG_DATABASE_URL" /backups/twenty-crm-latest.dump'
```

### Off-Server Replication (3-2-1 Rule)
Because PostgreSQL (`2.25.71.201:5432`) and S3 (`s3.kyndstudio.com`) run on your managed infrastructure, sync the `/var/lib/docker/volumes/*twenty-db-backups/_data` directory and S3 bucket (`crm-kyndstudio`) nightly to an independent off-site object store (e.g., Cloudflare R2 or Backblaze B2) via `rclone` or Dokploy's S3 backup destination.

---

## 3. Safe Sequential Upgrade Procedure

Twenty CRM uses both TypeORM core schema migrations and per-workspace metadata migrations (`yarn command:prod upgrade`).

### Why Sequential Minor Upgrades Matter
- **Never skip minor versions** (e.g., do not jump directly from `v2.9.x` to `v2.12.x`). Always upgrade one minor release tag at a time (`v2.9.x` → `v2.10.x` → `v2.11.x`).
- Avoid deploying unpinned `:latest` builds from `upstream/main` in production. Always rebase/merge your `agency-prod` commits onto official `upstream` release tags.

### Step-by-Step Upgrade Workflow

1. **Take a Database Snapshot** (see Section 2 above).
2. **Fetch Official Upstream Release Tags:**
   ```bash
   git fetch upstream --tags
   ```
3. **Rebase `agency-prod` onto the Next Minor Release Tag (e.g., `v2.10.0`):**
   ```bash
   git checkout agency-prod
   git rebase v2.10.0
   ```
   *(Tip: Keep custom changes limited to branding assets, `docker-compose.dokploy.yml`, `n8n-twenty-ai-lead-agent.json`, and `.github/workflows/build-ghcr.yml` so rebases stay conflict-free.)*
4. **Push to Build the Versioned GHCR Image:**
   ```bash
   git push origin agency-prod --force-with-lease
   ```
   GitHub Actions (`build-ghcr.yml`) will build the image with `APP_VERSION=<version>` baked in and push `ghcr.io/thewaqaspro/twenty:v<version>`.
5. **Update `TAG` in Dokploy Environment:**
   Set `TAG=v2.10.0` (matching the release tag) in your Dokploy environment variables and redeploy.
6. **Verify Startup Migration Logs:**
   Check the `server` container logs immediately after deployment:
   ```bash
   docker logs $(docker ps -qf "name=server") --tail 100
   ```
   Confirm `Successfully migrated DB!` appears without `"Warning: Upgrade completed with errors"`.

---

## 4. Multi-Client Architecture Guide

When onboarding multiple agency clients, choose one of these two supported isolation models:

| Model | Configuration | Best For | Isolation & Trade-offs |
| :--- | :--- | :--- | :--- |
| **Model A: Multi-Workspace Subdomains (Single Stack)** | `IS_MULTIWORKSPACE_ENABLED=true`<br>`DEFAULT_SUBDOMAIN=crm`<br>`FRONT_AUTO_BASE_URL=true` | Onboarding 2–25 agency clients quickly under `*.kyndstudio.com` (`client1.kyndstudio.com`, `client2.kyndstudio.com`). | Each client gets an isolated PostgreSQL schema (`workspace_<id>`) and dedicated API key. All clients share the same container resources and maintenance window. |
| **Model B: Dedicated Stack per Client** | `IS_MULTIWORKSPACE_ENABLED=false`<br>Separate `PG_DATABASE_URL` (`kynd_crm_clientX`) & Redis DB index (`REDIS_URL=.../4`) | High-retainer enterprise clients who require custom domains (`crm.clientdomain.com`), independent SLAs, or future full data handoff. | Complete database, cache, and container isolation. Zero cross-client blast radius during upgrades. |

> **Warning:** Never invite external users from different client companies into the **same** workspace (`IS_MULTIWORKSPACE_ENABLED=false` on a single database), as users within a single workspace share visibility into contacts, companies, and pipeline metadata unless strict enterprise row-level permissions are configured.

---

## 5. n8n AI Lead Agent Configuration

When importing `n8n-twenty-ai-lead-agent.json` into n8n (`https://n8n.kyndstudio.com`), configure the following environment variables in your n8n container/deployment:

- `TWENTY_WEBHOOK_SECRET`: Shared secret string configured in Twenty CRM webhook headers (`X-Webhook-Secret`) to block unauthorized requests.
- `TWENTY_API_KEY_CLIENT_1`: Twenty API key generated inside Client 1's workspace.
- `TWENTY_API_KEY_CLIENT_2`: Twenty API key generated inside Client 2's workspace.
- `BREVO_API_KEY`: Brevo transactional API v3 key for sending outbound lead qualification emails.

---

## 6. Automated Backup Script (`scripts/backup-twenty.sh`)

The script `scripts/backup-twenty.sh` implements Checklist Item 11 by performing end-to-end database dumping, secrets archiving, AES-256 encryption, and S3 offsite replication.

### Features
1. **Container & Direct Fallback**: Automatically targets `database-postgresql-adg7lr` via `docker exec pg_dump -U postgres -F c kynd_crm`. If executed outside the host Docker daemon, it automatically resolves to `PG_DATABASE_URL` using the VPS endpoint.
2. **Key Escrow Bundling**: Bundles `.env.production` (containing `ENCRYPTION_KEY` and `APP_SECRET`) and a `manifest.json` along with the database dump.
3. **AES-256-CBC Encryption**: Encrypts the tarball using PBKDF2 with 100,000 iterations (`openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000`).
4. **S3 Replication**: Uses `aws s3 cp` or `rclone` to push the encrypted bundle to offsite object storage (Cloudflare R2, Backblaze B2, or MinIO).
5. **Local Pruning**: Purges backups older than 7 days (`find -mtime +7`).

### Daily Cron Configuration (02:30 UTC)
To automate this daily at 02:30 UTC, install this cron entry on the host:

```bash
# Add to host crontab (crontab -e):
30 2 * * * /Users/waqas/DEV/CRM/scripts/backup-twenty.sh >> /var/log/twenty-backup.log 2>&1
```

### Decrypting and Extracting Backups
To restore or inspect a backup archive:
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -in /path/to/twenty-backup-YYYYMMDD_HHMMSSZ.tar.gz.enc \
  -out backup.tar.gz \
  -pass pass:<YOUR_ENCRYPTION_KEY>

tar -xzvf backup.tar.gz
# Yields: twenty-database.dump, .env.production, manifest.json
```

---

## 7. Automated Upstream Upgrade Script (`scripts/upgrade-twenty-fork.sh`)

The script `scripts/upgrade-twenty-fork.sh` automates the monthly upstream rebase workflow for the agency soft-fork.

### Execution Workflow
```bash
./scripts/upgrade-twenty-fork.sh v2.10.0
```

1. **Safety Pre-flight**: Verifies git working directory is clean, then automatically runs `scripts/backup-twenty.sh` to take a full encrypted database and secrets snapshot before modifying any git ref.
2. **Upstream Tag Fetching**: Ensures `upstream` points to `https://github.com/twentyhq/twenty.git` and fetches latest release tags (`git fetch upstream --tags`).
3. **Branch Sync & Rebase**: Checks out `agency-prod` and rebases our soft-fork commits cleanly on top of the target upstream tag (`git rebase <tag>`).
4. **Automated Conflict Guard**: If any upstream code conflicts arise, halts execution and presents resolution steps (`git rebase --continue` / `git rebase --abort`).
5. **GHCR Trigger**: Pushes `agency-prod` to origin using `--force-with-lease`, triggering the GitHub Actions GHCR Docker build workflow (`.github/workflows/build-ghcr.yml`).
