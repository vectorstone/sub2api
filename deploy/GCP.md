# Deploying Sub2API on Google Cloud Platform (GCP)

This guide describes practical GCP deployment options for the current Sub2API repository, which already ships with Docker Compose deployment assets under `deploy/`.

## Recommended approach

For the current codebase, the best GCP first deployment target is:

- **Compute Engine + Docker Compose**
- Start with a **single VM** for the app tier
- Add managed services only when you need stronger durability or easier operations

This repository already assumes:

- container-based deployment (`deploy/docker-compose*.yml`)
- local persistent application data under `/app/data`
- PostgreSQL and Redis dependencies

Because of that, **Compute Engine maps cleanly to the existing deployment model** and requires the fewest changes.

## Region and pricing assumptions

The examples below use:

- **Region:** `us-central1` (Iowa)
- **Estimate date:** 2026-04-16
- **Billing model:** on-demand, no committed use discounts
- **Traffic profile:** low to moderate request volume

Prices can change. Recalculate before purchase with the pricing pages linked at the end of this document.

---

## Option A: Single VM with Docker Compose (lowest operational complexity)

**Best for**

- MVPs
- personal deployments
- small team use
- low to moderate concurrency

### Architecture

One Compute Engine VM runs:

- `sub2api`
- `postgres`
- `redis`
- optional `nginx` or Caddy for TLS termination

### Suggested shape

- **Machine:** `e2-standard-2` (2 vCPU, 8 GiB)
- **Disk:** `pd-balanced` 50 GiB
- **OS:** Ubuntu 24.04 LTS

### Why this is the default recommendation

- Matches `deploy/docker-compose.local.yml` directly
- No application changes required
- Lowest moving parts count
- Lowest cost for a durable first production deployment

### Deployment notes

1. Create a VM in `us-central1`
2. Install Docker Engine + Docker Compose plugin
3. Copy the deployment files from `deploy/`
4. Use `docker-compose.local.yml`
5. Bind a domain name to the VM external IP
6. Add Nginx or Caddy in front of port `8080` for HTTPS
7. Back up `data/`, `postgres_data/`, and `redis_data/` to Cloud Storage

### Estimated monthly cost

| Item | Assumption | Estimated monthly cost |
| --- | --- | ---: |
| Compute Engine VM | `e2-standard-2` @ `$0.06701142/hour` | **~$48.92** |
| Persistent Disk | `pd-balanced` 50 GiB @ `$0.10/GB-month` | **~$5.00** |
| External IPv4 | in-use VM IP @ `$0.005/hour` | **~$3.65** |
| **Total** | before backups/egress | **~$57.57/month** |

### Practical budget

Plan for **$60–75/month** after small extras such as snapshots, backups, and light outbound traffic.

---

## Option B: Compute Engine + Cloud SQL (recommended light-production upgrade)

**Best for**

- small production services
- teams that want managed PostgreSQL
- easier backup / restore / upgrade story

### Architecture

- VM runs `sub2api`
- PostgreSQL moves to **Cloud SQL for PostgreSQL**
- Redis can stay:
  - on the same VM for cost efficiency, or
  - move to Memorystore later if needed

### Suggested shape

- **App VM:** `e2-standard-2`
- **Database:** Cloud SQL PostgreSQL `db-g1-small` for a low-cost starting point
- **Redis:** start self-managed unless you specifically need managed Redis

### Why this is often the best second step

- Keeps deployment close to current Docker workflow
- Offloads the riskiest stateful component (PostgreSQL)
- Gives you automated Cloud SQL backups with less operational work

### Deployment notes

1. Create a Compute Engine VM for the app tier
2. Create a Cloud SQL PostgreSQL instance in the same region
3. Point `DATABASE_*` env vars to Cloud SQL
4. Keep Redis in Docker initially to save money
5. Use Cloud SQL automatic backups
6. Back up `/app/data` to Cloud Storage

### Estimated monthly cost

| Item | Assumption | Estimated monthly cost |
| --- | --- | ---: |
| Compute Engine VM | `e2-standard-2` | **~$48.92** |
| App disk | `pd-balanced` 20 GiB | **~$2.00** |
| External IPv4 | in-use VM IP | **~$3.65** |
| Cloud SQL instance | `db-g1-small` @ `$0.035/hour` | **~$25.55** |
| Cloud SQL storage + backups | small starter allocation | **~$5–15** |
| **Total** | with self-managed Redis on the VM | **~$85–95/month** |

### Practical budget

Plan for **~$90–110/month** depending on database size, backup retention, and egress.

---

## Option C: Compute Engine + Cloud SQL + Memorystore (managed stateful services)

**Best for**

- teams that want managed PostgreSQL and managed Redis
- deployments where operational simplicity is worth the higher bill

### Architecture

- VM runs `sub2api`
- PostgreSQL uses Cloud SQL
- Redis uses Memorystore for Redis

### Cost caveat

Managed Redis is often the biggest jump in monthly spend for a small deployment.

### Estimated monthly cost

| Item | Assumption | Estimated monthly cost |
| --- | --- | ---: |
| Compute Engine VM | `e2-standard-2` | **~$48.92** |
| App disk | `pd-balanced` 20 GiB | **~$2.00** |
| External IPv4 | in-use VM IP | **~$3.65** |
| Cloud SQL instance | `db-g1-small` | **~$25.55** |
| Cloud SQL storage + backups | starter allocation | **~$5–15** |
| Memorystore | shared-core-nano 1.4 GiB @ `$0.0318/hour` | **~$23.21** |
| **Total** | before extra egress | **~$108–118/month** |

### Practical budget

Plan for **~$110–130/month**.

---

## Why Cloud Run is not the first recommendation here

Cloud Run can work, but it is not the best first target for this repository.

### Reasons

- Current deployment assets are optimized for Docker Compose, not serverless runtime patterns
- `/app/data` persistence expectations do not map cleanly to Cloud Run's ephemeral filesystem
- You still need PostgreSQL and Redis outside the service
- Long-lived streaming/API gateway behavior usually needs more tuning on Cloud Run than on a VM

### When Cloud Run makes sense

Consider Cloud Run only if you explicitly want:

- request-driven scale-to-zero behavior
- very small sporadic traffic
- a serverless operations model

Even then, expect more deployment reshaping than the Compute Engine path.

---

## Security and networking checklist

For any of the options above:

1. Put the app behind HTTPS
2. Restrict SSH access with IAP or source IP allowlists
3. Limit PostgreSQL exposure:
   - private IP preferred
   - avoid public SQL unless necessary
4. Keep Redis private
5. Store secrets in Secret Manager or at minimum separate `.env` handling
6. Turn on VM snapshots / Cloud SQL backups before go-live
7. Add uptime checks and alerting in Cloud Monitoring

---

## Suggested rollout path

### Path 1: lowest cost, fastest launch

- Start with **Option A**
- Move to Option B later if DB operations become painful

### Path 2: best balance for a small paid service

- Start with **Option B**
- Keep Redis self-managed first
- Add Memorystore only if Redis availability/maintenance becomes a real pain point

### Path 3: higher-compliance / lower-ops stateful layer

- Use **Option C**
- Accept the higher monthly bill in exchange for managed PostgreSQL + Redis

---

## Rule of thumb

- **Cheapest durable start:** Option A
- **Best small-production balance:** Option B
- **Most managed:** Option C

For the current repository and a normal first GCP deployment, **Option B is usually the best long-term balance**, but **Option A is the fastest and cheapest path to get into production safely**.

---

## Official pricing references

Use these pages to recalculate before you commit:

- Compute Engine VM pricing: https://cloud.google.com/compute/vm-instance-pricing
- Cloud SQL for PostgreSQL pricing: https://cloud.google.com/sql/docs/postgres/pricing
- Memorystore for Redis pricing: https://cloud.google.com/memorystore/docs/redis/pricing
- Block storage pricing: https://cloud.google.com/products/block-storage
- External IP pricing: https://cloud.google.com/vpc/pricing
- Cloud Run pricing: https://cloud.google.com/run/pricing
