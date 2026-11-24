"""FormFlow backend (middle tier).

Small Flask API. It is the only service that talks to the database.
Every secret and setting comes from environment variables, nothing is hardcoded.
"""
import os
import time
from contextlib import closing

import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

# The image tag (for example sha-a1b2c3d) is baked into the image at build time.
APP_VERSION = os.environ.get("APP_VERSION", "unknown")


def get_conn():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=3,
    )


def init_db():
    """Create the table if it is missing. Retry while the database wakes up."""
    for _ in range(30):
        try:
            with closing(get_conn()) as conn, conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        CREATE TABLE IF NOT EXISTS submissions (
                            id SERIAL PRIMARY KEY,
                            name TEXT NOT NULL,
                            email TEXT NOT NULL,
                            message TEXT NOT NULL,
                            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                        )
                        """
                    )
            return
        except psycopg2.OperationalError:
            time.sleep(2)
    raise RuntimeError("Database is not reachable after 60 seconds")


init_db()


@app.get("/api/version")
def version():
    return jsonify(version=APP_VERSION)


@app.get("/api/health")
def health():
    """Health check that really touches the database, not just 'the app is up'."""
    try:
        with closing(get_conn()) as conn, conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return jsonify(status="ok", database="up", version=APP_VERSION), 200
    except Exception:
        return jsonify(status="error", database="down", version=APP_VERSION), 503


@app.post("/api/submissions")
def create_submission():
    data = request.get_json(silent=True) or {}
    name = str(data.get("name", "")).strip()
    email = str(data.get("email", "")).strip()
    message = str(data.get("message", "")).strip()

    if not name or not email or not message:
        return jsonify(error="name, email and message are all required"), 400
    if len(name) > 100 or len(email) > 200 or len(message) > 2000:
        return jsonify(error="one of the fields is too long"), 400

    with closing(get_conn()) as conn, conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO submissions (name, email, message) VALUES (%s, %s, %s) RETURNING id",
                (name, email, message),
            )
            new_id = cur.fetchone()[0]
    return jsonify(id=new_id), 201


@app.get("/api/submissions")
def list_submissions():
    with closing(get_conn()) as conn, conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, name, email, message, created_at "
                "FROM submissions ORDER BY id DESC LIMIT 20"
            )
            rows = cur.fetchall()
    return jsonify(
        [
            {
                "id": r[0],
                "name": r[1],
                "email": r[2],
                "message": r[3],
                "created_at": r[4].isoformat(),
            }
            for r in rows
        ]
    )
