import hashlib
import os
import re
from io import BytesIO
from pathlib import Path
from urllib.parse import quote

import requests
from PIL import Image, ImageFilter, ImageOps
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
                "PrimaryImageItemId,AlbumId,ArtistItems,"
                "DateCreated"
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

    album_id = item.get("AlbumId") or ""
    artist_items = item.get("ArtistItems") or []

    artist_id = ""

    if artist_items and isinstance(
        artist_items[0],
        dict,
    ):
        artist_id = artist_items[0].get("Id") or ""

    artwork_source_id = (
        album_id
        or item.get("PrimaryImageItemId")
        or item["Id"]
    )

    artwork_key = album_id

    if not artwork_key:
        artwork_key = hashlib.sha1(
            (
                (item.get("AlbumArtist") or "")
                + "\0"
                + (item.get("Album") or "")
            ).encode("utf-8")
        ).hexdigest()

    artwork_key = re.sub(
        r"[^A-Za-z0-9._-]",
        "_",
        artwork_key,
    )

    return {
        "id": item["Id"],
        "jellyfin_id": item["Id"],
        "title": item.get("Name") or title,
        "artist": item.get("AlbumArtist")
        or (artists[0] if artists else ""),
        "artist_id": artist_id,
        "album": item.get("Album") or "",
        "album_id": album_id,
        "duration": duration,
        "date_created": item.get("DateCreated") or "",
        "track_number": item.get("IndexNumber") or 0,
        "disc_number": item.get("ParentIndexNumber") or 0,
        "local_path": (
            f"/Music/{artist}/{album}/{filename}"
        ),
        "artwork": {
            "thumbnail": (
                "/.tangara-artwork/albums/"
                + artwork_key
                + "-sq28.png"
            ),
            "thumbnail_item_id":
                artwork_source_id,
            "cover": (
                "/.tangara-artwork/albums/"
                + artwork_key
                + "-sq66.png"
            ),
            "cover_item_id":
                artwork_source_id,
            "background": (
                "/.tangara-artwork/albums/"
                + artwork_key
                + "-bg160x128-v3.png"
            ),
            "background_item_id":
                artwork_source_id,
        },
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
        # Fetch a clean square source and create the 160x128 background
        # ourselves. Jellyfin's blur response adds a visible edge vignette on
        # some artwork, while a local Gaussian blur stays uniform across the
        # screen.
        image_params = {
            "format": "png",
            "fillWidth": "256",
            "fillHeight": "256",
            "quality": "90",
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

    if variant in {"thumbnail", "background"}:
        cache_control = upstream.headers.get(
            "Cache-Control",
            "private, max-age=86400",
        )

        try:
            image_bytes = upstream.content
            upstream.close()

            with Image.open(
                BytesIO(image_bytes)
            ) as image:
                image = ImageOps.exif_transpose(
                    image
                )

                if variant == "thumbnail":
                    image = image.convert("RGBA")
                    image = ImageOps.fit(
                        image,
                        (28, 28),
                        method=(
                            Image.Resampling.LANCZOS
                        ),
                        centering=(0.5, 0.5),
                    )
                else:
                    image = image.convert("RGB")

                    # Blur an overscanned crop, then trim the bleed. This
                    # keeps the final 160x128 image away from Pillow's filter
                    # boundary and removes the vertical edge ridges that can
                    # appear when a blur is applied directly at output size.
                    bleed = 24
                    image = ImageOps.fit(
                        image,
                        (
                            160 + bleed * 2,
                            128 + bleed * 2,
                        ),
                        method=(
                            Image.Resampling.BICUBIC
                        ),
                        centering=(0.5, 0.5),
                    )
                    image = image.filter(
                        ImageFilter.GaussianBlur(
                            radius=16
                        )
                    )
                    image = image.crop(
                        (
                            bleed,
                            bleed,
                            bleed + 160,
                            bleed + 128,
                        )
                    )

                output = BytesIO()
                image.save(
                    output,
                    format="PNG",
                    optimize=True,
                )
                processed = output.getvalue()
        except (
            OSError,
            ValueError,
        ) as error:
            return jsonify(
                {
                    "error": (
                        "Artwork "
                        + variant
                        + " processing failed"
                    ),
                    "detail": str(error),
                }
            ), 502

        return Response(
            processed,
            status=200,
            headers={
                "Content-Length":
                    str(len(processed)),
                "Cache-Control":
                    cache_control,
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
