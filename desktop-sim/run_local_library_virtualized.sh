#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
OUTPUT="${2:-$REPO/build/local-library-virtualized.csv}"
BINARY="$REPO/desktop-sim/build/tangara-sim"
CASE="$REPO/desktop-sim/local_library_virtualized_case.lua"

cd "$REPO"

test -x "$BINARY"
test -f "$CASE"
mkdir -p "$(dirname "$OUTPUT")"

printf '%s\n' 'tracks,create_ms,pool_rows,empty_objects,data_objects,screen_objects,object_delta,timers,empty_lua_kb,data_lua_kb,screen_lua_kb,lua_ui_delta_kb,empty_rss_kb,data_rss_kb,screen_rss_kb,rss_ui_delta_kb,max_rss_kb' > "$OUTPUT"

for tracks in 118 500 1000 5000; do
    TANGARA_VIRTUAL_TRACKS="$tracks" \
    TANGARA_VIRTUAL_OUTPUT="$OUTPUT" \
    "$BINARY" "$CASE"
done

python3 - "$OUTPUT" <<'PY'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = list(csv.DictReader(path.open()))

assert [int(row["tracks"]) for row in rows] == [118, 500, 1000, 5000]
assert all(int(row["pool_rows"]) <= 7 for row in rows)

object_deltas = [int(row["object_delta"]) for row in rows]
lua_deltas = [float(row["lua_ui_delta_kb"]) for row in rows]
create_times = [float(row["create_ms"]) for row in rows]

assert all(value < 120 for value in object_deltas)
assert max(object_deltas) - min(object_deltas) < 12
assert all(value > 0 for value in lua_deltas)
assert create_times[-1] < 2000

print(f"Virtualized CSV: {path}")
print("Local Library Tracks virtualization benchmark passed")
PY

cat "$OUTPUT"
