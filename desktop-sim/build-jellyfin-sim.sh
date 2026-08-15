#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/tools/bootstrap-simulator-deps.sh"

cmake -S desktop-sim -B desktop-sim/build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build desktop-sim/build --parallel

printf 'Built %s\n' "$ROOT/desktop-sim/build/tangara-sim"
