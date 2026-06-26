# Lab 5 (Capstone, Optional): Blue/Green a Stateful App on EKS + Aurora

**Duration:** 45–60 minutes

> **Advanced / optional capstone.** Lab 5 is a **fully independent deploy** with
> its **own Terraform state**. It reads your existing EKS cluster **read-only**
> and creates everything else (its own Aurora, namespace, IRSA role, ECR repo).
> It does **not** touch the Labs 1–4 environment — you can run it, tear it down,
> or skip it with zero effect on the rest of the course. This guide covers
> **Part A** (manual Kubernetes Blue/Green). Part B (Argo Rollouts) is a later
> bonus and is not built yet.

---

## Objectives

By completing this lab, you will:

- Deploy a **stateful** Flask "items" API to EKS that connects to **Aurora PostgreSQL**, reading its DB credentials from **AWS Secrets Manager** via **IRSA** (no static passwords in the pod).
- Run a **manual Kubernetes Blue/Green** deploy: two Deployments (blue = v1, green = v2) built from **one image**, behavior gated by env vars, with traffic chosen by a single **Service selector** you flip.
- Apply an **expand/contract** schema migration so blue (v1) and green (v2) safely share **one database** during the rollout.
- Cut traffic over blue → green with **zero downtime**, then prove **instant rollback** by flipping back.

---

## Prerequisites

Before starting this lab, ensure you have:

- [ ] Labs 1 and 4 understood (EKS app deploy + Aurora) — this capstone integrates both.
- [ ] Your main `lab_env_student` deploy is **applied and running** (you need a live EKS cluster). You do **not** need any of the `enable_lab1..4` lab pipelines on; Lab 5 only reads the shared cluster/VPC.
- [ ] Your `kubectl` is pointed at that cluster: `aws eks update-kubeconfig --name <cluster> --region <region>`.
- [ ] **Docker** installed (Lab 5 builds an image locally). If your workstation doesn't have it: `curl -sSL https://raw.githubusercontent.com/roi-cloud-fun/io-107/main/scripts/install_student_deps.sh | sudo bash -s -- --with-docker` (then log out/in so your user is in the `docker` group).
- [ ] Terraform, AWS CLI v2, Helm, and `git` installed (the standard lab toolchain).

**Course Repository:** **[https://github.com/roi-cloud-fun/io-107](https://github.com/roi-cloud-fun/io-107)** — Lab 5 lives in `lab_5/`.

> **Why an independent deploy?** Lab 5 stands up its **own** Aurora and IRSA in
> its **own** state. It references your existing cluster through a read-only
> `data` source — never a `terraform import`. That keeps ownership of the
> cluster in your main state where it belongs, so a `terraform destroy` in
> Lab 5 can never delete anything Labs 1–4 depend on.

---

## Pre-Lab Setup

**1. Provision Lab 5's own infrastructure.** From the repo root:

```bash
cd lab_5/terraform
cp terraform.tfvars.example terraform.tfvars
cp backend.tf.example backend.tf
```

Edit **`terraform.tfvars`** — set `student_id` and `aws_region` to match your
main deploy, and point `main_remote_state` at your `lab_env_student` state
(same bucket you bootstrapped, key `lab_env_student/<your-id>.tfstate`):

```hcl
student_id = "alice"
aws_region = "us-east-1"

main_remote_state = {
  bucket = "io107-alice-tfstate-123456789012"
  key    = "lab_env_student/alice.tfstate"
  region = "us-east-1"
}
```

Edit **`backend.tf`** — set the **same bucket** and a **unique** key
(`lab_5/<your-id>.tfstate`, *not* your lab_env_student key).

Then apply (Aurora takes ~10 minutes to come up):

```bash
terraform init
terraform apply        # review the plan, type 'yes'
```

Capture the outputs — the rest of the lab references them:

```bash
eval "$(terraform output -json | jq -r 'to_entries[] | "export \(.key | ascii_upcase)=\"\(.value.value)\""')"

echo "Namespace:   $LAB5_NAMESPACE"
echo "ECR repo:    $LAB5_ECR_REPO_URL"
echo "DB endpoint: $LAB5_DB_ENDPOINT"
echo "DB secret:   $LAB5_DB_SECRET_NAME"
echo "IRSA role:   $LAB5_MYAPP_ROLE_ARN"
echo "Region:      $LAB5_REGION"
```

> These env vars persist for this shell. If you open a new terminal, re-run the
> `eval` block from `lab_5/terraform`.

**2. Return to your home directory** before building. As in every lab, you do
**not** build or clone inside the Terraform folder:

```bash
cd ~
```

---

## Part 1: Build the Image and Deploy Blue (v1)

### Task 1: Build and push the app image (once)

The same image runs as both blue and green — behavior is chosen at runtime by
env vars, so you build it exactly once. From your home directory, get the
`lab_5/` source (clone the course repo if you haven't):

```bash
cd ~
git clone https://github.com/roi-cloud-fun/io-107.git 2>/dev/null || true
cd ~/io-107/lab_5
```

Log Docker into ECR, build, and push:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${LAB5_REGION}.amazonaws.com"

aws ecr get-login-password --region "$LAB5_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$LAB5_ECR_REPO_URL:v1" .
docker push "$LAB5_ECR_REPO_URL:v1"
```

> We tag the image `v1` purely as a label for this build; **blue and green use
> the same `:v1` image**. The v1/v2 *behavior* difference is the env vars the
> chart sets, not two different images.

### Task 2: Deploy blue with Helm

Install the chart with **only blue enabled** (`green.enabled=false` is the
default). Wire in your ECR repo, the IRSA role, and the Aurora connection:

```bash
helm upgrade --install myapp ~/io-107/lab_5/charts/myapp \
  -n "$LAB5_NAMESPACE" \
  --set image.repository="$LAB5_ECR_REPO_URL" \
  --set image.tag=v1 \
  --set serviceAccount.roleArn="$LAB5_MYAPP_ROLE_ARN" \
  --set db.secretName="$LAB5_DB_SECRET_NAME" \
  --set db.host="$LAB5_DB_ENDPOINT" \
  --set db.name=appdb \
  --set region="$LAB5_REGION" \
  --wait
```

Watch the pods come up:

```bash
kubectl get pods -n "$LAB5_NAMESPACE" -l app=myapp,color=blue -w
```

### Task 3: Verify and seed data

Get the LoadBalancer URL for the main Service (give the ELB a minute to
provision):

```bash
export APP_URL="http://$(kubectl get svc myapp -n "$LAB5_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "$APP_URL"
```

Hit `/` — you should see **version v1, color blue**, and an `item_count` from
Aurora (proves Secrets Manager + IRSA + the DB connection all work):

```bash
curl -s "$APP_URL/"            # {"app":"myapp","version":"v1","color":"blue","item_count":0}
```

POST a couple of items, then list them. v1 has no concept of `priority`:

```bash
curl -s -X POST "$APP_URL/items" -H 'Content-Type: application/json' -d '{"name":"alpha"}'
curl -s -X POST "$APP_URL/items" -H 'Content-Type: application/json' -d '{"name":"beta"}'
curl -s "$APP_URL/items"       # items have id+name only (no priority field)
```

---

## Part 2: Expand the Schema (the guardrail step)

### Task 4: Run the expand migration

v2 needs a `priority` column. Add it as a **nullable, additive** column so v1
(still serving traffic) keeps working untouched. Run `migrations/001_expand.sql`
against Aurora using the Secrets Manager credentials — easiest from a throwaway
psql pod **inside the cluster** (it can reach Aurora through the worker-node
security group):

```bash
# Pull the DB credentials from Secrets Manager (the same secret the app reads).
CREDS=$(aws secretsmanager get-secret-value --secret-id "$LAB5_DB_SECRET_NAME" \
  --region "$LAB5_REGION" --query SecretString --output text)
DB_USER=$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["username"])')
DB_PASS=$(echo "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')

# Run the expand migration from a one-off psql pod in your namespace.
kubectl run psql-migrate -n "$LAB5_NAMESPACE" --rm -it --restart=Never \
  --image=public.ecr.aws/docker/library/postgres:16 \
  --env="PGPASSWORD=$DB_PASS" -- \
  psql -h "$LAB5_DB_ENDPOINT" -U "$DB_USER" -d appdb \
  -c "ALTER TABLE items ADD COLUMN IF NOT EXISTS priority INT;"
```

> Confirm blue is unaffected: `curl -s "$APP_URL/"` still returns
> `version v1` and the same `item_count`. The additive column is invisible to v1.

---

## Part 3: Deploy Green (v2), Preview, and Cut Over

### Task 5: Deploy green alongside blue

Flip `green.enabled=true`. Blue stays up and **keeps serving all traffic** — the
main Service selector is still `color=blue`. This `helm upgrade` only *adds* the
green Deployment and a green-only preview Service:

```bash
helm upgrade myapp ~/io-107/lab_5/charts/myapp \
  -n "$LAB5_NAMESPACE" \
  --reuse-values \
  --set green.enabled=true \
  --wait

kubectl get pods -n "$LAB5_NAMESPACE" -l app=myapp -L color
```

You should now see **both** blue and green pods running.

### Task 6: Preview green against live data

The `myapp-preview` Service (ClusterIP, pinned to green) lets you validate v2
**before** moving any production traffic. Port-forward to it:

```bash
kubectl port-forward -n "$LAB5_NAMESPACE" svc/myapp-preview 8081:80 &
sleep 2
curl -s http://localhost:8081/          # version v2, color green, SAME item_count
curl -s -X POST http://localhost:8081/items \
  -H 'Content-Type: application/json' -d '{"name":"gamma","priority":5}'
curl -s http://localhost:8081/items     # items now include the priority field
kill %1                                  # stop the port-forward
```

Green reads and writes `priority` while seeing the **same data** blue created —
proof the two versions coexist safely on one database.

### Task 7: Cut over to green

Flip the **main Service selector** from blue to green. This is the zero-downtime
cutover — no pods restart, the selector just starts pointing at green:

```bash
helm upgrade myapp ~/io-107/lab_5/charts/myapp \
  -n "$LAB5_NAMESPACE" \
  --reuse-values \
  --set activeColor=green \
  --wait
```

Watch the flip on the public URL:

```bash
for i in $(seq 1 5); do curl -s "$APP_URL/"; echo; sleep 1; done
# version changes from v1/blue to v2/green; item_count is unchanged (data persisted).
```

### Task 8: Rollback drill

Rolling back is just flipping the selector the other way — instant, no data loss:

```bash
helm upgrade myapp ~/io-107/lab_5/charts/myapp \
  -n "$LAB5_NAMESPACE" --reuse-values --set activeColor=blue --wait
curl -s "$APP_URL/"      # back to version v1, color blue
```

Flip it back to `green` when you're done confirming, then leave it on green.

---

## Guardrail Lesson: Why Expand/Contract

The migration in Task 4 was **additive** (`ADD COLUMN ... priority INT`). That is
the entire reason this Blue/Green worked: during the rollout, **blue (v1) and
green (v2) were both reading and writing the same `items` table at the same
time**. An additive column is invisible to v1, so blue never errored.

Had Task 4 been a **breaking** change — renaming or dropping a column v1 still
selects — blue would have started throwing errors the *instant* the migration
ran, long before you cut over. That is why zero-downtime Blue/Green against a
shared database requires **expand/contract**:

1. **Expand** — add the new (nullable/additive) schema. Both versions work.
2. **Deploy** both versions; backfill data if needed.
3. **Cut over** to the new version.
4. **Contract** — only *after* the old version is fully retired, remove the old
   columns / compat code (`migrations/002_contract.sql` — a no-op placeholder
   here, since `priority` is the column v2 keeps).

Never combine a breaking schema change with a rolling deploy.

---

## Checkpoint: Verify Your Progress

You've completed Part A when:

- [ ] `terraform apply` in `lab_5/terraform` succeeded against its **own** state.
- [ ] `curl $APP_URL/` returned a real `item_count` from Aurora (Secrets Manager + IRSA working).
- [ ] You POSTed items as v1 (no `priority`) and they persisted.
- [ ] The expand migration ran and blue was **unaffected**.
- [ ] Both blue and green pods ran at once, sharing one database.
- [ ] The preview Service showed v2 reading/writing `priority` on the same data.
- [ ] Flipping `activeColor` cut `curl $APP_URL/` from v1→v2 with the item_count unchanged.
- [ ] Flipping `activeColor=blue` rolled back instantly.

---

## Knowledge Check

1. Blue and green run the **same container image**. What actually makes one
   behave as v1 and the other as v2?
2. Why does `GET /health` deliberately **not** query the database?
3. During the rollout, both versions hit the same `items` table. Why was adding
   `priority` safe, but renaming an existing column would **not** have been?
4. The cutover changes only the main Service's `selector`. Why is that
   zero-downtime, and why is rollback effectively instant?
5. Lab 5 reads your EKS cluster with a `data` source instead of
   `terraform import`. What would go wrong if you imported the cluster into
   Lab 5's state instead?
6. The app gets its DB password from Secrets Manager via IRSA. Where is the
   password stored, and what grants the pod permission to read it?

---

## Cleanup

Lab 5 tears down independently and leaves your main environment untouched:

```bash
helm uninstall myapp -n "$LAB5_NAMESPACE"     # frees the LoadBalancer first
cd ~/io-107/lab_5/terraform
terraform destroy                              # removes Aurora, namespace, IRSA, ECR
```

---

## Next Steps

- **Part B (bonus, not yet built):** replace the two Deployments + manual
  selector flip with a single **Argo Rollouts** `Rollout` (`strategy.blueGreen`,
  preview service, one-command `promote`, instant `abort`). Same guardrail,
  automated.
- Revisit Lab 4's database-level Blue/Green (Aurora engine upgrades) and contrast
  it with this **application-level** Blue/Green — two different layers of the
  same zero-downtime idea.

---

## Resources

- [Kubernetes Services & selectors](https://kubernetes.io/docs/concepts/services-networking/service/)
- [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Aurora-managed master user passwords in Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-secrets-manager.html)
- [Expand/contract (parallel change) pattern](https://martinfowler.com/bliki/ParallelChange.html)
