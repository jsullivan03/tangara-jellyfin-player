# Desktop simulator firmware parity

The desktop simulator now contains an opt-in native-style backstack module named
`firmware_backstack`.

It mirrors the firmware lifecycle used by `UiState::PushLuaScreen`,
`UiState::PushScreen`, `UiState::PopLuaScreen`, and `UiTask::Main`:

1. Create a separate native LVGL screen root, content object, alert object, and
   focus group.
2. Set Luavgl's parent root and the default focus group.
3. Call the Lua screen's `create_ui` method.
4. Hide the previous screen.
5. Show the new screen.
6. Load the native screen root on the next simulator service pass.
7. Attach keyboard and wheel input to that screen's focus group.

The existing lightweight mock backstack remains available while production UI
code is frozen. New lifecycle work must use `firmware_backstack` and its tests.

## Current characterization

`jellyfin_firmware_lifecycle_characterization_test.lua` now proves three
shared Local Library lifecycle rules:

- The restored Lua screen's Luavgl root and default focus group are active
  before its `on_show` callback runs. This rule is implemented in both
  `screens::Lua::onShown()` and the desktop parity adapter.
- Fresh entry places Sort above the viewport through the corrected shared
  vertical-scroll binding.
- Returning from artist detail restores the selected artist by stable item ID
  instead of resetting focus to the first row.

The old lightweight simulator hid the native pop-ordering problem because it
used one global focus group. The parity harness exposed it, and the synchronized
firmware/parity fix now prevents a parent screen from installing its controls
into the outgoing child screen's group. Local Library rows now retain stable
selection IDs across hide/show transitions. Data caching and list
virtualization remain the next production refactors.

## Scope

This module improves parity for screen hierarchy, loading, focus groups,
backstack ownership, and navigation callbacks. Hardware-only validation is
still required for audio timing, SD latency, Wi-Fi contention, PSRAM usage, and
physical wheel behavior.

Font parity is the next infrastructure stage. The simulator and firmware must
load the same generated font artifacts and run the same multilingual glyph
coverage tests rather than substituting desktop system fonts.

## Shared vertical scroll binding

Stage 1 fixes a shared Luavgl binding defect where `scroll_to({y = ...})` called `lv_obj_scroll_to_x()` instead of `lv_obj_scroll_to_y()`. Because firmware and desktop simulator compile the same binding source, one regression test now protects both targets. The Local Library initial viewport uses this supported shared API and no longer depends on a child `SCREEN_LOADED` event.

## Explicit selection restoration

Local Library row models now expose stable selection IDs. The active screen
records the ID on focus and restores the matching row only when the same screen
resumes. Fresh entry still uses the first content row and the initial Sort
viewport rule. This keeps navigation state out of transient LVGL group order.
