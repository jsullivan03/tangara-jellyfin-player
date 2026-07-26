import os
import re
from io import BytesIO
from pathlib import Path
from urllib.parse import quote

import requests
from PIL import Image, ImageOps
from flask import (
    Flask,
    Response,
    jsonify,
    request,
    stream_with_context,
)

from library_sync import library_sync_api

from device_links import (
    device_authentication,
    device_links,
    linked_device_count,
    valid_device_id,
)

from sync_preferences import (
    selected_audio_items,
    selected_item_ids,
    sync_preferences_api,
)

app = Flask(__name__)
app.register_blueprint(device_links)
app.register_blueprint(sync_preferences_api)
app.register_blueprint(library_sync_api)

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


def jellyfin_headers(
    token,
    accept="application/json",
):
    return {
        "X-Emby-Token": token,
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


def get_item(
    item_id,
    token,
    user_id,
):
    response = requests.get(
        f"{JELLYFIN_URL}/Items",
        headers=jellyfin_headers(token),
        params={
            "UserId": user_id,
            "Ids": item_id,
            "Recursive": "true",
            "Limit": "1",
            "Fields": (
                "Path,MediaSources,Album,AlbumArtist,"
                "Artists,RunTimeTicks,IndexNumber,"
                "ParentIndexNumber,Container,ImageTags,"
                "PrimaryImageItemId"
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
            "linked_devices": linked_device_count(),
        }
    )


@app.get("/devices/<device_id>/manifest")
def device_manifest(device_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = device_authentication(
        device_id,
        JELLYFIN_API_KEY,
        JELLYFIN_USER_ID,
    )

    try:
        if authentication["source"] == "linked_user":
            jellyfin_items = selected_audio_items(
                device_id,
                authentication,
            )

            items = [
                manifest_item(item)
                for item in jellyfin_items
            ]
        else:
            items = []

            for item_id in sorted(ITEM_IDS):
                item = get_item(
                    item_id,
                    authentication["token"],
                    authentication["user_id"],
                )

                if item is None:
                    return jsonify(
                        {
                            "error": (
                                "Jellyfin item was "
                                "not found"
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
                "authentication":
                    authentication["source"],
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
    (
        "/devices/<device_id>/items/"
        "<item_id>/artwork/<variant>"
    )
)
def device_artwork(
    device_id,
    item_id,
    variant,
):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    if variant not in {
        "cover",
        "background",
        "thumbnail",
    }:
        return jsonify(
            {"error": "Invalid artwork variant"}
        ), 400

    authentication = device_authentication(
        device_id,
        JELLYFIN_API_KEY,
        JELLYFIN_USER_ID,
    )

    if (
        authentication["source"] != "linked_user"
        and item_id not in ITEM_IDS
    ):
        return jsonify(
            {
                "error": (
                    "Item is not selected for "
                    "this device"
                )
            }
        ), 404

    try:
        item = get_item(
            item_id,
            authentication["token"],
            authentication["user_id"],
        )
    except requests.RequestException as error:
        return jsonify(
            {
                "error": "Jellyfin item query failed",
                "detail": str(error),
            }
        ), 502

    if item is None:
        return jsonify(
            {"error": "Jellyfin item was not found"}
        ), 404

    source_ids = []

    for source_id in (
        item.get("PrimaryImageItemId"),
        item.get("AlbumId"),
        item_id,
    ):
        if (
            isinstance(source_id, str)
            and source_id
            and source_id not in source_ids
        ):
            source_ids.append(source_id)

    image_tags = item.get("ImageTags") or {}
    image_tag = image_tags.get("Primary")

    if variant == "thumbnail":
        image_params = {
            "format": "png",
            "fillWidth": "28",
            "fillHeight": "28",
            "quality": "88",
        }
    elif variant == "cover":
        image_params = {
            "format": "png",
            "fillWidth": "66",
            "fillHeight": "66",
            "quality": "90",
        }
    else:
        image_params = {
            "format": "png",
            "fillWidth": "160",
            "fillHeight": "70",
            "quality": "85",
            "blur": "8",
        }

    if image_tag:
        image_params["tag"] = image_tag

    upstream = None

    try:
        for source_id in source_ids:
            candidate = requests.get(
                (
                    f"{JELLYFIN_URL}/Items/"
                    f"{quote(source_id, safe='')}/"
                    "Images/Primary"
                ),
                headers=jellyfin_headers(
                    authentication["token"],
                    "image/png",
                ),
                params=image_params,
                stream=True,
                timeout=(10, 60),
            )

            if candidate.status_code != 404:
                upstream = candidate
                break

            candidate.close()
    except requests.RequestException as error:
        if upstream is not None:
            upstream.close()

        return jsonify(
            {
                "error": (
                    "Jellyfin artwork request failed"
                ),
                "detail": str(error),
            }
        ), 502

    if upstream is None:
        return jsonify(
            {"error": "Artwork was not found"}
        ), 404

    if variant == "thumbnail":
        try:
            image_bytes = upstream.content
            upstream.close()

            with Image.open(
                BytesIO(image_bytes)
            ) as image:
                image = ImageOps.exif_transpose(
                    image
                )
                image = image.convert("RGBA")
                image = ImageOps.fit(
                    image,
                    (28, 28),
                    method=(
                        Image.Resampling.LANCZOS
                    ),
                    centering=(0.5, 0.5),
                )

                output = BytesIO()
                image.save(
                    output,
                    format="PNG",
                    optimize=True,
                )
                thumbnail = output.getvalue()
        except (
            OSError,
            ValueError,
        ) as error:
            return jsonify(
                {
                    "error": (
                        "Artwork thumbnail "
                        "processing failed"
                    ),
                    "detail": str(error),
                }
            ), 502

        return Response(
            thumbnail,
            status=200,
            headers={
                "Content-Length":
                    str(len(thumbnail)),
                "Cache-Control":
                    upstream.headers.get(
                        "Cache-Control",
                        "private, max-age=86400",
                    ),
            },
            mimetype="image/png",
        )

    response_headers = {}

    for name in (
        "Content-Type",
        "Content-Length",
        "ETag",
        "Last-Modified",
        "Cache-Control",
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


@app.get(
    "/devices/<device_id>/items/<item_id>/media"
)
def device_media(device_id, item_id):
    if not valid_device_id(device_id):
        return jsonify(
            {"error": "Invalid device ID"}
        ), 400

    authentication = device_authentication(
        device_id,
        JELLYFIN_API_KEY,
        JELLYFIN_USER_ID,
    )

    try:
        if authentication["source"] == "linked_user":
            allowed_items = selected_item_ids(
                device_id,
                authentication,
            )
        else:
            allowed_items = ITEM_IDS
    except requests.RequestException as error:
        return jsonify(
            {
                "error": (
                    "Jellyfin authorization query "
                    "failed"
                ),
                "detail": str(error),
            }
        ), 502

    if item_id not in allowed_items:
        return jsonify(
            {
                "error": (
                    "Item is not selected for "
                    "this device"
                )
            }
        ), 404

    upstream_headers = jellyfin_headers(
        authentication["token"],
        "application/octet-stream",
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
