# Tangara Jellyfin Player — Project Handoff

**Checkpoint date:** 2026-07-27
**Branch:** `custom-jellyfin-player`
**Checkpoint:** the commit containing this handoff
**Parent checkpoint:** `61312be7 Measure Tangara local library scaling`

## 1. Project goal

This fork is turning Tangara into a premium Jellyfin-first ESP32 music player while preserving:

- Local SD-card playback
- Offline use
- Tangara’s physical controls
- Existing audio pipeline and queue foundation
- Selective per-device Jellyfin synchronization
- Wi-Fi only when needed
- A compact, dark, modern interface

The target is not a thin streaming client. Music should be synchronized to local storage and remain playable without the backend.

## 2. Development rules established during this work

- Make one focused change at a time.
- Use the real LVGL desktop simulator for UI work.
- Automated tests do not count as visual confirmation.
- Do not commit until automated tests and the interactive simulator both pass.
- Long changes should use rollback-guarded `.sh` scripts.
- Do not rerun old patches unless explicitly directed.
- Use short, paste-safe terminal commands when the user may send them through Discord.
- `status` is read-only in zsh; use `rc` for exit codes.
- Never claim a behavior is fixed only because a headless test passed.
- Preserve the last known-good commit before structural work.

## 3. Important commits

```text
0f8765d4  Stabilize Jellyfin library UI and sorting
e6cfa659  Fix Tangara library navigation and simulator parity
e0a82fc2  Cache Tangara local library index
61312be7  Measure Tangara local library scaling
```

The commit containing this file adds verified top-level Tracks virtualization and the updated handoff.

## 4. Verified Local Library behavior

The following has been confirmed interactively:

- Dark Artists, Albums, Tracks, Playlists, Favorites, and collection screens work.
- Fresh entry selects the first media row with Sort above the viewport.
- One upward movement reveals Sort.
- Artists directly toggle `A-Z` and `Z-A`.
- Other sortable screens support:
  - Alphabetical
  - Recently Added
- Each method retains its own direction.
- Closing Sort applies the selected method.
- Changing Sort on the virtual Tracks screen resets to logical result 1.
- The first and second moves below Sort select logical results 1 and 2 without skipping.
- Returning from artist detail restores the exact selected artist.
- Returning from a track after sorting restores that selected track.
- Individual artist pages do not show Sort.
- Opening Sort does not move the background list.
- Playlist songs use album artwork.
- Favorites has an acceptable star tile on pure black.
- Text alignment, marquee behavior, badges, and focus restoration are stable.

## 5. Interactive simulator launch

Use the custom Jellyfin launcher, not `stock.lua` or `ui.lua`:

```bash
cd ~/tangara-fw; pkill -x tangara-sim 2>/dev/null || true; TANGARA_SIM_SERVER_URL=http://100.99.105.21:8788 TANGARA_SIM_DEVICE_ID=tangara-sim-001 ./desktop-sim/build/tangara-sim desktop-sim/jellyfin_library.lua
```

Notes:

- `desktop-sim/ui.lua` is only a small smoke-test screen.
- `desktop-sim/stock.lua` opens Tangara’s original gray stock menu.
- Automated test scripts open and close immediately.
- The custom launcher above is the visual test target used for the verified Jellyfin UI.

## 6. Shared defects that were fixed

### Luavgl vertical scrolling

The shared Lua binding for:

```lua
object:scroll_to { y = value }
```

incorrectly called `lv_obj_scroll_to_x()`.

It now calls `lv_obj_scroll_to_y()`. This shared source is used by both Tangara and the simulator.

### Native Lua screen resume ordering

Tangara previously called the parent Lua screen’s `on_show()` before restoring that screen’s Luavgl root and focus group.

The corrected order is:

```text
restore screen root
restore screen focus group
run on_show
attach input to the active group
```

The firmware-parity simulator mirrors this order.

### Explicit selection restoration

Selection is now tracked by stable media IDs rather than relying only on whichever LVGL object happens to emit focus events.

Selection updates are suppressed while a focus group is being rebuilt so automatic LVGL focus cannot overwrite the saved item.

## 7. Simulator parity infrastructure

The repository contains:

```text
desktop-sim/firmware_backstack.c
desktop-sim/firmware_backstack.h
desktop-sim/firmware_backstack_test.lua
desktop-sim/jellyfin_firmware_lifecycle_characterization_test.lua
desktop-sim/luavgl_scroll_binding_test.lua
desktop-sim/FIRMWARE_PARITY.md
```

These tests validate:

- Separate root/content objects
- Separate focus groups per screen
- Firmware-order show/hide behavior
- Native-style pop/resume behavior
- Correct vertical scroll binding
- Fresh-entry Sort positioning
- Stable middle-item restoration

The ordinary interactive launcher still uses the existing desktop integration. The parity backstack is currently strongest as an automated lifecycle test target.

## 8. Local Library index cache

`jellyfin_local_index.lua` now caches one normalized in-memory index.

Repeated Local Library screen openings no longer:

- Reread the manifest
- Rebuild Artists, Albums, and Tracks
- Probe every downloaded media file

The cache is invalidated when:

- A new manifest is saved
- Sync changes local files
- A generation change is explicitly recorded

Relevant files:

```text
lua/jellyfin_local_index.lua
lua/jellyfin_local_index_generation.lua
lua/sync_apply.lua
lua/sync_manifest_cache.lua
```

Relevant tests:

```text
desktop-sim/jellyfin_local_index_cache_test.lua
desktop-sim/sync_apply_index_invalidation_test.lua
desktop-sim/sync_manifest_cache_invalidation_test.lua
```

## 9. Tracks virtualization

Only the top-level Tracks screen is virtualized so far.

It uses:

```text
7 reusable media rows
```

instead of one LVGL row per track.

Relevant files:

```text
lua/jellyfin_virtual_track_list.lua
lua/jellyfin_list_ui.lua
lua/jellyfin_local_library.lua
desktop-sim/jellyfin_virtual_track_list_test.lua
desktop-sim/local_library_virtualized_case.lua
desktop-sim/run_local_library_virtualized.sh
desktop-sim/TRACK_VIRTUALIZATION.md
```

Virtualized behavior verified:

- Row recycling
- Forward and backward navigation
- Activation
- Long press
- Sorting
- Sort-to-first-result transition
- No skipped results below Sort
- Child-screen restoration
- Constant row-pool size

Artists, Albums, Playlists, Favorites, and detail screens still use eager rows.

## 10. Performance measurements

### Original eager Tracks screen

| Tracks | Create time | Extra LVGL objects | Lua UI memory |
|---:|---:|---:|---:|
| 118 | 65.435 ms | 858 | 738.2 KB |
| 500 | 290.727 ms | 3,532 | 3,107.6 KB |
| 1,000 | 752.206 ms | 7,032 | 6,139.2 KB |
| 5,000 | 18,991.899 ms | 35,032 | 32,023.0 KB |

### Virtualized Tracks screen

| Tracks | Create time | Extra LVGL objects | Lua UI memory |
|---:|---:|---:|---:|
| 118 | 5.870 ms | 81 | 66.2 KB |
| 500 | 11.755 ms | 81 | 104.2 KB |
| 1,000 | 22.999 ms | 81 | 80.2 KB |
| 5,000 | 118.229 ms | 81 | 316.8 KB |

At 5,000 tracks, creation improved from roughly 19 seconds to 118 ms. LVGL object count became constant.

Desktop RSS is not directly equivalent to ESP32 memory. LVGL object count, Lua allocations, construction time, and hardware heap measurements are the more useful embedded indicators.

## 11. Tests to preserve

```bash
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_virtual_track_list_test.lua
./desktop-sim/run_local_library_virtualized.sh
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_local_index_cache_test.lua
./desktop-sim/build/tangara-sim desktop-sim/sync_apply_index_invalidation_test.lua
./desktop-sim/build/tangara-sim desktop-sim/sync_manifest_cache_invalidation_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_local_index_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_firmware_lifecycle_characterization_test.lua
./desktop-sim/build/tangara-sim desktop-sim/luavgl_scroll_binding_test.lua
./desktop-sim/build/tangara-sim desktop-sim/firmware_backstack_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_sort_modes_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_sort_persistence_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_ui_lifecycle_test.lua
./desktop-sim/build/tangara-sim desktop-sim/jellyfin_sort_interaction_test.lua
```

## 12. Remaining optimization work

### Virtualize other potentially large screens

The reusable-row architecture should be generalized carefully to:

1. Albums
2. Artists
3. Playlist/Favorites contents
4. Other large collections

Do one screen type at a time and preserve its specific visual layout.

### Shared status service

Each Jellyfin screen can still create a status/clock timer. Replace per-screen polling with one shared service whose visible views subscribe and hidden views unsubscribe.

### Sort persistence

Sort popup navigation can still write preference state more often than necessary.

Preferred design:

- Copy applied Sort state into a draft
- Change the draft while the popup is open
- Apply and persist once when closing

### Playlist view cache

The Jellyfin playlist/favorites working view still performs JSON loading, copying, operation projection, and reindexing more often than ideal. Add explicit caching and invalidation similar to the Local Library index.

### Background sync work

Some sync polling and filesystem/JSON work still occurs from LVGL timer callbacks. Long-term, move heavier work to a low-priority worker and deliver compact results to the UI.

## 13. Fonts and international metadata

This remains an important unfinished requirement.

The simulator and Tangara must load the exact same compiled font artifacts.

Minimum desired metadata coverage:

- Spanish and Latin accents
- Polish and Latin Extended
- Cyrillic
- Greek
- Japanese
- Simplified and Traditional Chinese
- Korean

Recommended architecture:

- Built-in Latin Extended core font
- Optional regional font packs
- Backend-generated library-specific glyph subsets for CJK efficiency
- LVGL fallback chain
- Automated multilingual test screen

Complex scripts such as Arabic, Hebrew, and Indic scripts also require shaping and bidirectional support, not only glyph files.

Do not use desktop system fonts as proof that Tangara supports a glyph.

## 14. Settings and clock work

A real top-level Settings section is still required:

- Playback
- Audio
- Display
- Language and Text
- Wi-Fi
- Jellyfin
- Sync
- Storage
- Updates
- About

The status-bar clock currently relies on basic local time formatting. It still needs:

- Network time synchronization
- Timezone
- DST
- 12/24-hour preference
- Offline retained time
- One shared time service
- Settings integration

Jellyfin Settings should expose:

- Backend URL
- Device identity/name
- Link status
- Link/relink flow
- Linked user
- Connection test
- Last backend contact
- Unlink/reset

## 15. Sync work still open

The intended sync sequence is:

```text
connect Wi-Fi
fetch device manifest
compare local state
check storage
download to .part
resume interrupted files
verify
atomically rename
update local index
reconcile removals and operations
turn Wi-Fi off when configured
```

Remaining work includes:

- Robust partial-file handling
- Cancellation
- Retry/backoff
- Storage-limit enforcement
- Manual/automatic/charging-only modes
- Download queue and progress UI
- Playback-aware throttling
- Offline and server-error states
- Power-loss recovery testing

## 16. Hardware validation still needed

The desktop simulator proves UI logic but not:

- PSRAM fragmentation
- Internal heap pressure
- SD-card contention
- Audio underruns
- Wi-Fi/audio interaction
- Physical wheel behavior
- Real font storage and decoding

Before deeper feature work, run a complete ESP-IDF build:

```bash
cd ~/tangara-fw; git submodule update --init --recursive; . ./.env; idf.py build
```

Later hardware profiling should record:

- Free and minimum internal heap
- Largest free internal block
- PSRAM free/minimum/largest block
- Task stack high-water marks
- Audio underruns
- SD read latency
- UI callback time
- Sync activity during playback

Do not flash unless the device is connected and flashing is intentionally requested.

## 17. Recommended next task

After confirming the firmware build:

1. Generalize the virtual row engine for Albums while preserving its existing artwork and subtitle layout.
2. Benchmark 100, 500, 1,000, and 5,000 albums.
3. Verify fresh Sort behavior, sorting, activation, and restoration interactively.
4. Commit before moving to Artists or Playlists.

A shared status/clock service is also a reasonable next task if development shifts from Local Library scaling to Settings.

## 18. New-chat workflow

In a new conversation:

1. Upload this file.
2. Upload the generated `tangara-next-chat-<commit>.tar.gz`.
3. Paste `NEW_CHAT_STARTER_PROMPT.txt`.
4. Ask the assistant to read the handoff and inspect the archive before proposing changes.
5. Do not rely on conversation memory or old patch scripts as source of truth.
