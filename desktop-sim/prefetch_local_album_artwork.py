from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen
import json
import os
import sys

root = Path(sys.argv[1]).resolve()
base = sys.argv[2].rstrip("/")
device_id = sys.argv[3]

manifest_path = root / ".tangara_sync_manifest.json"

if not manifest_path.exists():
    raise SystemExit(
        f"Manifest not found: {manifest_path}"
    )

manifest = json.loads(manifest_path.read_text())
jobs = {}

for item in manifest.get("items") or []:
    artwork = item.get("artwork") or {}
    local_path = artwork.get("thumbnail")
    item_id = artwork.get("thumbnail_item_id")

    if (
        isinstance(local_path, str)
        and local_path.startswith("/")
        and isinstance(item_id, str)
        and item_id
    ):
        jobs.setdefault(local_path, item_id)

if not jobs:
    raise SystemExit(
        "The simulator manifest contains no album artwork jobs"
    )

def fetch(job):
    local_path, item_id = job
    destination = root / local_path.lstrip("/")

    if destination.exists() and destination.stat().st_size > 0:
        return "reused"

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary = Path(str(destination) + ".part")
    url = (
        f"{base}/devices/{quote(device_id, safe='')}/"
        f"items/{quote(item_id, safe='')}/artwork/thumbnail"
    )

    try:
        with urlopen(url, timeout=25) as response:
            data = response.read()

        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            return "failed"

        temporary.write_bytes(data)
        os.replace(temporary, destination)
        return "downloaded"
    except (
        HTTPError,
        URLError,
        TimeoutError,
    ):
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

        return "failed"

total = len(jobs)
finished = 0
counts = {
    "downloaded": 0,
    "reused": 0,
    "failed": 0,
}

print(
    f"Preparing {total} local album covers...",
    flush=True,
)

with ThreadPoolExecutor(
    max_workers=min(10, total)
) as executor:
    futures = [
        executor.submit(fetch, job)
        for job in jobs.items()
    ]

    for future in as_completed(futures):
        result = future.result()
        counts[result] += 1
        finished += 1

        if finished == total or finished % 8 == 0:
            print(
                f"Album covers: {finished}/{total}",
                flush=True,
            )

print(
    "Album artwork ready: "
    f"{counts['downloaded']} downloaded, "
    f"{counts['reused']} reused, "
    f"{counts['failed']} unavailable",
    flush=True,
)
