# io107-lab2-sam-app

Serverless API used by **IO-107 Lab 2: Lambda Deployment with SAM**.

This repo demonstrates the production Lambda deployment pattern taught in Module 4:

1. Source push (Git) merge to `main` triggers AWS CodePipeline.
2. AWS CodeBuild runs `pytest` then `sam build` → `sam package` → `sam deploy`.
3. SAM publishes a new immutable Lambda version and updates the `live` alias.
4. The `DeploymentPreference` shifts 10% of traffic to the new version for 5 minutes.
5. If the `ApiErrorAlarm` breaches its threshold during the canary window, the deployment automatically rolls back.

---

## Repository layout

```
io107-lab2-sam-app/
├── src/
│   ├── app.py              # Lambda function code (routes on path + httpMethod)
│   └── requirements.txt    # Python dependencies (boto3 ships with runtime)
├── tests/
│   └── test_app.py         # pytest tests run in CodeBuild pre_build phase
├── template.yaml           # SAM template (Function + Alias + DeploymentPreference + Alarm)
├── buildspec.yml           # CodeBuild phases: install → pre_build → build → post_build
├── samconfig.toml          # SAM deploy defaults (stack name, region, capabilities)
├── .gitignore
└── README.md               # This file
```

---

## Prerequisites

Lab 1 must be complete. This repo reuses:

- The AWS CodePipeline + AWS CodeBuild project from Lab 1
- The S3 artifact bucket from Lab 1 (passed via `$ARTIFACT_BUCKET`)
- The CodeBuild IAM service role from Lab 1

You will also need locally (for the optional local-testing path):

- Python 3.11
- AWS SAM CLI (`pip install aws-sam-cli`)
- AWS CLI configured with credentials for the training account
- Git

---

## What the SAM template provisions

| Resource | Type | Purpose |
|----------|------|---------|
| `ApiFunction` | `AWS::Serverless::Function` | Python 3.11 Lambda, handler `app.handler` |
| `ApiFunction.Alias live` | (implicit, via `AutoPublishAlias`) | Immutable pointer callers reference instead of `$LATEST` |
| `ApiFunction.DeploymentPreference` | (implicit) | `Canary10Percent5Minutes` traffic shift with rollback alarms |
| `ApiErrorAlarm` | `AWS::CloudWatch::Alarm` | Watches `AWS/Lambda` `Errors` metric — triggers rollback |
| `ServerlessRestApi` | `AWS::ApiGateway::RestApi` (implicit) | Auto-created from the `Events` block |

Events currently registered on `ApiFunction`:

| Event name | HTTP method | Path | Handler branch |
|------------|-------------|------|----------------|
| `GetItems` | GET | `/items` | `get_items()` |
| `HealthCheck` | GET | `/health` | `health_check()` |

---

## Student modification path (Lab 2 Task 4)

Lab 2 asks students to add a `POST /items` endpoint. The change spans **two files**:

### 1. `template.yaml` — add a `CreateItem` event

Inside the `ApiFunction` `Events` block, add:

```yaml
CreateItem:
  Type: Api
  Properties:
    Path: /items
    Method: POST
```

The placeholder comment in `template.yaml` marks where this goes.

### 2. `src/app.py` — add the route branch and the `create_item` function

In the `handler` function, add a new `elif` branch:

```python
elif path == '/items' and method == 'POST':
    return create_item(event)
```

Then add the function:

```python
def create_item(event):
    try:
        body = json.loads(event.get('body', '{}'))
        name = body.get('name', 'Unnamed')
        new_item = {'id': 4, 'name': name, 'created': True}
        logger.info(f"Created item: {new_item}")
        return {
            'statusCode': 201,
            'body': json.dumps(new_item)
        }
    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'Invalid JSON'})
        }
```

Both placeholders are commented out in the starting code — uncomment and adapt rather than retyping from scratch if you prefer.

---

## Local testing

```bash
# Run unit tests
pip install pytest
PYTHONPATH=src pytest tests/ -v

# Build locally
sam build

# Invoke a single event locally
sam local invoke ApiFunction --event tests/event_get_items.json
```

---

## Deployment

You do not run `sam deploy` by hand — that is the pipeline's job. The merge into `main` triggers AWS CodePipeline, which runs `buildspec.yml` and executes `sam deploy` with the parameters configured in `samconfig.toml`.

If you ever need to deploy manually from a workstation (do not do this in production):

```bash
sam build
sam deploy --guided   # first time only
sam deploy            # subsequent deploys
```

---

## Validation

After the pipeline finishes Task 5 deploys your change, grab the API endpoint and test both routes:

```bash
API_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name io107-lab2-sam-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
  --output text)

# Existing route
curl "${API_ENDPOINT%/}/items"

# New route (added in Task 4)
curl -X POST "${API_ENDPOINT%/}/items" \
  -H "Content-Type: application/json" \
  -d '{"name": "New Item"}'
```

The `${API_ENDPOINT%/}` shell pattern strips any trailing slash defensively — the SAM-generated output does not include one, but it costs nothing to be safe.

---

## Cleanup

The CodePipeline, CodeBuild project, IAM role, and S3 artifact bucket from Lab 1 stay in place for Lab 3. If your training account is being torn down, delete the `io107-lab2-sam-app` CloudFormation stack from the AWS CloudFormation console — that removes the Lambda function, API Gateway, alarm, and the IAM execution role SAM created.

---

## References

- [AWS SAM Developer Guide](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/)
- [Lambda Versioning and Aliases](https://docs.aws.amazon.com/lambda/latest/dg/configuration-versions.html)
- [SAM Deployment Preferences (CodeDeploy traffic shifting)](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/automating-updates-to-serverless-apps.html)
- [AWS CodeBuild buildspec reference](https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html)
