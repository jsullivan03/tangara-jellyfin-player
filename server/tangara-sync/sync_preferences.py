import os
import time
from urllib.parse import quote

import requests
from flask import Blueprint, jsonify, request

from device_links import (
    database_connection,
    get_device,
    valid_device_id,
)

JELLYFIN_URL = os.environ.get(
    "JELLYFIN_URL",
    "http://host.docker.internal:8096",
).rstrip("/")

AUDIO_FIELDS = (
    "Album,AlbumArtist,Artists,"
    "MediaSources,Container,"
    "RunTimeTicks,IndexNumber,"
    "ParentIndexNumber,ImageTags,"
    "DateCreated"
)

sync_preferences_api = Blueprint(
    "sync_preferences",
    __name__,
)


def initialize_sync_database():
    with database_connection() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_preferences (
                device_id TEXT PRIMARY KEY,
                favorites_enabled INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            )
            """
        )

        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_playlists (
                device_id TEXT NOT NULL,
                playlist_id TEXT NOT NULL,
                playlist_name TEXT NOT NULL,
                position INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (device_id, playlist_id)
            )
            """
        )


initialize_sync_database()


def linked_authentication(device_id):
    row = get_device(device_id)

    if row is None or not row["jellyfin_access_token"]:
        return None

    return {
        "token": row["jellyfin_access_token"],
        "user_id": row["jellyfin_user_id"],
        "user_name": row["jellyfin_user_name"],
    }


def jellyfin_headers(token):
    return {
        "X-Emby-Token": token,
        "Accept": "application/json",
    }


def jellyfin_get(
    authentication,
    path,
    params=None,
    allow_not_found=False,
):
    response = requests.get(
        JELLYFIN_URL + path,
        headers=jellyfin_headers(
            authentication["token"]
        ),
        params=params,
        timeout=30,
    )

    if response.status_code == 404 and allow_not_found:
        return None

    response.raise_for_status()

    return response.json()


def response_items(payload):
    if isinstance(payload, dict):
        return payload.get("Items") or []

    if isinstance(payload, list):
        return payload

    return []


def only_audio(items):
    return [
        item
        for item in items
        if item.get("Type") == "Audio"
    ]


def fetch_playlists(authentication):
    payload = jellyfin_get(
        authentication,
        "/Items",
        {
            "UserId": authentication["user_id"],
            "IncludeItemTypes": "Playlist",
            "Recursive": "true",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Limit": "1000",
            "Fields": ("ChildCount,ImageTags,""PrimaryImageItemId"),
        },
    )

    return response_items(payload)


def fetch_playlist_items(
    authentication,
    playlist_id,
):
    payload = jellyfin_get(
        authentication,
        (
            "/Playlists/"
            + quote(playlist_id, safe="")
            + "/Items"
        ),
        {
            "UserId": authentication["user_id"],
            "Limit": "10000",
            "Fields": AUDIO_FIELDS,
        },
        allow_not_found=True,
    )

    if payload is None:
        return []

    return only_audio(response_items(payload))


def fetch_favorite_items(authentication):
    payload = jellyfin_get(
        authentication,
        "/Items",
        {
            "UserId": authentication["user_id"],
            "IncludeItemTypes": "Audio",
            "Recursive": "true",
            "Filters": "IsFavorite",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Limit": "10000",
            "Fields": AUDIO_FIELDS,
        },
    )

    return only_audio(response_items(payload))


def current_preferences(device_id):
    with database_connection() as connection:
        row = connection.execute(
            """
            SELECT favorites_enabled
            FROM sync_preferences
            WHERE device_id = ?
            """,
            (device_id,),
        ).fetchone()

        playlists = connection.execute(
            """
            SELECT playlist_id, playlist_name
            FROM sync_playlists
            WHERE device_id = ?
            ORDER BY position ASC
            """,
            (device_id,),
        ).fetchall()

    return {
        "favorites": bool(
            row["favorites_enabled"]
            if row
            else False
        ),
        "playlists": [
            {
                "id": playlist["playlist_id"],
                "name": playlist["playlist_name"],
            }
            for playlist in playlists
        ],
    }


def save_preferences(
    device_id,
    favorites,
    playlists,
):
    now = int(time.time())

    with database_connection() as connection:
        connection.execute(
            """
            INSERT INTO sync_preferences (
                device_id,
                favorites_enabled,
                updated_at
            ) VALUES (?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                favorites_enabled =
                    excluded.favorites_enabled,
                updated_at = excluded.updated_at
            """,
            (
                device_id,
                1 if favorites else 0,
                now,
            ),
        )

        connection.execute(
            """
            DELETE FROM sync_playlists
            WHERE device_id = ?
            """,
            (device_id,),
        )

        for position, playlist in enumerate(playlists):
            connection.execute(
                """
                INSERT INTO sync_playlists (
                    device_id,
                    playlist_id,
                    playlist_name,
                    position,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    device_id,
                    playlist["id"],
                    playlist["name"],
                    position,
                    now,
                ),
            )


def selected_audio_items(
    device_id,
    authentication=None,
):
    authentication = (
        authentication
        or linked_authentication(device_id)
    )

    if authentication is None:
        return []

    preferences = current_preferences(device_id)
    selected = []
    seen = set()

    for playlist in preferences["playlists"]:
        items = fetch_playlist_items(
            authentication,
            playlist["id"],
        )

        for item in items:
            item_id = item.get("Id")

            if not item_id or item_id in seen:
                continue

            seen.add(item_id)
            selected.append(item)

    if preferences["favorites"]:
        for item in fetch_favorite_items(authentication):
            item_id = item.get("Id")

            if not item_id or item_id in seen:
                continue

            seen.add(item_id)
            selected.append(item)

    return selected


def selected_item_ids(
    device_id,
    authentication=None,
):
    return {
        item["Id"]
        for item in selected_audio_items(
            device_id,
            authentication,
        )
        if item.get("Id")
    }


def link_required_response():
    return jsonify(
        {
            "error": "Device is not linked",
            "link_required": True,
        }
    ), 409


@sync_preferences_api.get(
    "/devices/<device_id>/sync/preferences"
)
def get_device_sync_preferences(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    if linked_authentication(device_id) is None:
        return link_required_response()

    return jsonify(current_preferences(device_id))


@sync_preferences_api.put(
    "/devices/<device_id>/sync/preferences"
)
def update_device_sync_preferences(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(device_id)

    if authentication is None:
        return link_required_response()

    payload = request.get_json(silent=True)

    if not isinstance(payload, dict):
        return jsonify(
            {"error": "JSON object is required"}
        ), 400

    favorites = payload.get("favorites")
    playlist_ids = payload.get("playlists")

    if not isinstance(favorites, bool):
        return jsonify(
            {"error": "favorites must be a boolean"}
        ), 400

    if not isinstance(playlist_ids, list):
        return jsonify(
            {"error": "playlists must be an array"}
        ), 400

    if len(playlist_ids) > 100:
        return jsonify(
            {"error": "Too many playlists selected"}
        ), 400

    normalized_ids = []

    for playlist_id in playlist_ids:
        if (
            not isinstance(playlist_id, str)
            or not playlist_id
        ):
            return jsonify(
                {
                    "error": (
                        "Each playlist ID must be "
                        "a non-empty string"
                    )
                }
            ), 400

        if playlist_id not in normalized_ids:
            normalized_ids.append(playlist_id)

    try:
        available = fetch_playlists(authentication)
    except requests.RequestException as error:
        return jsonify(
            {
                "error": (
                    "Jellyfin playlist query failed"
                ),
                "detail": str(error),
            }
        ), 502

    available_by_id = {
        playlist["Id"]: playlist
        for playlist in available
        if playlist.get("Id")
    }

    unknown = [
        playlist_id
        for playlist_id in normalized_ids
        if playlist_id not in available_by_id
    ]

    if unknown:
        return jsonify(
            {
                "error": (
                    "One or more playlists are "
                    "not available to this user"
                ),
                "unknown_playlists": unknown,
            }
        ), 400

    selected_playlists = [
        {
            "id": playlist_id,
            "name": (
                available_by_id[playlist_id].get(
                    "Name"
                )
                or playlist_id
            ),
        }
        for playlist_id in normalized_ids
    ]

    save_preferences(
        device_id,
        favorites,
        selected_playlists,
    )

    return jsonify(current_preferences(device_id))


@sync_preferences_api.get(
    "/devices/<device_id>/sync/sources"
)
def get_device_sync_sources(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = linked_authentication(device_id)

    if authentication is None:
        return link_required_response()

    preferences = current_preferences(device_id)
    selected_ids = {
        playlist["id"]
        for playlist in preferences["playlists"]
    }

    try:
        playlists = fetch_playlists(authentication)
        favorites = fetch_favorite_items(
            authentication
        )

        playlist_payloads = []

        for playlist in playlists:
            playlist_id = playlist.get("Id")

            if not playlist_id:
                continue

            playlist_items = fetch_playlist_items(
                authentication,
                playlist_id,
            )

            playlist_payloads.append(
                {
                    "id": playlist_id,
                    "name": (
                        playlist.get("Name")
                        or playlist_id
                    ),
                    "track_count": len(
                        playlist_items
                    ),
                    "selected": (
                        playlist_id
                        in selected_ids
                    ),
                }
            )
    except requests.RequestException as error:
        return jsonify(
            {
                "error": (
                    "Jellyfin sync-source query failed"
                ),
                "detail": str(error),
            }
        ), 502

    return jsonify(
        {
            "user": {
                "id": authentication["user_id"],
                "name": authentication["user_name"],
            },
            "favorites": {
                "name": "Favorites",
                "track_count": len(favorites),
                "selected": preferences["favorites"],
            },
            "playlists": playlist_payloads,
        }
    )
