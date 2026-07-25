import hashlib
import json
import re
import threading
import time
from urllib.parse import quote

import requests
from flask import Blueprint, jsonify, request

from device_links import (
    database_connection,
    valid_device_id,
)
from sync_preferences import (
    current_preferences,
    fetch_favorite_items,
    fetch_playlist_items,
    fetch_playlists,
    JELLYFIN_URL,
    jellyfin_headers,
    linked_authentication,
    link_required_response,
)

library_sync_api = Blueprint(
    "library_sync",
    __name__,
)

OPERATION_ID_PATTERN = re.compile(
    r"[A-Za-z0-9._:-]{1,128}"
)

SUPPORTED_OPERATIONS = {
    "create_playlist",
    "rename_playlist",
    "delete_playlist",
    "add_playlist_item",
    "remove_playlist_item",
    "move_playlist_item",
    "set_favorite",
}

operation_lock = threading.Lock()


class OperationFailure(Exception):
    def __init__(
        self,
        message,
        code="operation_failed",
        retriable=False,
    ):
        super().__init__(message)
        self.message = message
        self.code = code
        self.retriable = retriable


def initialize_library_sync_database():
    with database_connection() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS playlist_aliases (
                device_id TEXT NOT NULL,
                local_playlist_id TEXT NOT NULL,
                jellyfin_playlist_id TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (
                    device_id,
                    local_playlist_id
                )
            )
            """
        )

        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS device_operations (
                device_id TEXT NOT NULL,
                operation_id TEXT NOT NULL,
                operation_type TEXT NOT NULL,
                request_json TEXT NOT NULL,
                status TEXT NOT NULL,
                result_json TEXT,
                error_code TEXT,
                error_text TEXT,
                retriable INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                applied_at INTEGER,
                PRIMARY KEY (
                    device_id,
                    operation_id
                )
            )
            """
        )


initialize_library_sync_database()


def canonical_json(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    )


def revision(value):
    return hashlib.sha256(
        canonical_json(value).encode("utf-8")
    ).hexdigest()


def require_string(
    data,
    name,
    maximum=512,
):
    value = data.get(name)

    if not isinstance(value, str):
        raise OperationFailure(
            f"{name} must be a string",
            "invalid_operation",
        )

    value = value.strip()

    if not value:
        raise OperationFailure(
            f"{name} must not be empty",
            "invalid_operation",
        )

    if len(value) > maximum:
        raise OperationFailure(
            f"{name} is too long",
            "invalid_operation",
        )

    return value


def optional_string(
    data,
    name,
    maximum=512,
):
    value = data.get(name)

    if value is None:
        return None

    if not isinstance(value, str):
        raise OperationFailure(
            f"{name} must be a string",
            "invalid_operation",
        )

    value = value.strip()

    if not value:
        raise OperationFailure(
            f"{name} must not be empty",
            "invalid_operation",
        )

    if len(value) > maximum:
        raise OperationFailure(
            f"{name} is too long",
            "invalid_operation",
        )

    return value


def string_list(
    data,
    name,
    maximum_items=10000,
):
    values = data.get(name, [])

    if not isinstance(values, list):
        raise OperationFailure(
            f"{name} must be an array",
            "invalid_operation",
        )

    if len(values) > maximum_items:
        raise OperationFailure(
            f"{name} contains too many items",
            "invalid_operation",
        )

    normalized = []

    for value in values:
        if not isinstance(value, str) or not value:
            raise OperationFailure(
                f"{name} must contain non-empty strings",
                "invalid_operation",
            )

        normalized.append(value)

    return normalized


def jellyfin_request(
    authentication,
    method,
    path,
    params=None,
    json_body=None,
    allowed_statuses=(),
):
    response = requests.request(
        method,
        JELLYFIN_URL + path,
        headers=jellyfin_headers(
            authentication["token"]
        ),
        params=params,
        json=json_body,
        timeout=30,
    )

    if response.status_code in allowed_statuses:
        return response

    response.raise_for_status()

    return response



def response_json(response):
    if not response.content:
        return {}

    try:
        payload = response.json()
    except ValueError as error:
        raise OperationFailure(
            "Jellyfin returned invalid JSON",
            "jellyfin_invalid_response",
            True,
        ) from error

    if not isinstance(payload, dict):
        raise OperationFailure(
            "Jellyfin returned an unexpected response",
            "jellyfin_invalid_response",
            True,
        )

    return payload


def media_size(item):
    media_sources = item.get("MediaSources") or []

    if not media_sources:
        return None

    return media_sources[0].get("Size")


def track_payload(item, position=None):
    user_data = item.get("UserData") or {}
    runtime_ticks = item.get("RunTimeTicks") or 0

    try:
        duration_seconds = (
            int(runtime_ticks) // 10_000_000
        )
    except (TypeError, ValueError):
        duration_seconds = 0

    payload = {
        "id": item.get("Id"),
        "title": item.get("Name") or "",
        "artist": (
            item.get("AlbumArtist")
            or (
                (item.get("Artists") or [""])[0]
            )
        ),
        "album": item.get("Album") or "",
        "album_id": item.get("AlbumId"),
        "duration": duration_seconds,
        "size_bytes": media_size(item),
        "favorite": bool(
            user_data.get("IsFavorite")
        ),
        "playlist_entry_id":
            item.get("PlaylistItemId"),
        "track_number": item.get("IndexNumber"),
        "disc_number":
            item.get("ParentIndexNumber"),
        "image_tags": item.get("ImageTags") or {},
    }

    if position is not None:
        payload["position"] = position

    return payload


def playlist_revision(items):
    return revision([
        {
            "entry_id": item.get(
                "PlaylistItemId"
            ),
            "item_id": item.get("Id"),
        }
        for item in items
    ])


def favorites_revision(items):
    return revision([
        item.get("Id")
        for item in items
        if item.get("Id")
    ])


def resolve_playlist_id(
    device_id,
    playlist_id,
):
    with database_connection() as connection:
        row = connection.execute(
            """
            SELECT jellyfin_playlist_id
            FROM playlist_aliases
            WHERE device_id = ?
              AND local_playlist_id = ?
            """,
            (
                device_id,
                playlist_id,
            ),
        ).fetchone()

    if row:
        return row["jellyfin_playlist_id"]

    return playlist_id


def save_playlist_alias(
    device_id,
    local_playlist_id,
    jellyfin_playlist_id,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            INSERT INTO playlist_aliases (
                device_id,
                local_playlist_id,
                jellyfin_playlist_id,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(
                device_id,
                local_playlist_id
            ) DO UPDATE SET
                jellyfin_playlist_id =
                    excluded.jellyfin_playlist_id,
                updated_at = excluded.updated_at
            """,
            (
                device_id,
                local_playlist_id,
                jellyfin_playlist_id,
                now,
                now,
            ),
        )


def remove_playlist_state(
    device_id,
    playlist_id,
):
    with database_connection() as connection:
        connection.execute(
            """
            DELETE FROM sync_playlists
            WHERE device_id = ?
              AND playlist_id = ?
            """,
            (
                device_id,
                playlist_id,
            ),
        )

        connection.execute(
            """
            DELETE FROM playlist_aliases
            WHERE device_id = ?
              AND jellyfin_playlist_id = ?
            """,
            (
                device_id,
                playlist_id,
            ),
        )


def update_selected_playlist_name(
    device_id,
    playlist_id,
    name,
):
    with database_connection() as connection:
        connection.execute(
            """
            UPDATE sync_playlists
            SET playlist_name = ?,
                updated_at = ?
            WHERE device_id = ?
              AND playlist_id = ?
            """,
            (
                name,
                int(time.time()),
                device_id,
                playlist_id,
            ),
        )


def operation_record(
    device_id,
    operation_id,
):
    with database_connection() as connection:
        return connection.execute(
            """
            SELECT *
            FROM device_operations
            WHERE device_id = ?
              AND operation_id = ?
            """,
            (
                device_id,
                operation_id,
            ),
        ).fetchone()


def prepare_operation_record(
    device_id,
    operation_id,
    operation_type,
    request_json,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            INSERT OR IGNORE INTO device_operations (
                device_id,
                operation_id,
                operation_type,
                request_json,
                status,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, 'pending', ?, ?)
            """,
            (
                device_id,
                operation_id,
                operation_type,
                request_json,
                now,
                now,
            ),
        )

    row = operation_record(
        device_id,
        operation_id,
    )

    if (
        row["operation_type"] != operation_type
        or row["request_json"] != request_json
    ):
        raise OperationFailure(
            (
                "operation ID was already used "
                "with different data"
            ),
            "operation_id_conflict",
        )

    return row


def save_operation_applied(
    device_id,
    operation_id,
    result,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            UPDATE device_operations
            SET status = 'applied',
                result_json = ?,
                error_code = NULL,
                error_text = NULL,
                retriable = 0,
                updated_at = ?,
                applied_at = ?
            WHERE device_id = ?
              AND operation_id = ?
            """,
            (
                canonical_json(result),
                now,
                now,
                device_id,
                operation_id,
            ),
        )


def save_operation_failed(
    device_id,
    operation_id,
    failure,
):
    with database_connection() as connection:
        connection.execute(
            """
            UPDATE device_operations
            SET status = 'failed',
                error_code = ?,
                error_text = ?,
                retriable = ?,
                updated_at = ?
            WHERE device_id = ?
              AND operation_id = ?
            """,
            (
                failure.code,
                failure.message,
                1 if failure.retriable else 0,
                int(time.time()),
                device_id,
                operation_id,
            ),
        )


def decode_result(row):
    if not row["result_json"]:
        return {}

    try:
        result = json.loads(row["result_json"])
    except json.JSONDecodeError:
        return {}

    return result if isinstance(result, dict) else {}


def create_playlist(
    device_id,
    authentication,
    data,
):
    name = require_string(
        data,
        "name",
        200,
    )
    local_playlist_id = optional_string(
        data,
        "local_playlist_id",
        128,
    )
    item_ids = string_list(
        data,
        "item_ids",
    )

    response = jellyfin_request(
        authentication,
        "POST",
        "/Playlists",
        json_body={
            "Name": name,
            "Ids": item_ids,
            "UserId":
                authentication["user_id"],
            "MediaType": "Audio",
        },
    )
    payload = response_json(response)
    playlist_id = (
        payload.get("Id")
        or payload.get("id")
    )

    if not isinstance(playlist_id, str) or not playlist_id:
        raise OperationFailure(
            (
                "Jellyfin did not return the "
                "created playlist ID"
            ),
            "jellyfin_invalid_response",
            True,
        )

    if local_playlist_id:
        save_playlist_alias(
            device_id,
            local_playlist_id,
            playlist_id,
        )

    return {
        "playlist_id": playlist_id,
        "local_playlist_id":
            local_playlist_id,
        "name": name,
        "item_count": len(item_ids),
    }


def rename_playlist(
    device_id,
    authentication,
    data,
):
    playlist_reference = require_string(
        data,
        "playlist_id",
        128,
    )
    name = require_string(
        data,
        "name",
        200,
    )
    playlist_id = resolve_playlist_id(
        device_id,
        playlist_reference,
    )

    jellyfin_request(
        authentication,
        "POST",
        (
            "/Playlists/"
            + quote(playlist_id, safe="")
        ),
        json_body={"Name": name},
    )

    update_selected_playlist_name(
        device_id,
        playlist_id,
        name,
    )

    return {
        "playlist_id": playlist_id,
        "name": name,
    }


def delete_playlist(
    device_id,
    authentication,
    data,
):
    playlist_reference = require_string(
        data,
        "playlist_id",
        128,
    )
    playlist_id = resolve_playlist_id(
        device_id,
        playlist_reference,
    )

    response = jellyfin_request(
        authentication,
        "DELETE",
        (
            "/Items/"
            + quote(playlist_id, safe="")
        ),
        allowed_statuses=(404,),
    )

    remove_playlist_state(
        device_id,
        playlist_id,
    )

    return {
        "playlist_id": playlist_id,
        "deleted": response.status_code != 404,
        "already_missing":
            response.status_code == 404,
    }


def add_playlist_item(
    device_id,
    authentication,
    data,
):
    playlist_reference = require_string(
        data,
        "playlist_id",
        128,
    )
    item_id = require_string(
        data,
        "item_id",
        128,
    )
    playlist_id = resolve_playlist_id(
        device_id,
        playlist_reference,
    )

    before = {
        item.get("PlaylistItemId")
        for item in fetch_playlist_items(
            authentication,
            playlist_id,
        )
        if item.get("PlaylistItemId")
    }

    jellyfin_request(
        authentication,
        "POST",
        (
            "/Playlists/"
            + quote(playlist_id, safe="")
            + "/Items"
        ),
        params={
            "ids": item_id,
            "userId":
                authentication["user_id"],
        },
    )

    after_items = fetch_playlist_items(
        authentication,
        playlist_id,
    )

    entry_id = None

    for item in reversed(after_items):
        candidate = item.get("PlaylistItemId")

        if (
            item.get("Id") == item_id
            and candidate
            and candidate not in before
        ):
            entry_id = candidate
            break

    if not entry_id:
        raise OperationFailure(
            (
                "Jellyfin added the track but did "
                "not return its playlist entry"
            ),
            "jellyfin_invalid_response",
            True,
        )

    return {
        "playlist_id": playlist_id,
        "item_id": item_id,
        "entry_id": entry_id,
        "position": len(after_items) - 1,
    }


def remove_playlist_item(
    device_id,
    authentication,
    data,
):
    playlist_reference = require_string(
        data,
        "playlist_id",
        128,
    )
    entry_id = require_string(
        data,
        "entry_id",
        128,
    )
    playlist_id = resolve_playlist_id(
        device_id,
        playlist_reference,
    )

    response = jellyfin_request(
        authentication,
        "DELETE",
        (
            "/Playlists/"
            + quote(playlist_id, safe="")
            + "/Items"
        ),
        params={"entryIds": entry_id},
        allowed_statuses=(404,),
    )

    return {
        "playlist_id": playlist_id,
        "entry_id": entry_id,
        "removed": response.status_code != 404,
        "already_missing":
            response.status_code == 404,
    }


def move_playlist_item(
    device_id,
    authentication,
    data,
):
    playlist_reference = require_string(
        data,
        "playlist_id",
        128,
    )
    entry_id = require_string(
        data,
        "entry_id",
        128,
    )
    new_index = data.get("new_index")

    if (
        isinstance(new_index, bool)
        or not isinstance(new_index, int)
        or new_index < 0
    ):
        raise OperationFailure(
            (
                "new_index must be a "
                "non-negative integer"
            ),
            "invalid_operation",
        )

    playlist_id = resolve_playlist_id(
        device_id,
        playlist_reference,
    )

    def entry_index(items):
        normalized_entry_id = entry_id.lower()

        for index, item in enumerate(items):
            candidate = item.get("PlaylistItemId")

            if (
                isinstance(candidate, str)
                and candidate.lower()
                == normalized_entry_id
            ):
                return index

        return None

    items = fetch_playlist_items(
        authentication,
        playlist_id,
    )
    current_index = entry_index(items)

    if current_index is None:
        raise OperationFailure(
            "Playlist entry was not found",
            "playlist_entry_not_found",
        )

    if new_index >= len(items):
        raise OperationFailure(
            "new_index is outside the playlist",
            "invalid_operation",
        )

    if current_index == new_index:
        return {
            "playlist_id": playlist_id,
            "entry_id": entry_id,
            "old_index": current_index,
            "new_index": new_index,
            "moved": False,
            "already_positioned": True,
            "attempts": 0,
        }

    path = (
        "/Playlists/"
        + quote(playlist_id, safe="")
        + "/Items/"
        + quote(entry_id, safe="")
        + "/Move/"
        + str(new_index)
    )
    deadline = time.monotonic() + 8
    attempts = 0
    observed_index = current_index

    while time.monotonic() < deadline:
        jellyfin_request(
            authentication,
            "POST",
            path,
        )
        attempts += 1

        confirmation_deadline = min(
            deadline,
            time.monotonic() + 1.5,
        )

        while time.monotonic() < confirmation_deadline:
            time.sleep(0.25)

            refreshed = fetch_playlist_items(
                authentication,
                playlist_id,
            )
            observed_index = entry_index(refreshed)

            if observed_index != new_index:
                continue

            time.sleep(0.75)

            confirmed = fetch_playlist_items(
                authentication,
                playlist_id,
            )
            observed_index = entry_index(confirmed)

            if observed_index == new_index:
                return {
                    "playlist_id": playlist_id,
                    "entry_id": entry_id,
                    "old_index": current_index,
                    "new_index": new_index,
                    "moved": True,
                    "already_positioned": False,
                    "attempts": attempts,
                }

    raise OperationFailure(
        (
            "Jellyfin did not persist the "
            "playlist move"
        ),
        "jellyfin_write_not_persisted",
        True,
    )


def set_favorite(
    device_id,
    authentication,
    data,
):
    del device_id

    item_id = require_string(
        data,
        "item_id",
        128,
    )
    favorite = data.get("favorite")

    if not isinstance(favorite, bool):
        raise OperationFailure(
            "favorite must be a boolean",
            "invalid_operation",
        )

    jellyfin_request(
        authentication,
        "POST" if favorite else "DELETE",
        (
            "/UserFavoriteItems/"
            + quote(item_id, safe="")
        ),
        params={
            "userId":
                authentication["user_id"],
        },
    )

    return {
        "item_id": item_id,
        "favorite": favorite,
    }


OPERATION_HANDLERS = {
    "create_playlist": create_playlist,
    "rename_playlist": rename_playlist,
    "delete_playlist": delete_playlist,
    "add_playlist_item": add_playlist_item,
    "remove_playlist_item":
        remove_playlist_item,
    "move_playlist_item": move_playlist_item,
    "set_favorite": set_favorite,
}


def normalized_operation(operation):
    if not isinstance(operation, dict):
        raise OperationFailure(
            "each operation must be an object",
            "invalid_operation",
        )

    operation_id = operation.get("id")
    operation_type = operation.get("type")
    data = operation.get("data", {})

    if (
        not isinstance(operation_id, str)
        or not OPERATION_ID_PATTERN.fullmatch(
            operation_id
        )
    ):
        raise OperationFailure(
            (
                "operation id must contain only "
                "letters, numbers, period, "
                "underscore, colon, or hyphen"
            ),
            "invalid_operation",
        )

    if operation_type not in SUPPORTED_OPERATIONS:
        raise OperationFailure(
            "unsupported operation type",
            "invalid_operation",
        )

    if not isinstance(data, dict):
        raise OperationFailure(
            "operation data must be an object",
            "invalid_operation",
        )

    return (
        operation_id,
        operation_type,
        data,
    )


def apply_operation(
    device_id,
    authentication,
    operation,
):
    (
        operation_id,
        operation_type,
        data,
    ) = normalized_operation(operation)

    request_json = canonical_json({
        "type": operation_type,
        "data": data,
    })

    row = prepare_operation_record(
        device_id,
        operation_id,
        operation_type,
        request_json,
    )

    if row["status"] == "applied":
        return {
            "id": operation_id,
            "type": operation_type,
            "status": "applied",
            "replayed": True,
            "result": decode_result(row),
        }

    try:
        result = OPERATION_HANDLERS[
            operation_type
        ](
            device_id,
            authentication,
            data,
        )
    except OperationFailure as failure:
        save_operation_failed(
            device_id,
            operation_id,
            failure,
        )

        return {
            "id": operation_id,
            "type": operation_type,
            "status": "failed",
            "replayed": False,
            "error": {
                "code": failure.code,
                "message": failure.message,
                "retriable":
                    failure.retriable,
            },
        }
    except requests.RequestException as error:
        failure = OperationFailure(
            str(error),
            "jellyfin_request_failed",
            True,
        )

        save_operation_failed(
            device_id,
            operation_id,
            failure,
        )

        return {
            "id": operation_id,
            "type": operation_type,
            "status": "failed",
            "replayed": False,
            "error": {
                "code": failure.code,
                "message": failure.message,
                "retriable": True,
            },
        }

    save_operation_applied(
        device_id,
        operation_id,
        result,
    )

    return {
        "id": operation_id,
        "type": operation_type,
        "status": "applied",
        "replayed": False,
        "result": result,
    }


def pagination():
    try:
        start = int(
            request.args.get("start", "0")
        )
        limit = int(
            request.args.get("limit", "100")
        )
    except ValueError:
        return None, None, (
            jsonify({
                "error":
                    "start and limit must be integers"
            }),
            400,
        )

    if start < 0:
        return None, None, (
            jsonify({
                "error":
                    "start must not be negative"
            }),
            400,
        )

    if limit < 1 or limit > 500:
        return None, None, (
            jsonify({
                "error":
                    "limit must be between 1 and 500"
            }),
            400,
        )

    return start, limit, None


def available_playlist(
    authentication,
    playlist_id,
):
    for playlist in fetch_playlists(
        authentication
    ):
        if playlist.get("Id") == playlist_id:
            return playlist

    return None


@library_sync_api.get(
    "/devices/<device_id>/library"
)
def get_device_library(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(
        device_id
    )

    if authentication is None:
        return link_required_response()

    preferences = current_preferences(device_id)
    selected_ids = {
        playlist["id"]
        for playlist in preferences["playlists"]
    }

    try:
        playlists = fetch_playlists(
            authentication
        )
        playlist_payloads = []

        for playlist in playlists:
            playlist_id = playlist.get("Id")

            if not playlist_id:
                continue

            items = fetch_playlist_items(
                authentication,
                playlist_id,
            )

            playlist_payloads.append({
                "id": playlist_id,
                "name": (
                    playlist.get("Name")
                    or playlist_id
                ),
                "track_count": len(items),
                "revision":
                    playlist_revision(items),
                "keep_downloaded":
                    playlist_id in selected_ids,
                "items_path": (
                    "/devices/"
                    + quote(device_id, safe="")
                    + "/playlists/"
                    + quote(playlist_id, safe="")
                    + "/items"
                ),
            })

        favorites = fetch_favorite_items(
            authentication
        )
    except requests.RequestException as error:
        return jsonify({
            "error":
                "Jellyfin library query failed",
            "detail": str(error),
        }), 502

    summary = {
        "user": {
            "id": authentication["user_id"],
            "name":
                authentication["user_name"],
        },
        "generated_at": int(time.time()),
        "favorites": {
            "name": "Favorites",
            "track_count": len(favorites),
            "revision":
                favorites_revision(favorites),
            "keep_downloaded":
                preferences["favorites"],
            "items_path": (
                "/devices/"
                + quote(device_id, safe="")
                + "/favorites/items"
            ),
        },
        "playlists": playlist_payloads,
    }

    summary["revision"] = revision({
        "favorites":
            summary["favorites"]["revision"],
        "playlists": [
            {
                "id": playlist["id"],
                "name": playlist["name"],
                "revision":
                    playlist["revision"],
            }
            for playlist in playlist_payloads
        ],
    })

    return jsonify(summary)


@library_sync_api.get(
    (
        "/devices/<device_id>/playlists/"
        "<playlist_id>/items"
    )
)
def get_device_playlist_items(
    device_id,
    playlist_id,
):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(
        device_id
    )

    if authentication is None:
        return link_required_response()

    start, limit, pagination_error = (
        pagination()
    )

    if pagination_error:
        return pagination_error

    playlist_id = resolve_playlist_id(
        device_id,
        playlist_id,
    )

    try:
        playlist = available_playlist(
            authentication,
            playlist_id,
        )

        if playlist is None:
            return jsonify({
                "error": "Playlist was not found"
            }), 404

        items = fetch_playlist_items(
            authentication,
            playlist_id,
        )
    except requests.RequestException as error:
        return jsonify({
            "error":
                "Jellyfin playlist query failed",
            "detail": str(error),
        }), 502

    selected = items[
        start:start + limit
    ]
    next_start = (
        start + len(selected)
        if start + len(selected) < len(items)
        else None
    )

    return jsonify({
        "playlist": {
            "id": playlist_id,
            "name": (
                playlist.get("Name")
                or playlist_id
            ),
            "revision":
                playlist_revision(items),
        },
        "start": start,
        "limit": limit,
        "total": len(items),
        "next_start": next_start,
        "items": [
            track_payload(item, start + index)
            for index, item in enumerate(
                selected
            )
        ],
    })


@library_sync_api.get(
    "/devices/<device_id>/favorites/items"
)
def get_device_favorite_items(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(
        device_id
    )

    if authentication is None:
        return link_required_response()

    start, limit, pagination_error = (
        pagination()
    )

    if pagination_error:
        return pagination_error

    try:
        items = fetch_favorite_items(
            authentication
        )
    except requests.RequestException as error:
        return jsonify({
            "error":
                "Jellyfin favorites query failed",
            "detail": str(error),
        }), 502

    selected = items[
        start:start + limit
    ]
    next_start = (
        start + len(selected)
        if start + len(selected) < len(items)
        else None
    )

    return jsonify({
        "name": "Favorites",
        "revision":
            favorites_revision(items),
        "start": start,
        "limit": limit,
        "total": len(items),
        "next_start": next_start,
        "items": [
            track_payload(item, start + index)
            for index, item in enumerate(
                selected
            )
        ],
    })


@library_sync_api.post(
    "/devices/<device_id>/operations"
)
def post_device_operations(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(
        device_id
    )

    if authentication is None:
        return link_required_response()

    payload = request.get_json(silent=True)

    if not isinstance(payload, dict):
        return jsonify(
            {"error": "JSON object is required"}
        ), 400

    operations = payload.get("operations")

    if not isinstance(operations, list):
        return jsonify(
            {"error": "operations must be an array"}
        ), 400

    if not operations:
        return jsonify({
            "ok": True,
            "results": [],
        })

    if len(operations) > 100:
        return jsonify(
            {"error": "Too many operations"}
        ), 400

    results = []

    with operation_lock:
        for operation in operations:
            try:
                result = apply_operation(
                    device_id,
                    authentication,
                    operation,
                )
            except OperationFailure as failure:
                return jsonify({
                    "error": failure.message,
                    "code": failure.code,
                }), (
                    409
                    if failure.code
                    == "operation_id_conflict"
                    else 400
                )

            results.append(result)

            if result["status"] != "applied":
                break

    return jsonify({
        "ok": all(
            result["status"] == "applied"
            for result in results
        ),
        "results": results,
        "remaining": (
            len(operations) - len(results)
        ),
    })
