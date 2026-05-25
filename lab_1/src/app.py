"""IO-107 Lab 1 sample Flask app.

Two endpoints:
  GET /health  -> {"status": "healthy"}      Used by the Helm chart liveness/readiness probes.
  GET /        -> {"caller": "<arn>", ...}   Calls sts:GetCallerIdentity to prove IRSA is wired.

The point of `/` is to give students a quick smoke test that the pod's AWS SDK
picked up the projected service-account token and exchanged it for STS
credentials via sts:AssumeRoleWithWebIdentity. If IRSA is broken, the call
fails with NoCredentialsError or an access-denied error and the JSON reports
that explicitly rather than crashing the pod.
"""

import os

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify

app = Flask(__name__)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")


@app.route("/health", methods=["GET"])
def health():
    """Liveness/readiness probe target.

    Intentionally trivial: returns 200 as long as the Flask worker is alive.
    We don't want this probe to fail on transient STS issues — that would
    cause Helm's --atomic to roll the release back for a non-app reason.
    """
    return jsonify({"status": "healthy"}), 200


@app.route("/", methods=["GET"])
def index():
    """Report the IRSA-assumed caller identity, environment, and region."""
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    response = {
        "app": "myapp",
        "environment": ENVIRONMENT,
        "region": region,
    }
    try:
        sts = boto3.client("sts", region_name=region)
        identity = sts.get_caller_identity()
        response["caller"] = identity.get("Arn")
        response["account"] = identity.get("Account")
    except (BotoCoreError, ClientError) as exc:
        # IRSA misconfigured — surface the error to the smoke test instead of 500-ing.
        response["caller"] = None
        response["irsa_error"] = str(exc)
        return jsonify(response), 200
    return jsonify(response), 200


if __name__ == "__main__":
    # Local-dev only; gunicorn is the production entrypoint (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=8080)
