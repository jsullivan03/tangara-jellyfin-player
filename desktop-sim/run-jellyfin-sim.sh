#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${TANGARA_SIM_CONFIG:-$ROOT/desktop-sim/tangara-sim.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

: "${TANGARA_SIM_SERVER_URL:?Set TANGARA_SIM_SERVER_URL or copy desktop-sim/tangara-sim.env.example to desktop-sim/tangara-sim.env}"
TANGARA_SIM_DEVICE_ID="${TANGARA_SIM_DEVICE_ID:-tangara-sim-001}"
TANGARA_SIM_AUDIO_MODE="${TANGARA_SIM_AUDIO_MODE:-audible}"

export TANGARA_SIM_SERVER_URL
export TANGARA_SIM_DEVICE_ID
export TANGARA_SIM_AUDIO_MODE

SIM_BIN="$ROOT/desktop-sim/build/tangara-sim"
if [[ ! -x "$SIM_BIN" ]]; then
  printf 'Simulator binary is missing. Run desktop-sim/build-jellyfin-sim.sh first.\n' >&2
  exit 2
fi

cd "$ROOT"
exec "$SIM_BIN" desktop-sim/jellyfin_library.lua
