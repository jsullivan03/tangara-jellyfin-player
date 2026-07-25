import os
import re
import sqlite3
import time
from pathlib import Path

import requests
from flask import Blueprint, jsonify, request

JELLYFIN_URL = os.environ.get(
    "JELLYFIN_URL",
    "http://host.docker.internal:8096",
).rstrip("/")

DATABASE_FILE = Path(
    os.environ.get(
        "TANGARA_DATABASE_FILE",
        "/data/tangara-sync.db",
    )
)

device_links = Blueprint(
    "device_links",
    __name__,
)


def database_connection():
    connection = sqlite3.connect(DATABASE_FILE)
    connection.row_factory = sqlite3.Row
    return connection


def initialize_database():
    DATABASE_FILE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with database_connection() as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY,
                jellyfin_user_id TEXT,
                jellyfin_user_name TEXT,
                jellyfin_access_token TEXT,
                quick_connect_code TEXT,
                quick_connect_secret TEXT,
                quick_connect_created_at INTEGER,
                linked_at INTEGER,
                updated_at INTEGER NOT NULL
            )
            """
        )

    try:
        os.chmod(DATABASE_FILE, 0o600)
    except OSError:
        pass


initialize_database()


def valid_device_id(device_id):
    return bool(
        re.fullmatch(
            r"[A-Za-z0-9._:-]{1,128}",
            device_id,
        )
    )


def get_device(device_id):
    with database_connection() as connection:
        return connection.execute(
            "SELECT * FROM devices WHERE device_id = ?",
            (device_id,),
        ).fetchone()


def linked_device_count():
    with database_connection() as connection:
        row = connection.execute(
            """
            SELECT COUNT(*) AS count
            FROM devices
            WHERE jellyfin_access_token IS NOT NULL
            """
        ).fetchone()

    return int(row["count"])


def save_quick_connect(
    device_id,
    code,
    secret,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            INSERT INTO devices (
                device_id,
                quick_connect_code,
                quick_connect_secret,
                quick_connect_created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                quick_connect_code = excluded.quick_connect_code,
                quick_connect_secret = excluded.quick_connect_secret,
                quick_connect_created_at = excluded.quick_connect_created_at,
                updated_at = excluded.updated_at
            """,
            (
                device_id,
                code,
                secret,
                now,
                now,
            ),
        )


def save_linked_user(
    device_id,
    user_id,
    user_name,
    access_token,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            INSERT INTO devices (
                device_id,
                jellyfin_user_id,
                jellyfin_user_name,
                jellyfin_access_token,
                linked_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                jellyfin_user_id = excluded.jellyfin_user_id,
                jellyfin_user_name = excluded.jellyfin_user_name,
                jellyfin_access_token = excluded.jellyfin_access_token,
                quick_connect_code = NULL,
                quick_connect_secret = NULL,
                quick_connect_created_at = NULL,
                linked_at = excluded.linked_at,
                updated_at = excluded.updated_at
            """,
            (
                device_id,
                user_id,
                user_name,
                access_token,
                now,
                now,
            ),
        )


def clear_pending_link(device_id):
    with database_connection() as connection:
        connection.execute(
            """
            UPDATE devices
            SET quick_connect_code = NULL,
                quick_connect_secret = NULL,
                quick_connect_created_at = NULL,
                updated_at = ?
            WHERE device_id = ?
            """,
            (
                int(time.time()),
                device_id,
            ),
        )


def quick_connect_headers(device_id):
    return {
        "Authorization": (
            'MediaBrowser '
            'Client="Tangara Sync", '
            'Device="Tangara Player", '
            f'DeviceId="{device_id}", '
            'Version="0.2.0"'
        ),
        "Accept": "application/json",
    }


def device_link_payload(row):
    if row is None:
        return {
            "linked": False,
            "pending": False,
        }

    linked = bool(row["jellyfin_access_token"])
    pending = bool(row["quick_connect_secret"])

    payload = {
        "linked": linked,
        "pending": pending,
    }

    if linked:
        payload["user"] = {
            "id": row["jellyfin_user_id"],
            "name": row["jellyfin_user_name"],
        }

    if pending:
        payload["code"] = row["quick_connect_code"]
        payload["started_at"] = (
            row["quick_connect_created_at"]
        )

    return payload


def device_authentication(
    device_id,
    fallback_token,
    fallback_user_id,
):
    row = get_device(device_id)

    if row and row["jellyfin_access_token"]:
        return {
            "token": row["jellyfin_access_token"],
            "user_id": row["jellyfin_user_id"],
            "source": "linked_user",
        }

    return {
        "token": fallback_token,
        "user_id": fallback_user_id,
        "source": "service_user",
    }


@device_links.post(
    "/devices/<device_id>/link/start"
)
def start_device_link(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    force = request.args.get(
        "force",
        "",
    ).lower() in {"1", "true", "yes"}

    row = get_device(device_id)

    if (
        row
        and row["jellyfin_access_token"]
        and not force
    ):
        payload = device_link_payload(row)
        payload["already_linked"] = True
        return jsonify(payload)

    headers = quick_connect_headers(device_id)

    try:
        enabled = requests.get(
            f"{JELLYFIN_URL}/QuickConnect/Enabled",
            headers=headers,
            timeout=20,
        )
        enabled.raise_for_status()

        if enabled.json() is not True:
            return jsonify(
                {
                    "error":
                        "Jellyfin Quick Connect is disabled"
                }
            ), 503

        response = requests.post(
            f"{JELLYFIN_URL}/QuickConnect/Initiate",
            headers=headers,
            timeout=20,
        )
        response.raise_for_status()
        state = response.json()
    except requests.RequestException as error:
        return jsonify(
            {
                "error":
                    "Quick Connect initiation failed",
                "detail": str(error),
            }
        ), 502

    code = state.get("Code")
    secret = state.get("Secret")

    if not code or not secret:
        return jsonify(
            {
                "error": (
                    "Jellyfin did not return a Quick "
                    "Connect code and secret"
                )
            }
        ), 502

    save_quick_connect(
        device_id,
        code,
        secret,
    )

    payload = device_link_payload(
        get_device(device_id)
    )
    payload["already_linked"] = False

    return jsonify(payload), 201


@device_links.get(
    "/devices/<device_id>/link/status"
)
def device_link_status(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    row = get_device(device_id)

    if row is None or not row["quick_connect_secret"]:
        return jsonify(device_link_payload(row))

    headers = quick_connect_headers(device_id)
    secret = row["quick_connect_secret"]

    try:
        response = requests.get(
            f"{JELLYFIN_URL}/QuickConnect/Connect",
            headers=headers,
            params={"secret": secret},
            timeout=20,
        )

        if response.status_code == 404:
            clear_pending_link(device_id)
            payload = device_link_payload(
                get_device(device_id)
            )
            payload["expired"] = True
            return jsonify(payload), 410

        response.raise_for_status()
        state = response.json()
    except requests.RequestException as error:
        return jsonify(
            {
                "error":
                    "Quick Connect polling failed",
                "detail": str(error),
            }
        ), 502

    if state.get("Authenticated") is not True:
        return jsonify(device_link_payload(row))

    exchange_headers = dict(headers)
    exchange_headers["Content-Type"] = (
        "application/json"
    )

    try:
        response = requests.post(
            (
                f"{JELLYFIN_URL}/Users/"
                "AuthenticateWithQuickConnect"
            ),
            headers=exchange_headers,
            json={"Secret": secret},
            timeout=20,
        )
        response.raise_for_status()
        authentication = response.json()
    except requests.RequestException as error:
        return jsonify(
            {
                "error": (
                    "Quick Connect token exchange "
                    "failed"
                ),
                "detail": str(error),
            }
        ), 502

    access_token = authentication.get("AccessToken")
    user = authentication.get("User") or {}
    user_id = user.get("Id")
    user_name = user.get("Name") or ""

    if not access_token or not user_id:
        return jsonify(
            {
                "error": (
                    "Jellyfin authentication lacked an "
                    "access token or user"
                )
            }
        ), 502

    save_linked_user(
        device_id,
        user_id,
        user_name,
        access_token,
    )

    payload = device_link_payload(
        get_device(device_id)
    )
    payload["newly_linked"] = True

    return jsonify(payload)
