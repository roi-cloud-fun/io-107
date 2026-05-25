# io107-lab1-eks-app

Sample Flask application + Helm chart used by **IO-107 Lab 1: End-to-End EKS Deployment Pipeline**.

This repo demonstrates the standard SDLC pattern taught in the course:

1. Source push (Git) →
2. AWS CodePipeline triggers AWS CodeBuild →
3. CodeBuild builds the container image, pushes it to Amazon ECR →
4. CodeBuild runs `helm upgrade --install --atomic` against the training Amazon EKS cluster →
5. Pods come up with IRSA-bound AWS credentials (no static keys).

---

## Repository layout

```
io107-lab1-eks-app/
├── src/                        # Flask application source code
│   ├── app.py                  # /, /health endpoints; demonstrates IRSA via STS
│   └── requirements.txt        # flask, gunicorn, boto3
├── charts/
│   └── myapp/
│       ├── Chart.yaml          # Helm chart metadata
│       ├── values.yaml         # Base values (no env-specific overrides)
│       ├── values-dev.yaml     # Dev environment overrides (1 replica → bumped to 2 in lab)
│       ├── values-stg.yaml     # Stg environment overrides (3 replicas)
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           └── _helpers.tpl
├── Dockerfile                  # Python 3.12-slim → gunicorn
├── buildspec.yml               # CodeBuild build → ECR push → helm upgrade
└── README.md                   # This file
```

---

## Prerequisites

Before this lab runs end-to-end, the platform team must have provisioned:

- An Amazon EKS training cluster with an OIDC provider and IRSA enabled.
- The IAM role `myapp-dev-role` whose trust policy scopes assumption to `system:serviceaccount:lab1:myapp-sa`.
- An Amazon ECR repository named `myapp` in the same region.
- An AWS CodeCommit (or GitHub) repository containing this code, wired to AWS CodePipeline.
- An AWS CodeBuild project consuming `buildspec.yml`, with the CodeBuild service role granted permission for ECR push, EKS API access, and `kubectl` against the cluster.

The Lab 1 guide walks students through observing those pieces — it does not provision them.

---

## What students do in Lab 1

1. Clone this repository.
2. Read `buildspec.yml` to understand each pipeline phase.
3. Inspect `charts/myapp/values.yaml` and `values-dev.yaml` to see the IRSA annotation wiring.
4. Edit `values-dev.yaml` to change `replicaCount` from `1` to `2`, then commit and push.
5. Observe AWS CodePipeline, AWS CodeBuild, and Amazon EKS deploy the change.
6. Verify pods, the LoadBalancer service, and that `aws s3 ls` from inside the pod works (proves IRSA is wired correctly).

See `courses/SYF/stream2_aws_intermediate/IO-107_SDLC_Pipeline/content/labs/Lab_1_Guide.md` for the step-by-step.

---

## Local sanity checks (optional)

```bash
# Render the chart with the dev values to confirm the templates parse:
helm template charts/myapp \
  -f charts/myapp/values-dev.yaml \
  --set image.tag=test123

# Build the image locally:
docker build -t myapp:local .

# Run the container and hit /health:
docker run --rm -p 8080:8080 myapp:local &
curl http://localhost:8080/health
# {"status": "healthy"}
```

---

## Environment variables consumed by the container

| Variable | Set by | Purpose |
|----------|--------|---------|
| `AWS_REGION` | EKS pod (default region) | Region for `boto3` clients |
| `AWS_ROLE_ARN` | IRSA admission webhook | Injected by EKS when the ServiceAccount has `eks.amazonaws.com/role-arn` |
| `AWS_WEB_IDENTITY_TOKEN_FILE` | IRSA admission webhook | Path to the projected service-account token |
| `ENVIRONMENT` | Helm `values-<env>.yaml` | Reported by `/` as `environment` |
