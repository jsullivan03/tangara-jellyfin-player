# Tangara Premium Jellyfin Player — Project Handoff

**Checkpoint date:** 2026-07-27  
**Branch:** `custom-jellyfin-player`  
**Previous committed checkpoint:** `2c152960 Add dark playlist UI and consistent navigation`  
**Checkpoint commit target:** `Stabilize Jellyfin library UI and sorting`

## 1. Product direction

This fork is turning Tangara into a premium Jellyfin-first music player while retaining Tangara’s existing hardware controls, local SD playback, queue/playback foundation, power management, and offline capability.

The visual target is a modern dark interface inspired by Finamp and Spotify. The system should remain a real local music player rather than a thin streaming client.

Important constraints:

- One Jellyfin server and one Jellyfin account per Tangara.
- Jellyfin credentials and tokens remain on the backend where practical.
- Devices have limited storage, so full-library mirroring is not the default.
- Each device needs its own selective sync preferences and download queue.
- Sync should be resumable, storage-aware, and able to turn Wi-Fi off when finished.
- Local playback must remain usable without the sync server or network.

## 2. Confirmed working checkpoint

### Desktop development

- Stock Tangara firmware remains available in the repository.
- A real LVGL/Lua desktop simulator is working.
- Desktop hardware mocks and Jellyfin test fixtures are present.
- The simulator can load the current Jellyfin library from the sync backend.
- Album artwork can be prefetched for desktop testing.

### Library and playlists

- Modern dark Local Library and Playlists screens are implemented.
- Artists, Albums, Tracks, Favorites, normal playlists, and playlist contents use the shared dark list renderer.
- Playlist tracks show the track’s album artwork rather than reusing playlist artwork.
- Favorites uses a native star on a pure-black artwork tile.
- Individual artist pages no longer show a Sort row.
- Returning from an album, artist, track, or playlist subsection preserves the parent selection and does not sweep through the list.
- Returning from an individual artist page returns directly to the selected artist.
- Text alignment, scrolling labels, count badges, and dynamic Sort badges are stable.

### Sorting

- Artists use one direct Sort row that toggles `A-Z` and `Z-A`.
- Other sortable screens expose:
  - Alphabetical
  - Recently Added
- Highlighting a method changes the pending method.
- Enter toggles only that method’s direction:
  - `A-Z` / `Z-A`
  - `NEW` / `OLD`
- Moving between methods retains each method’s independent direction.
- Back/Escape applies the highlighted method and closes the popup.
- Opening the popup no longer scrolls the background list.
- Sort settings persist independently by screen.

### Shared UI lifecycle

- Marquee rendering is shared across Jellyfin list screens.
- The marquee scheduler uses a retained timer rather than disposable timers that could be finalized twice.
- The prior simulator crash in `luavgl_timer_delete` was resolved.
- Repeated screen opening and Sort-popup lifecycle tests pass.

### Backend and sync foundation

The repository already contains work for:

- Jellyfin device/account linking.
- Jellyfin Quick Connect controller.
- JSON POST and PUT support.
- Per-device sync preferences.
- Favorites and playlist source selection.
- Bidirectional Jellyfin library operations.
- Date-created metadata and Recently Added sorting.
- Device-specific manifest/download/reconcile flow.
- Local index generation and local library views.

## 3. Known unresolved issue

### Fresh entry still shows the Sort row

Desired behavior:

- When entering a sortable screen for the first time, the first media row should be selected and positioned at the top of the viewport.
- The Sort row should exist directly above it and require one upward wheel movement to reveal.

Current behavior:

- On fresh entry, the first media row is selected, but the Sort row remains visible.
- After entering a subsection and returning, the same screen behaves correctly: the first/previous row is positioned normally and Sort is above the viewport.

This is the only accepted unresolved regression in the current checkpoint.

### Do not repeat these failed approaches

Several experiments were reverted because they either did nothing or introduced navigation regressions:

- Depending on a `SCREEN_LOADED` flag. In the simulator logs, it stayed false.
- Re-running fresh-entry positioning whenever a parent screen resumed.
  - This caused visible list sweeps on return.
- Rebuilding the LVGL focus group while recording focus.
  - This could replace the saved artist with the final row.
- Invisible focus-anchor experiments.
  - They did not change the initial viewport.
- Calling `update_layout()`.
  - That method is not exposed by this Lua binding.
- Calling `scroll_to_y()`.
  - That method is not exposed by this Lua binding.
- A detached LVGL smoke test that created objects without loading the test screen.
  - It could not validate real scrolling.
- Timer probes that were blocked by the same invalid lifecycle condition.

The stable source deliberately restores the pre-regression `jellyfin_list_ui.lua`.

### Recommended next approach

Do not patch the current return/restoration path.

Build a minimal simulator test that loads an actual screen and proves the exact supported scrolling primitive before integrating it. A structural solution may be safer than another lifecycle timer, such as making the Sort row an intentional row above the initial viewport rather than trying to correct the viewport after the screen appears.

## 4. Settings work that still needs to be built

A real top-level **Settings** section is still required. Planned sections:

- Playback
- Audio
- Display
- Wi-Fi
- Jellyfin
- Sync
- Storage
- Updates
- About

### Jellyfin settings

Move production configuration out of hardcoded simulator assumptions and expose:

- Sync server URL
- Device identity/name
- Link/account status
- Start or repeat Jellyfin linking
- Linked Jellyfin user
- Connection test/status
- Unlink/reset controls
- Last successful backend contact
- Clear error states

The design remains one Jellyfin server and one account per Tangara.

Existing backend flow to preserve:

- `POST /devices/<device-id>/link/start`
- `GET /devices/<device-id>/link/status`
- `GET /devices/<device-id>/sync/sources`
- `GET /devices/<device-id>/sync/preferences`
- `PUT /devices/<device-id>/sync/preferences`

### Sync settings

The Settings section should expose:

- Manual, automatic, or charging-only sync
- Favorites sync toggle
- Selective playlist sync
- Storage limit
- Remove-from-device behavior
- Wi-Fi-off-after-sync behavior
- Retry/cancellation controls
- Sync and download status
- Last sync time and last error

The sync and Streamrip/Add Music screens should include a storage visualization so requests cannot silently exceed device capacity.

## 5. Clock and status-bar work to redo

The clock is visually present in the status bar, but its backend is still basic:

```lua
os.date("%H:%M")
```

It does not yet provide reliable:

- Network time synchronization
- Timezone selection
- Daylight-saving handling
- Time retention across restarts or offline periods
- User-selectable 12-hour or 24-hour display
- Settings integration

Required work:

1. Add a time service/backend rather than formatting the host/device clock directly in each screen.
2. Synchronize time after Wi-Fi becomes available.
3. Store timezone and display format in Settings.
4. Apply DST through a timezone-aware source rather than a fixed offset.
5. Keep a usable cached time when offline.
6. Let the status bar subscribe to one shared clock source.
7. Decide whether clock visibility belongs in Display settings.

The current status-bar visuals can remain, but the clock source and settings path need to be redone cleanly.

## 6. Sync/download work still open

The intended sync sequence remains:

1. Connect to known Wi-Fi.
2. Fetch the device manifest.
3. Compare manifest data with local storage/index.
4. Check available space.
5. Queue missing or changed files.
6. Download to temporary `.part` names.
7. Resume interrupted downloads.
8. Verify completed files.
9. Atomically rename completed files.
10. Rebuild/update the local library.
11. Reconcile removals and operations.
12. Turn Wi-Fi off when finished, if enabled.

Remaining implementation/polish:

- Robust `.part` file handling
- Download cancellation
- Retry limits and backoff
- Free-space checks before and during sync
- Storage-limit enforcement
- Bulk remove-from-device rules
- Automatic versus manual versus charging-only sync
- Clear per-device queue and progress UI
- Pause or reduce heavy sync work during high-resolution playback
- Useful offline, timeout, and server-error states
- Recovery testing after power loss or network interruption

## 7. UI work still open

- Finish the top-level Settings screens and navigation.
- Finish production backend configuration inside Settings.
- Finish the clock/time service.
- Add first-boot Wi-Fi and Jellyfin setup flow.
- Add Sync, Add Music/Streamrip, Downloads, Storage, and error-state screens.
- Continue Now Playing polish toward the Finamp/Spotify-inspired target, including the blurred album-cover background.
- Confirm queue behavior and navigation from Now Playing.
- Test long library lists for performance and memory use.
- Add useful loading states instead of blank screens.
- Keep wheel behavior, focus restoration, and Back behavior consistent.
- The current Favorites star is acceptable but may be revisited later as low-priority polish.

## 8. Stable core hashes at this checkpoint

These hashes identify the confirmed source state before committing:

```text
90eee082025301cc8820a6b35a6753f484e19cda5a00af778a238bd12b6c33ca  lua/jellyfin_list_ui.lua
f614fcb3691a74f0b7811b4f7b6bf0669bde059ea5a1f23c1a80995c74f86187  lua/jellyfin_local_library.lua
616a9cb9bb878c4ce7aa4a8227c279bc25cd5fde394160ad0606222d52bb1f98  lua/jellyfin_library.lua
eb0ddc72ce5ce8f01632d5b315deb22aa9861f8dc3e5840dce8fee5b3464fec5  lua/jellyfin_sort.lua
8dc333dd3358061c50866a403d4fc5b3b5d75aaeec09553c39bfe66b90013e1a  lua/jellyfin_marquee.lua
dc24b099b4ba4204e7240fe7e5b3e321a448a3715360d0809d95109dd7357f18  desktop-sim/jellyfin_ui_lifecycle_test.lua
f25d733b9f6e54592ff0ba1b4a75bb570c7be9f49355512540817604a1948110  desktop-sim/jellyfin_sort_interaction_test.lua
```

## 9. Tests to run before future UI commits

```bash
luac -p \
  lua/jellyfin_marquee.lua \
  lua/jellyfin_list_ui.lua \
  lua/jellyfin_sort.lua \
  lua/jellyfin_local_index.lua \
  lua/jellyfin_local_library.lua \
  lua/jellyfin_library.lua \
  desktop-sim/jellyfin_sort_modes_test.lua \
  desktop-sim/jellyfin_sort_persistence_test.lua \
  desktop-sim/jellyfin_ui_lifecycle_test.lua \
  desktop-sim/jellyfin_sort_interaction_test.lua \
  desktop-sim/jellyfin_local_index_test.lua

python3 -m py_compile \
  desktop-sim/prefetch_local_album_artwork.py \
  server/tangara-sync/*.py

./desktop-sim/build/tangara-sim \
  desktop-sim/jellyfin_sort_modes_test.lua

./desktop-sim/build/tangara-sim \
  desktop-sim/jellyfin_sort_persistence_test.lua

./desktop-sim/build/tangara-sim \
  desktop-sim/jellyfin_ui_lifecycle_test.lua

./desktop-sim/build/tangara-sim \
  desktop-sim/jellyfin_sort_interaction_test.lua

./desktop-sim/build/tangara-sim \
  desktop-sim/jellyfin_local_index_test.lua

git diff --check
```

## 10. Next-session starting point

1. Read this handoff before changing UI lifecycle code.
2. Confirm the branch and clean working tree.
3. Launch the current simulator and verify the checkpoint behavior.
4. Treat fresh-entry Sort visibility as a separate isolated task.
5. Do not modify return/restoration behavior while solving fresh entry.
6. After that isolated fix, build Settings and the shared clock/time backend.
7. Continue sync/storage/error-state work only after Settings owns the relevant configuration.
