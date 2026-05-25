def handler(event, context):
    """Minimal placeholder. Lab 3 never invokes this — the OPA Validate stage
    blocks the deployment before any Lambda is published. Code lives here only
    so `archive_file` can build a non-empty zip during `terraform plan`."""
    return {"statusCode": 200, "body": "ok"}
