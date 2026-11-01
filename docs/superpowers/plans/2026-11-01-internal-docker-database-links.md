# Implementation Plan: Internal Docker Networking for Databases

**Date:** 2026-11-01
**Target:** Twenty CRM Compose Deployment on Dokploy
**Host:** `2.25.71.201` (VPS)
**Dokploy Network:** `dokploy-network`

---

## 1. Objective & Architecture Overview

Migrate Twenty CRM's `server` and `worker` containers from routing database and cache queries through the host's public IP (`2.25.71.201`) to using Docker's internal DNS resolution over the shared `dokploy-network` bridge.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Host VPS (2.25.71.201)                                                          │
│                                                                                 │
│   dokploy-network (Docker Bridge Network)                                       │
│   ├── Twenty Server (compose-quantify-bluetooth-matrix-5p7wi3)                  │
│   ├── Twenty Worker (compose-quantify-bluetooth-matrix-5p7wi3)                  │
│   │       │                                                                     │
│   │       ├──▶ postgresql://... @database-postgresql-adg7lr:5432/kynd_crm      │
│   │       └──▶ redis://... @databases-redis-brbfnm:6379/3                       │
│   │                                                                             │
│   ├── PostgreSQL Container (database-postgresql-adg7lr) [Project: Databases]    │
│   └── Redis Container (databases-redis-brbfnm) [Project: Databases]             │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key Benefits:
- **Zero Public Egress / Ingress Latency:** Bypasses VPS external networking stack and firewall routing.
- **Enhanced Security:** Database traffic does not route through public network interfaces.
- **Resilience:** Unaffected by public IP changes, DNS reconfigurations, or external bandwidth throttling.

---

## 2. Resource Mapping

| Service | Dokploy Project | Container Name (`appName`) | Internal Port | Internal Connection String |
| :--- | :--- | :--- | :--- | :--- |
| **PostgreSQL 16** | `Databases` (`aEzmBFApRDKzGOasOUjnu`) | `database-postgresql-adg7lr` | `5432` | `postgresql://postgres:<PASSWORD>@database-postgresql-adg7lr:5432/kynd_crm` |
| **Redis 7/8** | `Databases` (`aEzmBFApRDKzGOasOUjnu`) | `databases-redis-brbfnm` | `6379` | `redis://default:<PASSWORD>@databases-redis-brbfnm:6379/3` |

---

## 3. Step-by-Step Execution Plan

### Step 1: Local Configuration Update
- Update [`.env.production`](file:///Users/waqas/DEV/CRM/.env.production):
  ```bash
  PG_DATABASE_URL=postgresql://postgres:<PG_PASSWORD>@database-postgresql-adg7lr:5432/kynd_crm
  REDIS_URL=redis://default:<REDIS_PASSWORD>@databases-redis-brbfnm:6379/3
  ```
- Keep passwords and credentials identical so existing schema, tables, and Redis keys are preserved without data migration.

### Step 2: Dokploy Compose Environment Synchronization
- Use Dokploy API endpoint `POST /api/compose.update` with payload targeting `composeId: C2yGJCMsac398s_cfwmEb`:
  - Set `env` containing the updated `PG_DATABASE_URL` and `REDIS_URL`.
  - Ensure all other production variables (`APP_SECRET`, `ENCRYPTION_KEY`, Brevo SMTP, S3 storage) remain intact.

### Step 3: Trigger Seamless Redeployment
- Call Dokploy API `POST /api/compose.deploy` with `{ "composeId": "C2yGJCMsac398s_cfwmEb" }`.
- Dokploy will recreate `server` and `worker` with the new environment variables attached to `dokploy-network`.

### Step 4: Verification & Smoke Testing
1. **Database Connectivity:** Query `https://crm.kyndstudio.com/graphql` to verify database queries execute normally.
2. **Worker BullMQ Queue:** Confirm worker processes jobs without Redis connection timeouts.
3. **Webhook Verification:** Trigger a contact update to confirm end-to-end webhook execution to n8n.

### Step 5: Rollback Safeguard
If Docker internal DNS resolution fails:
- Revert `PG_DATABASE_URL` and `REDIS_URL` in Dokploy to `2.25.71.201:5432` and `2.25.71.201:6379`.
- Re-run `POST /api/compose.deploy`.
