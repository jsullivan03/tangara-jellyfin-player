#!/usr/bin/env python3
import os
import sys
import time
import uuid
from urllib.parse import quote

import requests

SERVER_URL = os.environ.get(
    "TANGARA_SYNC_URL",
    "http://127.0.0.1:8788",
).rstrip("/")
DEVICE_ID = os.environ.get(
    "TANGARA_DEVICE_ID",
    "tangara-sim-001",
)
TIMEOUT = 30


def request_json(method, path, body=None):
    response = requests.request(
        method,
        SERVER_URL + path,
        json=body,
        timeout=TIMEOUT,
    )

    try:
        payload = response.json()
    except ValueError:
        payload = {
            "raw": response.text,
        }

    if not response.ok:
        raise RuntimeError(
            f"{method} {path} returned "
            f"{response.status_code}: {payload}"
        )

    return payload


def device_path(suffix):
    return (
        "/devices/"
        + quote(DEVICE_ID, safe="")
        + suffix
    )


def library():
    return request_json(
        "GET",
        device_path("/library"),
    )


def playlist_items(playlist_id):
    return request_json(
        "GET",
        device_path(
            "/playlists/"
            + quote(playlist_id, safe="")
            + "/items?limit=500"
        ),
    )


def favorite_items():
    return request_json(
        "GET",
        device_path(
            "/favorites/items?limit=500"
        ),
    )


def submit(operation):
    payload = request_json(
        "POST",
        device_path("/operations"),
        {"operations": [operation]},
    )

    if not payload.get("ok"):
        raise RuntimeError(
            f"operation failed: {payload}"
        )

    result = payload["results"][0]

    if result.get("status") != "applied":
        raise RuntimeError(
            f"operation was not applied: {result}"
        )

    return result


def find_candidates(summary):
    candidates = []
    seen = set()

    for playlist in summary.get(
        "playlists",
        [],
    ):
        page = playlist_items(
            playlist["id"]
        )

        for item in page.get("items", []):
            item_id = item.get("id")

            if item_id and item_id not in seen:
                seen.add(item_id)
                candidates.append(item)

                if len(candidates) >= 2:
                    return candidates

    page = favorite_items()

    for item in page.get("items", []):
        item_id = item.get("id")

        if item_id and item_id not in seen:
            seen.add(item_id)
            candidates.append(item)

            if len(candidates) >= 2:
                return candidates

    return candidates


def operation(
    operation_id,
    operation_type,
    data,
):
    return {
        "id": operation_id,
        "type": operation_type,
        "data": data,
    }


def main():
    run_id = uuid.uuid4().hex
    local_id = "local:" + run_id
    prefix = "test:" + run_id + ":"
    playlist_id = None
    initial_favorite = None
    favorite_item_id = None

    summary = library()
    candidates = find_candidates(summary)

    if len(candidates) < 2:
        raise RuntimeError(
            "Two audio tracks are required "
            "for the integration test"
        )

    first = candidates[0]
    second = candidates[1]
    original_name = (
        "Tangara Sync Test "
        + run_id[:8]
    )
    renamed_name = (
        original_name + " Renamed"
    )

    try:
        create = operation(
            prefix + "create",
            "create_playlist",
            {
                "local_playlist_id": local_id,
                "name": original_name,
                "item_ids": [first["id"]],
            },
        )
        created = submit(create)
        playlist_id = created[
            "result"
        ]["playlist_id"]

        replayed = submit(create)

        if not replayed.get("replayed"):
            raise RuntimeError(
                "create operation was not replayed"
            )

        if (
            replayed["result"]["playlist_id"]
            != playlist_id
        ):
            raise RuntimeError(
                "create replay changed playlist ID"
            )

        added = submit(operation(
            prefix + "add",
            "add_playlist_item",
            {
                "playlist_id": local_id,
                "item_id": second["id"],
            },
        ))
        second_entry_id = added[
            "result"
        ]["entry_id"]

        submit(operation(
            prefix + "rename",
            "rename_playlist",
            {
                "playlist_id": local_id,
                "name": renamed_name,
            },
        ))

        page = playlist_items(playlist_id)

        if page["playlist"]["name"] != renamed_name:
            raise RuntimeError(
                "playlist rename did not persist"
            )

        if page["total"] != 2:
            raise RuntimeError(
                "playlist does not contain two tracks"
            )

        moved = submit(operation(
            prefix + "move",
            "move_playlist_item",
            {
                "playlist_id": local_id,
                "entry_id": second_entry_id,
                "new_index": 0,
            },
        ))

        page = playlist_items(playlist_id)

        if page["items"][0]["id"] != second["id"]:
            observed = [
                item.get("id")
                for item in page.get("items", [])
            ]
            raise RuntimeError(
                "playlist move did not persist: "
                + str({
                    "move_result": moved,
                    "expected_first": second["id"],
                    "observed": observed,
                })
            )

        submit(operation(
            prefix + "remove",
            "remove_playlist_item",
            {
                "playlist_id": local_id,
                "entry_id": second_entry_id,
            },
        ))

        page = playlist_items(playlist_id)

        if page["total"] != 1:
            raise RuntimeError(
                "playlist removal did not persist"
            )

        favorite_item_id = first["id"]
        initial_favorite = favorite_item_id in {
            item["id"]
            for item in favorite_items()["items"]
        }

        submit(operation(
            prefix + "favorite-toggle",
            "set_favorite",
            {
                "item_id": favorite_item_id,
                "favorite":
                    not initial_favorite,
            },
        ))

        favorites = {
            item["id"]
            for item in favorite_items()["items"]
        }

        if (
            favorite_item_id in favorites
        ) == initial_favorite:
            raise RuntimeError(
                "favorite change did not persist"
            )

        submit(operation(
            prefix + "favorite-restore",
            "set_favorite",
            {
                "item_id": favorite_item_id,
                "favorite": initial_favorite,
            },
        ))
        initial_favorite = None

        submit(operation(
            prefix + "delete",
            "delete_playlist",
            {
                "playlist_id": local_id,
            },
        ))
        playlist_id = None

        submit(create)

        summary = library()

        if any(
            playlist["name"] == original_name
            for playlist in summary["playlists"]
        ):
            raise RuntimeError(
                "replayed create made a duplicate playlist"
            )

        print(
            "Bidirectional Jellyfin server test passed"
        )
        print(
            "Created, replayed, added, renamed, "
            "moved, removed, favorited, restored, "
            "and deleted successfully"
        )
    finally:
        if initial_favorite is not None:
            try:
                submit(operation(
                    prefix + "cleanup-favorite",
                    "set_favorite",
                    {
                        "item_id":
                            favorite_item_id,
                        "favorite":
                            initial_favorite,
                    },
                ))
            except Exception as error:
                print(
                    f"favorite cleanup failed: {error}",
                    file=sys.stderr,
                )

        if playlist_id is not None:
            try:
                submit(operation(
                    prefix + "cleanup-delete",
                    "delete_playlist",
                    {
                        "playlist_id":
                            playlist_id,
                    },
                ))
            except Exception as error:
                print(
                    f"playlist cleanup failed: {error}",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    started_at = time.time()

    try:
        main()
    except Exception as error:
        print(
            f"Bidirectional test failed: {error}",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        f"Elapsed: {time.time() - started_at:.1f}s"
    )
