#!/usr/bin/env bash
# Tangara Jellyfin player regression runner (Phase 0).
# Read-only with respect to product data and companion topology.
# Never starts/stops/alters Docker containers.
# Never touches host port 8787.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LUA_BIN="${LUA_BIN:-lua}"
LUAC_BIN="${LUAC_BIN:-luac}"
SIM_BIN="${SIM_BIN:-$ROOT/desktop-sim/build/tangara-sim}"
# Per-test wall clock. Tests missing os.exit(0) under tangara-sim otherwise hang
# in the SDL loop; Phase 0 reports that as FAIL rather than rewriting tests.
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-60}"

OPTIONAL_LIVE=0
RUN_SYNTAX=1
CATEGORY=""
FAILURES=0
PASSES=0
SKIPPED=0
DECLARED=0

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

usage() {
  cat <<'EOF'
Usage: tools/run-tangara-regressions.sh [options]

Categories (choose one):
  --identity       Artist/album/local index identity tests
  --download       Sync/download state and related sync UI tests
  --navigation     Resume, favorites, viewport, backstack tests
  --rendering      Mini-player, marquee, artwork, layout tests
  --playback       Queue, transport, session, volume tests
  --all            All required categorized suites

Other:
  --optional-live  Also run optional live-companion tests (still no Docker)
  --no-syntax      Skip Lua syntax checks
  -h, --help       Show this help

Environment:
  LUA_BIN, LUAC_BIN     Override lua/luac binaries
  SIM_BIN               Override desktop-sim/build/tangara-sim path
  TEST_TIMEOUT_SEC      Per-test timeout seconds (default 60)

Notes:
  - Focused suites run under tangara-sim when they require LVGL so they match
    local practice. Pure syntax checks use luac only.
  - Product data under storage roots used by tests may be temp dirs created by
    tests themselves; this runner does not mutate SD/device libraries.
  - Optional live tests may contact companion 8788 if present; they never
    target 8787 and never manage containers.
  - This runner never starts, stops, or alters Docker containers.
  - It does not rewrite failing test expectations.
EOF
}

log() {
  printf '%s\n' "$*"
}

section() {
  printf '\n== %s ==\n' "$*"
}

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: required binary not found: $1"
    exit 2
  fi
}

# Optional live-companion tests: never required for category pass.
is_optional_live() {
  case "$1" in
    desktop-sim/sync_library_live_test.lua|\
    desktop-sim/sync_operation_live_test.lua|\
    desktop-sim/jellyfin_audible_playback_test.lua|\
    desktop-sim/sync_runtime_test.lua)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_luac_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log "MISSING $file"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  DECLARED=$((DECLARED + 1))
  if "$LUAC_BIN" -p "$file" >/dev/null 2>&1; then
    log "PASS  syntax $file"
    PASSES=$((PASSES + 1))
    return 0
  fi
  log "FAIL  syntax $file"
  "$LUAC_BIN" -p "$file" || true
  FAILURES=$((FAILURES + 1))
  return 1
}

test_needs_sim() {
  # Prefer sim for any test that loads LVGL, firmware backstack, or luavgl.
  grep -Eq "require\\([\"']lvgl[\"']\\)|require\\([\"']firmware_backstack[\"']\\)|require\\([\"']luavgl" "$1"
}

run_lua_test() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log "MISSING $file"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  if is_optional_live "$file"; then
    if [[ "$OPTIONAL_LIVE" -ne 1 ]]; then
      log "SKIP  optional-live $file"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  fi

  DECLARED=$((DECLARED + 1))
  local via="lua"
  local cmd=()
  if [[ -n "$TIMEOUT_BIN" ]]; then
    cmd=("$TIMEOUT_BIN" "${TEST_TIMEOUT_SEC}s")
  fi
  if test_needs_sim "$file"; then
    if [[ ! -x "$SIM_BIN" ]]; then
      log "FAIL  $file (tangara-sim missing: $SIM_BIN)"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
    cmd+=("$SIM_BIN")
    via="tangara-sim"
  else
    cmd+=("$LUA_BIN")
    via="lua"
  fi

  local out
  set +e
  out="$("${cmd[@]}" "$file" 2>&1)"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "PASS  $file ($via)"
    PASSES=$((PASSES + 1))
    return 0
  fi
  if [[ -n "$TIMEOUT_BIN" && $rc -eq 124 ]]; then
    log "FAIL  $file ($via TIMEOUT ${TEST_TIMEOUT_SEC}s)"
  else
    log "FAIL  $file ($via exit $rc)"
  fi
  printf '%s\n' "$out" | tail -n 40
  FAILURES=$((FAILURES + 1))
  return 1
}

run_list() {
  local label="$1"
  shift
  section "$label"
  local f
  for f in "$@"; do
    # Continue after failures so the summary lists all broken suites.
    run_lua_test "$f" || true
  done
}

syntax_check_product() {
  section "Lua syntax (product modules)"
  local files=(
    lua/jellyfin_artist_identity.lua
    lua/jellyfin_album_identity.lua
    lua/jellyfin_track_identity.lua
    lua/jellyfin_local_index.lua
    lua/jellyfin_virtual_list.lua
    lua/jellyfin_mini_player.lua
    lua/jellyfin_playback_session.lua
    lua/jellyfin_marquee.lua
    lua/jellyfin_navigation.lua
    lua/jellyfin_sync_ui.lua
    lua/sync_download_state.lua
    lua/sync_runtime.lua
    lua/sync_reconcile.lua
    lua/sync_apply.lua
  )
  local f
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      run_luac_file "$f" || true
    else
      log "SKIP  missing module $f"
      SKIPPED=$((SKIPPED + 1))
    fi
  done
}

IDENTITY_TESTS=(
  desktop-sim/jellyfin_identity_canonical_test.lua
  desktop-sim/jellyfin_local_artists_dedupe_test.lua
  desktop-sim/jellyfin_local_artists_lifecycle_test.lua
  desktop-sim/jellyfin_local_index_test.lua
  desktop-sim/jellyfin_local_index_cache_test.lua
  desktop-sim/jellyfin_sync_album_identity_state_test.lua
)

DOWNLOAD_TESTS=(
  desktop-sim/sync_offline_bootstrap_request_test.lua
  desktop-sim/sync_async_dispatch_acceptance_test.lua
  desktop-sim/sync_download_state_owner_test.lua
  desktop-sim/sync_download_placeholder_repair_test.lua
  desktop-sim/sync_download_state_startup_review_test.lua
  desktop-sim/jellyfin_sync_download_state_test.lua
  desktop-sim/jellyfin_sync_download_progress_test.lua
  desktop-sim/jellyfin_sync_completion_local_placeholder_test.lua
  desktop-sim/jellyfin_sync_mounted_download_icon_test.lua
  desktop-sim/jellyfin_sync_status_cell_geometry_test.lua
  desktop-sim/jellyfin_sync_album_identity_state_test.lua
  desktop-sim/sync_operation_queue_test.lua
  desktop-sim/sync_runtime_refresh_lifecycle_test.lua
  desktop-sim/sync_runtime_apply_failure_state_test.lua
  desktop-sim/sync_runtime_activity_indicator_test.lua
  desktop-sim/sync_runtime_test.lua
  desktop-sim/sync_reconcile_artwork_variants_test.lua
  desktop-sim/sync_manifest_cache_invalidation_test.lua
  desktop-sim/jellyfin_sync_new_refresh_test.lua
  desktop-sim/jellyfin_sync_new_async_lifecycle_test.lua
  desktop-sim/sync_catalog_refresh_lifecycle_test.lua
  desktop-sim/sync_library_live_test.lua
  desktop-sim/sync_operation_live_test.lua
)

# Phase-3-modified untracked resume/viewport tests are intentionally not
# declared here after the rollback; their accepted Phase-2 contents were not
# captured by the tracked-only checkpoint. Keep the files for forensic use,
# but do not let stale motion expectations define the stable baseline.
NAVIGATION_TESTS=(
  desktop-sim/jellyfin_sort_test.lua
  desktop-sim/jellyfin_album_first_focus_test.lua
  desktop-sim/jellyfin_favorites_selection_restore_test.lua
  desktop-sim/jellyfin_virtual_album_list_test.lua
  desktop-sim/jellyfin_continuous_virtual_scroll_test.lua
  desktop-sim/jellyfin_ui_lifecycle_test.lua
  desktop-sim/firmware_backstack_test.lua
  desktop-sim/jellyfin_firmware_lifecycle_characterization_test.lua
)

RENDERING_TESTS=(
  desktop-sim/jellyfin_mini_player_scrollbar_test.lua
  desktop-sim/jellyfin_now_playing_marquee_test.lua
  desktop-sim/jellyfin_now_playing_lotion_reset_test.lua
  desktop-sim/jellyfin_marquee_replacement_test.lua
  desktop-sim/jellyfin_album_header_marquee_test.lua
  desktop-sim/jellyfin_artists_layout_test.lua
  desktop-sim/jellyfin_sim_artwork_cache_test.lua
  desktop-sim/jellyfin_sync_artwork_recycle_visibility_test.lua
  desktop-sim/sync_artwork_cache_recycle_test.lua
  desktop-sim/jellyfin_eager_scroll_indicator_test.lua
)

PLAYBACK_TESTS=(
  desktop-sim/jellyfin_queue_screen_test.lua
  desktop-sim/jellyfin_queue_shuffle_mid_session_test.lua
  desktop-sim/jellyfin_now_playing_queue_action_test.lua
  desktop-sim/jellyfin_distinct_queue_playback_test.lua
  desktop-sim/jellyfin_now_playing_transport_test.lua
  desktop-sim/jellyfin_playback_test.lua
  desktop-sim/jellyfin_playback_session_mini_test.lua
  desktop-sim/jellyfin_playback_session_eof_test.lua
  desktop-sim/jellyfin_playback_stability_test.lua
  desktop-sim/jellyfin_global_volume_test.lua
  desktop-sim/jellyfin_play_queue_audio_test.lua
  desktop-sim/jellyfin_audible_playback_test.lua
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity|--download|--navigation|--rendering|--playback|--all)
      if [[ -n "$CATEGORY" ]]; then
        log "ERROR: only one category flag is allowed"
        exit 2
      fi
      CATEGORY="${1#--}"
      shift
      ;;
    --optional-live)
      OPTIONAL_LIVE=1
      shift
      ;;
    --no-syntax)
      RUN_SYNTAX=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "ERROR: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$CATEGORY" ]]; then
  usage
  exit 2
fi

require_bin "$LUA_BIN"
if [[ "$RUN_SYNTAX" -eq 1 ]]; then
  require_bin "$LUAC_BIN"
fi
if [[ ! -x "$SIM_BIN" ]]; then
  log "WARN: tangara-sim not executable at $SIM_BIN"
  log "WARN: LVGL-backed tests will fail until the simulator binary is built"
fi

log "Tangara regression runner"
log "root=$ROOT"
log "category=$CATEGORY"
log "optional_live=$OPTIONAL_LIVE"
log "sim_bin=$SIM_BIN"
log "test_timeout_sec=$TEST_TIMEOUT_SEC"
log "docker/containers: not touched"
log "port 8787: not touched"

if [[ "$RUN_SYNTAX" -eq 1 ]]; then
  syntax_check_product
fi

case "$CATEGORY" in
  identity)
    run_list "identity" "${IDENTITY_TESTS[@]}"
    ;;
  download)
    run_list "download" "${DOWNLOAD_TESTS[@]}"
    ;;
  navigation)
    run_list "navigation" "${NAVIGATION_TESTS[@]}"
    ;;
  rendering)
    run_list "rendering" "${RENDERING_TESTS[@]}"
    ;;
  playback)
    run_list "playback" "${PLAYBACK_TESTS[@]}"
    ;;
  all)
    run_list "identity" "${IDENTITY_TESTS[@]}"
    run_list "download" "${DOWNLOAD_TESTS[@]}"
    run_list "navigation" "${NAVIGATION_TESTS[@]}"
    run_list "rendering" "${RENDERING_TESTS[@]}"
    run_list "playback" "${PLAYBACK_TESTS[@]}"
    ;;
  *)
    log "ERROR: unsupported category $CATEGORY"
    exit 2
    ;;
esac

section "Summary"
log "declared=$DECLARED passes=$PASSES failures=$FAILURES skipped=$SKIPPED"
if [[ "$FAILURES" -gt 0 ]]; then
  log "RESULT: FAIL"
  exit 1
fi
log "RESULT: PASS"
exit 0
