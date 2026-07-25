import os
import re
from pathlib import Path
from urllib.parse import quote

import requests
from flask import Flask, Response, jsonify, request, stream_with_context

app = Flask(__name__)

JELLYFIN_URL = os.environ.get(
    "JELLYFIN_URL",
    "http://host.docker.internal:8096",
).rstrip("/")

JELLYFIN_USER_ID = os.environ["JELLYFIN_USER_ID"]

API_KEY_FILE = Path(
    os.environ.get(
        "JELLYFIN_API_KEY_FILE",
        "/run/secrets/jellyfin_api_key",
    )
)

JELLYFIN_API_KEY = API_KEY_FILE.read_text().strip()

ITEM_IDS = {
    value.strip()
    for value in os.environ.get(
        "TANGARA_ITEM_IDS",
        "",
    ).split(",")
    if value.strip()
}

if not JELLYFIN_API_KEY:
    raise RuntimeError("Jellyfin API key is empty")

if not ITEM_IDS:
    raise RuntimeError("No Tangara test items are configured")


def jellyfin_headers(accept="application/json"):
    return {
        "X-Emby-Token": JELLYFIN_API_KEY,
        "Accept": accept,
    }


def safe_segment(value, fallback):
    if not isinstance(value, str):
        value = ""

    value = re.sub(
        r'[\\/:*?"<>|\x00-\x1f]',
        "_",
        value,
    )

    value = re.sub(r"\s+", " ", value)
    value = value.strip().strip(".")

    if not value or value in {".", ".."}:
        return fallback

    return value


def get_item(item_id):
    response = requests.get(
        f"{JELLYFIN_URL}/Items",
        headers=jellyfin_headers(),
        params={
            "UserId": JELLYFIN_USER_ID,
            "Ids": item_id,
            "Recursive": "true",
            "Limit": "1",
            "Fields": (
                "Path,MediaSources,Album,AlbumArtist,"
                "Artists,RunTimeTicks,IndexNumber,"
                "ParentIndexNumber,Container,ImageTags"
            ),
        },
        timeout=20,
    )

    response.raise_for_status()

    items = response.json().get("Items") or []

    if not items:
        return None

    return items[0]


def manifest_item(item):
    media_sources = item.get("MediaSources") or []
    media_source = (
        media_sources[0]
        if media_sources
        else {}
    )

    title = safe_segment(
        item.get("Name"),
        "Unknown Track",
    )

    artists = item.get("Artists") or []

    artist = safe_segment(
        item.get("AlbumArtist")
        or (artists[0] if artists else ""),
        "Unknown Artist",
    )

    album = safe_segment(
        item.get("Album"),
        "Unknown Album",
    )

    container = (
        item.get("Container")
        or media_source.get("Container")
        or "bin"
    ).lower()

    if container == "mp4":
        container = "m4a"

    index_number = item.get("IndexNumber")

    try:
        track_prefix = f"{int(index_number):02d} "
    except (TypeError, ValueError):
        track_prefix = ""

    filename = (
        track_prefix
        + title
        + "."
        + safe_segment(container, "bin")
    )

    runtime_ticks = item.get("RunTimeTicks") or 0

    try:
        duration = int(runtime_ticks) // 10_000_000
    except (TypeError, ValueError):
        duration = 0

    return {
        "id": item["Id"],
        "jellyfin_id": item["Id"],
        "title": item.get("Name") or title,
        "artist": item.get("AlbumArtist")
        or (artists[0] if artists else ""),
        "album": item.get("Album") or "",
        "duration": duration,
        "local_path": (
            f"/Music/{artist}/{album}/{filename}"
        ),
        "sync_state": "ready",
        "pinned": True,
        "size_bytes": media_source.get("Size"),
    }


@app.get("/health")
def health():
    return jsonify(
        {
            "ok": True,
            "jellyfin_url": JELLYFIN_URL,
            "configured_items": len(ITEM_IDS),
        }
    )


@app.get("/devices/<device_id>/manifest")
def device_manifest(device_id):
    items = []

    try:
        for item_id in sorted(ITEM_IDS):
            item = get_item(item_id)

            if item is None:
                return jsonify(
                    {
                        "error": (
                            "Jellyfin item was not found"
                        ),
                        "jellyfin_id": item_id,
                    }
                ), 404

            items.append(manifest_item(item))
    except requests.RequestException as error:
        return jsonify(
            {
                "error": "Jellyfin request failed",
                "detail": str(error),
            }
        ), 502

    return jsonify(
        {
            "device": {
                "id": device_id,
                "name": device_id,
                "storage": {
                    "capacity_bytes": 0,
                    "used_bytes": 0,
                    "reserved_bytes": 0,
                },
            },
            "items": items,
        }
    )


@app.get(
    "/devices/<device_id>/items/<item_id>/media"
)
def device_media(device_id, item_id):
    if item_id not in ITEM_IDS:
        return jsonify(
            {
                "error": (
                    "Item is not assigned to this "
                    "Tangara sync server"
                )
            }
        ), 404

    upstream_headers = jellyfin_headers(
        "application/octet-stream"
    )

    range_header = request.headers.get("Range")

    if range_header:
        upstream_headers["Range"] = range_header

    try:
        upstream = requests.get(
            (
                f"{JELLYFIN_URL}/Items/"
                f"{quote(item_id, safe='')}/Download"
            ),
            headers=upstream_headers,
            stream=True,
            timeout=(10, 300),
        )
    except requests.RequestException as error:
        return jsonify(
            {
                "error": "Jellyfin media request failed",
                "detail": str(error),
            }
        ), 502

    response_headers = {}

    for name in (
        "Content-Type",
        "Content-Length",
        "Content-Range",
        "Accept-Ranges",
        "ETag",
        "Last-Modified",
        "Content-Disposition",
    ):
        value = upstream.headers.get(name)

        if value is not None:
            response_headers[name] = value

    def generate():
        try:
            for chunk in upstream.iter_content(
                chunk_size=64 * 1024
            ):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    return Response(
        stream_with_context(generate()),
        status=upstream.status_code,
        headers=response_headers,
        direct_passthrough=True,
    )
