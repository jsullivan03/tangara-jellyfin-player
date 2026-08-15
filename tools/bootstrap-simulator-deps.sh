#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LVGL_DIR="$ROOT/lib/lvgl"
LVGL_REPO="https://github.com/lvgl/lvgl.git"
LVGL_COMMIT="e1c0b21b2723d391b885de4b2ee5cc997eccca91"
LVGL_VERSION="9.1.0"

version_from_tree() {
    local header="$1/src/lv_version.h"
    [[ -f "$header" ]] || return 1
    local major minor patch
    major="$(awk '$2 == "LVGL_VERSION_MAJOR" {print $3; exit}' "$header")"
    minor="$(awk '$2 == "LVGL_VERSION_MINOR" {print $3; exit}' "$header")"
    patch="$(awk '$2 == "LVGL_VERSION_PATCH" {print $3; exit}' "$header")"
    [[ -n "$major" && -n "$minor" && -n "$patch" ]] || return 1
    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

if [[ -d "$LVGL_DIR" ]]; then
    actual="$(version_from_tree "$LVGL_DIR" || true)"
    if [[ "$actual" != "$LVGL_VERSION" ]]; then
        echo "ERROR: existing $LVGL_DIR is not LVGL $LVGL_VERSION (found '${actual:-unknown}')." >&2
        echo "Refusing to replace an existing dependency tree." >&2
        exit 1
    fi
    echo "LVGL $actual already present; leaving it untouched."
    exit 0
fi

command -v git >/dev/null 2>&1 || {
    echo "ERROR: git is required to fetch pinned LVGL $LVGL_VERSION." >&2
    exit 1
}

mkdir -p "$ROOT/lib"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tangara-lvgl.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching LVGL $LVGL_VERSION at pinned commit $LVGL_COMMIT ..."
git clone --quiet --filter=blob:none --no-checkout "$LVGL_REPO" "$tmp/lvgl"
git -C "$tmp/lvgl" checkout --quiet --detach "$LVGL_COMMIT"

actual="$(version_from_tree "$tmp/lvgl" || true)"
if [[ "$actual" != "$LVGL_VERSION" ]]; then
    echo "ERROR: pinned LVGL checkout reported '${actual:-unknown}', expected $LVGL_VERSION." >&2
    exit 1
fi

mv "$tmp/lvgl" "$LVGL_DIR"
echo "Installed LVGL $LVGL_VERSION ($LVGL_COMMIT) into lib/lvgl."
