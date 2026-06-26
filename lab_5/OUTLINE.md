# Lab 5 (DRAFT OUTLINE) — Stateful App on EKS + Aurora, Blue/Green the App

> **Status: DESIGN DRAFT — not built or tested yet.** This is the shape for review
> before implementation.
>
> **Independence (hard requirement):** Lab 5 is a **fully self-contained deploy** —
> its own `lab_5/terraform/` directory with its **own state backend**, deploying
> **all the resources it needs**. It does **not** modify `lab_environment/lab_env_student/`
> at all. There is **zero risk** to the tested Labs 1–4 deploy because Lab 5 never
> touches that Terraform or its state. It reads the student's existing EKS cluster
> **read-only** (a `data` source by cluster name) and creates everything else itself.

**Capstone** that integrates **Lab 1 (EKS app)** + **Lab 4 (Aurora)** and fills the
course's one gap: **Blue/Green deployment of a *stateful app* on Kubernetes** — and
the #1 real-world guardrail that comes with it, **backward-compatible (expand/contract)
schema changes during a rollout.**

---

## Premise

A small **"items" API** on EKS backed by **Aurora PostgreSQL**. v1 is live (**blue**).
You ship v2 (**green**) that adds a feature needing a schema change. You roll it out
Blue/Green — **both versions hit the same database at once** — so v2 must be backward
compatible. You watch traffic flip blue→green with zero downtime and instant rollback.

To make it *visible*: `GET /` returns `{"version":"v1|v2","color":"blue|green","item_count":<from Aurora>}`,
so a `curl` loop literally shows the version flip while the data persists.

---

## Objectives

By completing this lab, students will:
- Deploy a stateful app to EKS that connects to Aurora (Secrets Manager creds; IRSA for AWS access).
- Perform a **manual Kubernetes Blue/Green** deploy — two Deployments, flip one Service selector.
- Apply an **expand/contract** migration so blue and green coexist safely on one DB.
- **(Bonus)** Automate the Blue/Green with **Argo Rollouts** — preview service, one-command promote, instant abort/rollback, live dashboard.

---

## Architecture

```
                 ┌─────────── Service: myapp (selector: color=blue|green) ───────────┐
   curl / ─────► │            (flip the selector to cut traffic over)               │
                 └───────────────┬───────────────────────────┬─────────────────────┘
                                 │                            │
                    Deployment myapp-blue (v1)    Deployment myapp-green (v2)
                                 │                            │
                                 └──────────► Aurora PostgreSQL ◄──────────┘
                                       (Lab 5's OWN Aurora cluster)
```
- **App:** extends Lab 1's Flask `myapp` with `/items` (GET list / POST add) reading & writing Aurora.
- **DB creds:** Secrets Manager (minimal path) → stretch goal RDS IAM auth via IRSA (`rds-db:connect`).
- **EKS:** reuses the student's existing cluster via a read-only `data "aws_eks_cluster"` lookup — Lab 5 only *adds* a namespace + workloads into it, never reconfigures it.

---

## Part A — Core lab (minimal: "hey it works")

1. **Provision** (`cd lab_5/terraform && terraform apply` — separate state): Lab 5's own Aurora, `lab5-<id>` namespace, app image build, IRSA with `secretsmanager:GetSecretValue`, the DB secret.
2. **Deploy v1 (blue):** Helm/kubectl into `lab5-<id>`. Verify `/items` works; `POST` a couple of items.
3. **Expand (schema):** add a **nullable** column, e.g. `ALTER TABLE items ADD COLUMN priority INT;` — additive, v1 ignores it. *This is the guardrail step.*
4. **Build v2 (green):** app reads/writes `priority`; deploy `myapp-green` **alongside** blue (same DB).
5. **Preview green:** via a `myapp-preview` Service (or `kubectl port-forward`) — confirm v2 against live data before any traffic moves.
6. **Cut over:** flip the main Service selector `color=blue` → `color=green`. `curl /` now shows `version v2`. Zero downtime.
7. **Rollback drill:** flip the selector back to `blue` — instant, no data loss.
8. **Contract (later):** once v1 is retired, drop the old column / remove compat code.

> **Guardrail lesson:** if step 3 had been a *breaking* change (rename/drop a column),
> blue would have started erroring the instant green migrated. **Expand/contract** —
> add → deploy both-compatible → backfill → cut over → drop — is *why* zero-downtime
> Blue/Green is even possible against a shared database.

---

## Part B — Bonus (Argo Rollouts: "make it automatic")

1. **Install** the Argo Rollouts controller (a `helm_release` *inside Lab 5's own Terraform*, gated by a Lab-5-local `enable_argo` var — still independent of the main deploy).
2. **Replace** the two Deployments + manual Service flip with a single **`Rollout`** (`strategy.blueGreen`, `activeService` + `previewService`, `autoPromotionEnabled: false` so a human still approves — keeps the guardrail).
3. `kubectl argo rollouts get rollout myapp --watch` — see blue/green live; `promote` with one command; `abort` = instant rollback.
4. **Optional stretch:** an `AnalysisTemplate` that auto-promotes only if `/health` + an error-rate check pass — ties the automation back to the guardrails theme.

---

## What needs building (implementation checklist)

Everything lives under **`lab_5/`**, deployed from its **own Terraform + state** — `lab_env_student/` is **not touched**:

- **`lab_5/terraform/`** (own `backend.tf` / state): `data "aws_eks_cluster"` (read-only lookup by name, passed as a var); Lab-5 Aurora cluster + instance; `lab5-<id>` namespace; app CodeBuild + pipeline + ECR (or reuse a shared ECR by name, read-only); IRSA role; Secrets Manager DB secret; outputs (`lab5_namespace`, `lab5_db_endpoint`, `lab5_service_url`); `enable_argo` var for Part B.
- **`lab_5/src/`**: app — `/items` GET/POST + DB layer (`psycopg`); `GET /` returns version/color/item_count; migration SQL (expand + contract).
- **`lab_5/charts/`**: blue + green Deployments + Service + preview Service (Part A); `Rollout` + `AnalysisTemplate` (Part B).
- **`lab_5/README.md`**: student-facing guide, same format as Labs 1–4.
- **`STUDENT_SETUP.md` / `README.md`**: add Lab 5 to the path (doc-only, additive).

> Because Lab 5 is a separate apply against separate state, it can be deployed,
> torn down, or skipped entirely with no effect on the Labs 1–4 environment.

---

## Fit / time

| | Student time | Notes |
|---|---|---|
| Part A (manual B/G) | ~45–60 min | own Aurora + app; standalone capstone |
| Part B (Argo bonus) | +~30 min | + Argo Rollouts controller into the existing cluster |

Part A is a complete capstone on its own; Part B is the "make it real" upgrade.

---

## Open decisions (for review before building)
1. **DB auth:** Secrets Manager (simpler, recommended for Part A) vs RDS IAM auth via IRSA (more cloud-native, stretch).
2. **EKS:** reuse the student's existing Lab-1 cluster (read-only data source — recommended, it's the integration point) vs Lab 5 standing up its *own* cluster (fully standalone but heavier + slower). Reusing keeps it independent of the main *Terraform* while still leveraging the cluster they already have.
3. **App base:** extend Lab 1's `myapp` Flask app, or a fresh minimal service? (Recommend extend — continuity for students.)
4. **Scope for the day:** ship Part A only, or Part A + the Argo bonus?
