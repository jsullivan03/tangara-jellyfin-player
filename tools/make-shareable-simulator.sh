#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d)"
OUTPUT="${1:-$ROOT/handoff/tangara-jellyfin-simulator-share-$STAMP.tar.gz}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/tangara-jellyfin-simulator"
mkdir -p "$PKG/lib" "$PKG/tools"

copy_tree() {
  local source="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"
  cp -a "$source" "$destination"
}

copy_tree "$ROOT/lua" "$PKG/lua"
copy_tree "$ROOT/desktop-sim" "$PKG/desktop-sim"
copy_tree "$ROOT/lib/luavgl" "$PKG/lib/luavgl"
copy_tree "$ROOT/lib/drflac" "$PKG/lib/drflac"
if [[ -d "$ROOT/lib/lvgl" ]]; then
  copy_tree "$ROOT/lib/lvgl" "$PKG/lib/lvgl"
  rm -rf "$PKG/lib/lvgl/.git"
fi
cp "$ROOT/tools/run-tangara-regressions.sh" "$PKG/tools/run-tangara-regressions.sh"
cp "$ROOT/tools/bootstrap-simulator-deps.sh" "$PKG/tools/bootstrap-simulator-deps.sh"
cp "$ROOT/.gitignore" "$PKG/.gitignore"
cp "$ROOT/REUSE.toml" "$PKG/REUSE.toml"
copy_tree "$ROOT/LICENSES" "$PKG/LICENSES"

rm -rf \
  "$PKG/desktop-sim/build" \
  "$PKG/desktop-sim/runtime" \
  "$PKG/desktop-sim/sd" \
  "$PKG/desktop-sim/.tangara-artwork"
rm -f \
  "$PKG/desktop-sim/tangara-sim.env" \
  "$PKG/desktop-sim"/*.log \
  "$PKG/desktop-sim"/*.pid

# Reject private/CGNAT IPv4 literals and credential-bearing URLs in the staged
# package. Loopback/documentation addresses remain acceptable examples.
python3 - "$PKG" <<'PY'
import ipaddress
import os
import re
import sys

root = sys.argv[1]
ip_re = re.compile(rb'(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])')
credential_url = re.compile(rb'https?://[^/\s:@]+:[^/\s@]+@')
problems = []

for base, _, files in os.walk(root):
    for name in files:
        path = os.path.join(base, name)
        try:
            data = open(path, 'rb').read()
        except OSError:
            continue
        if b'\x00' in data[:4096]:
            continue
        if credential_url.search(data):
            problems.append((path, 'credential-bearing URL'))
        for raw in ip_re.findall(data):
            try:
                ip = ipaddress.ip_address(raw.decode('ascii'))
            except ValueError:
                continue
            if ip.is_loopback or ip.is_unspecified:
                continue
            # ipaddress treats the RFC 5737 documentation blocks as private in
            # some Python versions; explicitly allow them as examples.
            if ip in ipaddress.ip_network('192.0.2.0/24') or \
               ip in ipaddress.ip_network('198.51.100.0/24') or \
               ip in ipaddress.ip_network('203.0.113.0/24'):
                continue
            if ip.is_private or ip in ipaddress.ip_network('100.64.0.0/10'):
                problems.append((path, f'private/CGNAT IP literal {ip}'))

if problems:
    for path, reason in problems:
        print(f'REJECT {path}: {reason}', file=sys.stderr)
    sys.exit(3)
PY

mkdir -p "$(dirname "$OUTPUT")"
tar -C "$STAGE" -czf "$OUTPUT" tangara-jellyfin-simulator
printf 'Created %s\n' "$OUTPUT"
sha256sum "$OUTPUT"
