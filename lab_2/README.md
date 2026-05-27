# Lab 2: Lambda Deployment with SAM

**Duration:** 45 minutes

---

## Objectives

By completing this lab, you will:

- Clone the SAM-based serverless application and walk through `template.yaml`, identifying the `AutoPublishAlias`, `DeploymentPreference`, and `ApiErrorAlarm` that make safe Lambda deployments possible.
- Add a new `POST /items` endpoint by editing both the SAM template and the Python handler.
- Push the change and observe AWS CodePipeline run the full `sam build` → `sam package` → `sam deploy` flow in CodeBuild, with `sam deploy` driving CloudFormation to create the Lambda function, API Gateway, and CodeDeploy canary deployment.
- Observe traffic shifting between Lambda versions on the `live` alias during the canary window, then verify both endpoints by invoking them via the API Gateway URL.

---

## Prerequisites

Before starting this lab, ensure you have:

- [ ] Lab 1 completed (you understand the per-student bootstrap, CodeCommit, and CodePipeline mechanics)
- [ ] Your per-student bootstrap is applied for Lab 2 (`enable_lab2=true`) — your `LAB2_*` env vars are non-empty
- [ ] AWS CLI v2 + `git` installed on your lab workstation
- [ ] Lab instructions document open (this guide)

**Course Repository:** **[https://github.com/roi-cloud-fun/io-107](https://github.com/roi-cloud-fun/io-107)** — contains the upstream lab fixtures. Your per-student CodeCommit repo was seeded from the `lab_2/` subdirectory.

From the `lab_environment/lab_env_student/` directory, capture your env vars (if you didn't already in Lab 1):

```bash
eval "$(terraform output -json | jq -r '
  to_entries[] | select(.value.value != "(disabled)") |
  "export \(.key | ascii_upcase)=\"\(.value.value)\""
')"

echo "CodeCommit:  $LAB2_CODECOMMIT_CLONE_URL"
echo "Pipeline:    $LAB2_PIPELINE_NAME"
```

> **Note:** Lab 1 already provisioned the shared resources (CodePipeline service role, CodeBuild service role, KMS keys). Lab 2 reuses them. The Lab 2 bootstrap adds the per-student CodeCommit repo, CodeBuild project, and S3 artifact bucket specific to this lab.

---

## Part 1: Inspect the Serverless Application

### Task 1: Clone Your Per-Student Repository

1. Open your terminal. Confirm `$LAB2_CODECOMMIT_CLONE_URL` is set (`echo` it). Then clone:

    ```bash
    git clone "$LAB2_CODECOMMIT_CLONE_URL" lab2-sam-app
    cd lab2-sam-app
    ```

2. Confirm you are on `main` — that's the branch your CodePipeline source action watches. Do not create a feature branch for this lab:

    ```bash
    git branch --show-current
    ```

    **Expected Result:** `main`. If anything else, switch back with `git checkout main`.

    > **Note:** In production at [Client], the workflow is feature-branch → PR → review → merge to `main` → pipeline fires. This lab compresses that to a direct push to `main` for simplicity. Don't carry the direct-push pattern into prod — the lab teaches pipeline mechanics, not the change-management workflow that wraps them.

3. List the repository contents:

    ```bash
    ls -la
    ```

    **Expected Result:**

    ```
    lab2-sam-app/
    ├── src/
    │   ├── app.py              # Lambda function code
    │   └── requirements.txt    # Python dependencies
    ├── template.yaml           # SAM template
    ├── buildspec.yml           # Pipeline configuration
    ├── samconfig.toml          # SAM deployment config
    └── README.md
    ```

---

### Task 2: Read the SAM Template

4. Open `template.yaml` in your editor. Locate the `Transform` line at the top:

    ```yaml
    AWSTemplateFormatVersion: '2010-09-09'
    Transform: AWS::Serverless-2016-10-31
    Description: IO-107 Lab 2 - Serverless API
    ```

    This `Transform` line is what makes it a SAM template rather than a raw CloudFormation template — SAM macros expand at deploy time into the lower-level CFN resources (Lambda, IAM, API Gateway, CodeDeploy).

5. Locate the `Globals` block. This sets defaults for every Lambda function in the template:

    ```yaml
    Globals:
      Function:
        Timeout: 30
        Runtime: python3.11
        MemorySize: 256
        Environment:
          Variables:
            ENVIRONMENT: !Ref Environment
            LOG_LEVEL: !Ref LogLevel
    ```

6. Locate the `ApiFunction` resource and identify the four key properties:

    - **AutoPublishAlias:** `live` — SAM creates an alias named `live` and updates it automatically on each deploy.
    - **DeploymentPreference Type:** `Canary10Percent5Minutes` — 10% of traffic shifts to the new version for 5 minutes, then 100%.
    - **Events:** Two API events (`GetItems` on `GET /items`, `HealthCheck` on `GET /health`).
    - **DeploymentPreference Alarms:** References `ApiErrorAlarm` so the deployment rolls back automatically if the error metric breaches the threshold during the canary window.

7. Locate the `ApiErrorAlarm` resource further down. This CloudWatch alarm watches the function's `Errors` metric:

    ```yaml
    ApiErrorAlarm:
      Type: AWS::CloudWatch::Alarm
      Properties:
        MetricName: Errors
        Namespace: AWS/Lambda
        Statistic: Sum
        Period: 60
        EvaluationPeriods: 1
        Threshold: 5
        ComparisonOperator: GreaterThanThreshold
    ```

> **Key Insight:** The template wires together three things that make safe Lambda deployments possible: an alias (`live`) that callers reference instead of `$LATEST`, a deployment preference that shifts traffic gradually, and a CloudWatch alarm that triggers automatic rollback. This is the pattern used for every production Lambda.

---

### Task 3: Read the Function Code

8. Open `src/app.py` and read the existing `handler` function:

    ```python
    import json
    import os
    import logging

    logger = logging.getLogger()
    logger.setLevel(os.environ.get('LOG_LEVEL', 'INFO'))

    def handler(event, context):
        path = event.get('path', '')
        method = event.get('httpMethod', '')
        logger.info(f"Request: {method} {path}")

        if path == '/health':
            return health_check()
        elif path == '/items' and method == 'GET':
            return get_items()
        else:
            return {
                'statusCode': 404,
                'body': json.dumps({'error': 'Not found'})
            }
    ```

9. Note that the handler routes on `event['path']` and `event['httpMethod']`. The next task will add a third branch for `POST /items`.

---

## Part 2: Add a New API Endpoint

### Task 4: Edit the SAM Template and Handler

10. Edit `template.yaml`. Add a new `CreateItem` event inside the `ApiFunction` `Events` block:

    ```yaml
    Events:
      GetItems:
        Type: Api
        Properties:
          Path: /items
          Method: GET
      CreateItem:
        Type: Api
        Properties:
          Path: /items
          Method: POST
      HealthCheck:
        Type: Api
        Properties:
          Path: /health
          Method: GET
    ```

11. Edit `src/app.py`. Add the `POST /items` route plus a `create_item` function:

    ```python
    def handler(event, context):
        path = event.get('path', '')
        method = event.get('httpMethod', '')
        logger.info(f"Request: {method} {path}")

        if path == '/health':
            return health_check()
        elif path == '/items' and method == 'GET':
            return get_items()
        elif path == '/items' and method == 'POST':
            return create_item(event)
        else:
            return {
                'statusCode': 404,
                'body': json.dumps({'error': 'Not found'})
            }

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

12. Save both files. Do not commit yet — the next task triggers the pipeline.

> **Note:** The handler dispatches on `path` and `httpMethod`. If you add more routes later, follow the same `elif` pattern rather than introducing a routing library — keeps the cold-start footprint small.

---

## Part 3: Trigger and Observe the Pipeline

### Task 5: Commit and Push

13. Stage both modified files:

    ```bash
    git add template.yaml src/app.py
    ```

14. Commit and push directly to `main`:

    ```bash
    git commit -m "Add POST /items endpoint for creating items"
    git push origin main
    ```

    > **Note:** The EventBridge rule the bootstrap created triggers your pipeline within a few seconds of the push.

---

### Task 6: Watch the Pipeline Stages

15. Open the AWS CodePipeline console and select your pipeline (`$LAB2_PIPELINE_NAME`). Watch the stages execute:

    - **Source** — pulls the latest commit from `main` of your CodeCommit repo.
    - **Build** — runs the buildspec's full lifecycle (`install` → `pre_build` → `build` → `post_build`) in AWS CodeBuild. **`sam deploy` runs as `post_build`** — there is no separate Deploy stage.

16. Click into the Build stage and open the CodeBuild logs. Watch the buildspec phases execute in this order:

    ```yaml
    phases:
      install:
        runtime-versions:
          python: 3.11
        commands:
          - pip install --upgrade pip
          - pip install aws-sam-cli
          - pip install pytest
          - pip install -r src/requirements.txt || true
      pre_build:
        commands:
          - pytest tests/ -v
      build:
        commands:
          - sam build
          - sam package \
              --output-template-file packaged.yaml \
              --s3-bucket $ARTIFACT_BUCKET
      post_build:
        commands:
          - sam deploy \
              --template-file packaged.yaml \
              --stack-name $STACK_NAME \
              --capabilities CAPABILITY_IAM \
              --parameter-overrides Environment=$ENVIRONMENT \
              --no-fail-on-empty-changeset
    ```

    > **Note:** `pre_build` runs the `pytest` suite as a gate — a test failure aborts the build before `sam deploy` runs. `--no-fail-on-empty-changeset` prevents a re-run from failing when the changeset is empty. `--capabilities CAPABILITY_IAM` is required because SAM creates IAM roles for the Lambda function.

> **What Just Happened?** A single Git push moved a serverless application change through unit tests, packaging to S3, CloudFormation change-set creation, and a CodeDeploy-managed canary rollout — all without anyone touching the Lambda console.

---

## Part 4: Observe Canary Traffic Shifting

### Task 7: Watch the Live Alias Weights

17. Capture the per-student stack name and the function name into shell variables (the SAM stack name is per-student, set by the bootstrap as `STACK_NAME`):

    ```bash
    SAM_STACK_NAME=$(aws cloudformation list-stacks \
        --query "StackSummaries[?starts_with(StackName,'io107-') && ends_with(StackName,'-lab2-sam-app') && StackStatus!='DELETE_COMPLETE'].StackName | [0]" \
        --output text)
    echo "Stack: $SAM_STACK_NAME"

    FUNCTION_NAME=$(aws cloudformation describe-stack-resource \
        --stack-name "$SAM_STACK_NAME" \
        --logical-resource-id ApiFunction \
        --query 'StackResourceDetail.PhysicalResourceId' \
        --output text)
    echo "Function: $FUNCTION_NAME"
    ```

18. Open the AWS Lambda console, navigate to **Functions**, and click the function named in `$FUNCTION_NAME`. Click the **Aliases** tab, then click the **live** alias.

19. Look at the **Weights** section. Timing depends on when you arrive relative to the canary window:

    **During the 5-minute canary window:**
    ```
    Version 2: 10%
    Version 1: 90%
    ```

    **After the canary completes:**
    ```
    Version 2: 100%
    ```

    > **Common Pitfall:** Refreshing the page during the canary might show 100% if you arrive late. To replay the canary, push another trivial code change to trigger a new deployment.

> **Key Insight:** AWS SAM published an immutable version of your function code and shifted traffic to it gradually. If the `ApiErrorAlarm` had breached its threshold during those 5 minutes, the deployment preference would have automatically routed all traffic back to the previous version. No human intervention required — that's the safety net.

---

## Part 5: Test the Endpoints

### Task 8: Invoke Both Endpoints

20. Retrieve the API Gateway endpoint URL from the CloudFormation stack outputs:

    ```bash
    API_ENDPOINT=$(aws cloudformation describe-stacks \
      --stack-name "$SAM_STACK_NAME" \
      --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
      --output text)
    echo "$API_ENDPOINT"
    ```

21. Test the existing `GET /items` endpoint. The SAM-generated `ApiEndpoint` output does not include a trailing slash; the `${API_ENDPOINT%/}` shell pattern below strips one defensively:

    ```bash
    curl "${API_ENDPOINT%/}/items"
    ```

    **Expected Result:**

    ```json
    {"items": [{"id": 1, "name": "Item 1"}, {"id": 2, "name": "Item 2"}, {"id": 3, "name": "Item 3"}]}
    ```

22. Test your new `POST /items` endpoint:

    ```bash
    curl -X POST "${API_ENDPOINT%/}/items" \
      -H "Content-Type: application/json" \
      -d '{"name": "New Item"}'
    ```

    **Expected Result:**

    ```json
    {"id": 4, "name": "New Item", "created": true}
    ```

    > **Troubleshooting:** If the POST returns 502 or 500, open **CloudWatch Logs > Log groups > /aws/lambda/$FUNCTION_NAME** and read the most recent log stream for a Python traceback. Usually a `json.JSONDecodeError` because the request body is empty or malformed.

---

### Task 9: Inspect the Alias from the CLI (Reference)

23. Retrieve the current alias configuration:

    ```bash
    aws lambda get-alias \
      --function-name "$FUNCTION_NAME" \
      --name live
    ```

24. Note the `FunctionVersion` field. If the canary completed cleanly, this is the new version (e.g. `2`). If a rollback occurred, it will be the previous version (e.g. `1`).

> **Note:** Don't run `aws lambda update-alias` manually in production. The `DeploymentPreference` in the SAM template manages alias updates and rollbacks. The CLI command above is shown so you understand the underlying mechanism — not as an operational tool.

---

## Checkpoint: Verify Your Progress

Before finishing, confirm you have completed:

- [ ] Cloned the per-student CodeCommit repo and confirmed the SAM project structure
- [ ] Identified `Transform: AWS::Serverless-2016-10-31` in `template.yaml`
- [ ] Located the `AutoPublishAlias`, `DeploymentPreference`, and `Alarms` properties on `ApiFunction`
- [ ] Located `ApiErrorAlarm` and understood its role in automatic rollback
- [ ] Added a `CreateItem` event for `POST /items` to `template.yaml`
- [ ] Added the `create_item` handler and route branch to `src/app.py`
- [ ] Committed and pushed to `main`, triggering the pipeline
- [ ] Observed Source and Build stages complete in AWS CodePipeline
- [ ] Reviewed the CodeBuild log and confirmed `sam build`, `sam package`, and `sam deploy` all ran successfully
- [ ] Captured `$SAM_STACK_NAME` and `$FUNCTION_NAME` for later commands
- [ ] Inspected the `live` alias on the Lambda console and saw weighted traffic shifting
- [ ] Successfully invoked `GET /items` against the API Gateway endpoint
- [ ] Successfully invoked `POST /items` and received a 201 response
- [ ] Retrieved the alias configuration via `aws lambda get-alias` and confirmed `FunctionVersion`

---

## Troubleshooting Reference

| Issue | Symptom | Solution |
|-------|---------|----------|
| `sam build` fails with missing-package error | CodeBuild log shows `ModuleNotFoundError` during install or build | Add the missing package to `src/requirements.txt`, commit, push. |
| `sam package` fails with `--resolve-s3 and --s3-bucket` conflict | `Error: Cannot use both --resolve-s3 and --s3-bucket parameters` | Confirm `samconfig.toml` doesn't have `resolve_s3 = true` in `[default.deploy.parameters]` or `[default.package.parameters]`. The buildspec explicitly passes `--s3-bucket $ARTIFACT_BUCKET`; the two conflict. |
| Stack is in `ROLLBACK_FAILED` | `sam deploy` errors with "stack is in ROLLBACK_FAILED state" | Manually delete via `aws cloudformation delete-stack --stack-name "$SAM_STACK_NAME" --retain-resources <stuck-resource>`, then re-deploy. |
| CodeDeploy `AccessDenied` during stack create | `User ... not authorized to perform: codedeploy:CreateApplication` | CodeBuild service role missing `codedeploy:*` perms. Re-run `terraform apply` to refresh the inline policy. |
| Lambda alias never gets weights | Console shows `live` → version directly, no traffic weights | You may have missed the 5-minute canary window. Push another trivial change to trigger a new deployment. |
| API Gateway returns 500 on POST | Pod logs show Python traceback | JSON parse error in `create_item` — re-send the request with `-H "Content-Type: application/json"` and a valid JSON body. |
| Pipeline fails with "CAPABILITY_IAM" | CFN says it cannot create IAM resources | Confirm `sam deploy` in `buildspec.yml` includes `--capabilities CAPABILITY_IAM`. |
| `sam deploy` reports "no changes" and pipeline fails | Empty changeset error | The `--no-fail-on-empty-changeset` flag should prevent this; confirm it's in `buildspec.yml`. |

---

## Cost Considerations

| Component | Type | Approximate Cost |
|-----------|------|------------------|
| AWS Lambda invocations (lab traffic) | Requests + GB-seconds | Negligible — well under free tier |
| API Gateway requests (lab traffic) | REST API requests | Negligible — well under free tier |
| AWS CodeBuild build minutes | `general1.small` Linux | A few cents per pipeline run |
| AWS CodePipeline | Active pipeline | $1.00 per active pipeline per month (pro-rated) |
| CloudWatch Logs storage | Function + build logs | Negligible for lab duration |
| **Total (this lab, ~45 min)** | | **<$0.05** |

<!-- source: https://aws.amazon.com/lambda/pricing/ + https://aws.amazon.com/api-gateway/pricing/ + https://aws.amazon.com/codepipeline/pricing/ verified 2026-04-07 -->

**Cleanup:** The CodePipeline, CodeBuild project, IAM roles, and S3 artifact bucket from your Lab 2 bootstrap stay in place between cohorts. To release just the per-student SAM stack (Lambda function, API Gateway, alarm, CodeDeploy resources) the pipeline deployed:

```bash
aws cloudformation delete-stack --stack-name "$SAM_STACK_NAME" --region us-east-1
```

Leave everything else alone — `terraform destroy` from `lab_env_student/` at end-of-cohort is what removes the bootstrap infrastructure.

---

## Knowledge Check

**Question 1:** In the SAM template, the `AutoPublishAlias: live` property triggers two automatic behaviors on each deploy. What are they?
<!-- source: Module_4_narrative.md §"Section 3: Traffic Shifting and Auto-Rollback" -->

**Question 2:** Production Lambda deployments standardize on `Canary10Percent5Minutes`. Why is this preferred over `AllAtOnce`?
<!-- source: Module_4_narrative.md §"Section 3: Traffic Shifting and Auto-Rollback" -->

**Question 3:** What is the difference between `$LATEST` and a published Lambda version, and why should event sources reference an alias rather than `$LATEST`?
<!-- source: Module_4_narrative.md §"Section 2: Lambda Versioning and Aliases" -->

**Question 4:** During the canary window, the `ApiErrorAlarm` breaches its threshold. What happens to the traffic weights on the `live` alias, and who (or what) performs the rollback?
<!-- source: Lab_2_narrative.md §"Section 2: Review the SAM Template" + Module_4_narrative.md §"Section 2: Lambda Versioning and Aliases" -->

**Question 5:** The standard is to use AWS SAM rather than raw CloudFormation for Lambda deployments. Name two SAM features that justify this choice.
<!-- source: Module_4_narrative.md §"Section 1: AWS SAM Deployments" + facts_extracted_v2.md §"SAM (Serverless Application Model)" -->

*Answers are in the Knowledge Check Bank.*

---

## Next Steps

In **Lab 3: Policy-as-Code Evaluation and Failure Remediation**, you'll deploy a Terraform template that intentionally violates the OPA policies, observe the pipeline halt at the Validate stage, read the Conftest output, and remediate each violation. The pipeline shape extends to Source → Build → **Validate (OPA)** → Approval → Deploy.

---

## Resources

- [AWS SAM Developer Guide](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/)
- [AWS Lambda Deployment Guide](https://docs.aws.amazon.com/lambda/latest/dg/deploying-lambda-apps.html)
- [Lambda Versioning and Aliases](https://docs.aws.amazon.com/lambda/latest/dg/configuration-versions.html)
- [AWS CodePipeline User Guide](https://docs.aws.amazon.com/codepipeline/latest/userguide/)
- [AWS CodeBuild User Guide](https://docs.aws.amazon.com/codebuild/latest/userguide/)
- [CloudWatch Logs for Lambda](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-cloudwatchlogs.html)

---

*Lab 2 Complete*
