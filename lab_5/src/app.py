"""IO-107 Lab 5 — "items" API on Aurora PostgreSQL.

One container image, two behaviors, gated by environment variables:

  * Blue (v1):  APP_VERSION=v1, ENABLE_PRIORITY=false, COLOR=blue
  * Green (v2): APP_VERSION=v2, ENABLE_PRIORITY=true,  COLOR=green

Both Deployments run the SAME image and hit the SAME Aurora cluster at once —
that is the whole point of the manual Blue/Green capstone. v2 reads/writes the
`priority` column; v1 ignores it. Because the schema change is *additive*
(expand/contract), blue keeps working the instant green migrates.

DB credentials come from AWS Secrets Manager. Aurora's managed master-user
secret (manage_master_user_password = true) is fetched with boto3 via IRSA, then
psycopg connects. The Aurora-managed secret reliably carries only
{"username","password"} (sometimes host/port/dbname too), so we ALSO accept
DB_HOST / DB_NAME / DB_PORT from the environment as a fallback.

Endpoints:
  GET  /health  -> {"status":"healthy"}        Probe target; never touches the DB.
  GET  /        -> {"app","version","color","item_count"}   Smoke test (DB count).
  GET  /items   -> list of items; includes `priority` only when ENABLE_PRIORITY.
  POST /items   -> insert {name, priority?}; v1 ignores priority, v2 writes it.
"""

import json
import os

import boto3
import psycopg
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v1")
COLOR = os.environ.get("COLOR", "blue")
# Treat anything other than an explicit truthy string as false.
ENABLE_PRIORITY = os.environ.get("ENABLE_PRIORITY", "false").lower() in ("1", "true", "yes")

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
DB_SECRET_NAME = os.environ.get("DB_SECRET_NAME", "")
# Fallbacks for fields Aurora's managed secret may omit.
DB_HOST_ENV = os.environ.get("DB_HOST", "")
DB_NAME_ENV = os.environ.get("DB_NAME", "appdb")
DB_PORT_ENV = os.environ.get("DB_PORT", "5432")


def _fetch_db_config():
    """Read the Aurora master-user secret from Secrets Manager and merge env fallbacks.

    Returns a dict with host, port, dbname, user, password. Raises on failure so
    the caller can surface the error in the JSON response rather than 500-ing.
    """
    client = boto3.client("secretsmanager", region_name=REGION)
    resp = client.get_secret_value(SecretId=DB_SECRET_NAME)
    secret = json.loads(resp["SecretString"])
    return {
        "host": secret.get("host") or DB_HOST_ENV,
        "port": secret.get("port") or DB_PORT_ENV,
        "dbname": secret.get("dbname") or DB_NAME_ENV,
        "user": secret.get("username"),
        "password": secret.get("password"),
    }


def _connect():
    """Open a short-lived psycopg connection using Secrets Manager creds."""
    cfg = _fetch_db_config()
    return psycopg.connect(
        host=cfg["host"],
        port=cfg["port"],
        dbname=cfg["dbname"],
        user=cfg["user"],
        password=cfg["password"],
        connect_timeout=5,
    )


def _ensure_table(conn):
    """Create the items table if it doesn't exist.

    Ship the table WITH `priority` so a fresh install works for both v1 and v2.
    The README's "expand" step (ALTER TABLE ... ADD COLUMN IF NOT EXISTS priority)
    is the demo narrative for migrating an *already-populated* v1 database.
    """
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS items ("
            "id SERIAL PRIMARY KEY, "
            "name TEXT NOT NULL, "
            "priority INT)"
        )
    conn.commit()


@app.route("/health", methods=["GET"])
def health():
    """Liveness/readiness probe. Intentionally never touches the DB so a transient
    Aurora hiccup doesn't flap the pods and trigger a needless rollout/rollback."""
    return jsonify({"status": "healthy"}), 200


@app.route("/", methods=["GET"])
def index():
    """Smoke test: version + color + a live item count from Aurora.

    A `curl` loop against this endpoint literally shows the version flip
    (v1 -> v2) the moment the Service selector cuts over, while item_count
    proves the data persisted across the switch.
    """
    response = {"app": "myapp", "version": APP_VERSION, "color": COLOR}
    try:
        with _connect() as conn:
            _ensure_table(conn)
            with conn.cursor() as cur:
                cur.execute("SELECT count(*) FROM items")
                response["item_count"] = cur.fetchone()[0]
    except (BotoCoreError, ClientError, psycopg.Error, KeyError, ValueError) as exc:
        # Same pattern as Lab 1: surface the error in JSON with 200 so the smoke
        # test reports the problem instead of the probe killing the pod.
        response["item_count"] = None
        response["db_error"] = str(exc)
    return jsonify(response), 200


@app.route("/items", methods=["GET"])
def list_items():
    """List items. v2 (ENABLE_PRIORITY) includes the priority field; v1 omits it
    entirely — the backward-compatible read behavior that lets blue and green
    share one database."""
    try:
        with _connect() as conn:
            _ensure_table(conn)
            with conn.cursor() as cur:
                if ENABLE_PRIORITY:
                    cur.execute("SELECT id, name, priority FROM items ORDER BY id")
                    items = [
                        {"id": r[0], "name": r[1], "priority": r[2]}
                        for r in cur.fetchall()
                    ]
                else:
                    cur.execute("SELECT id, name FROM items ORDER BY id")
                    items = [{"id": r[0], "name": r[1]} for r in cur.fetchall()]
        return jsonify({"version": APP_VERSION, "items": items}), 200
    except (BotoCoreError, ClientError, psycopg.Error, KeyError, ValueError) as exc:
        return jsonify({"version": APP_VERSION, "items": [], "db_error": str(exc)}), 200


@app.route("/items", methods=["POST"])
def add_item():
    """Insert an item. v1 ignores any supplied priority; v2 writes it."""
    payload = request.get_json(silent=True) or {}
    name = payload.get("name")
    if not name:
        return jsonify({"error": "field 'name' is required"}), 400
    priority = payload.get("priority")
    try:
        with _connect() as conn:
            _ensure_table(conn)
            with conn.cursor() as cur:
                if ENABLE_PRIORITY:
                    cur.execute(
                        "INSERT INTO items (name, priority) VALUES (%s, %s) RETURNING id",
                        (name, priority),
                    )
                else:
                    # v1 is unaware of priority — insert name only.
                    cur.execute(
                        "INSERT INTO items (name) VALUES (%s) RETURNING id",
                        (name,),
                    )
                new_id = cur.fetchone()[0]
            conn.commit()
        item = {"id": new_id, "name": name}
        if ENABLE_PRIORITY:
            item["priority"] = priority
        return jsonify({"version": APP_VERSION, "item": item}), 201
    except (BotoCoreError, ClientError, psycopg.Error, KeyError, ValueError) as exc:
        return jsonify({"version": APP_VERSION, "db_error": str(exc)}), 200


if __name__ == "__main__":
    # Local-dev only; gunicorn is the production entrypoint (see Dockerfile CMD).
    app.run(host="0.0.0.0", port=8080)
