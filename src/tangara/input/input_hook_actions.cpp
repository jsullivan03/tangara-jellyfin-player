/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_hook_actions.hpp"

#include <cstdint>

#include "indev/lv_indev.h"

#include "events/event_queue.hpp"
#include "ui/ui_events.hpp"

namespace input {
namespace actions {

auto select() -> HookCallback {
  return HookCallback{.name = "select", .fn = [&](lv_indev_data_t* d) {
                        d->state = LV_INDEV_STATE_PRESSED;
                      }};
}

auto scrollUp() -> HookCallback {
  return HookCallback{.name = "scroll_up",
                      .fn = [&](lv_indev_data_t* d) { d->enc_diff = -1; }};
}

auto scrollDown() -> HookCallback {
  return HookCallback{.name = "scroll_down",
                      .fn = [&](lv_indev_data_t* d) { d->enc_diff = 1; }};
}

auto scrollToTop() -> HookCallback {
  return HookCallback{.name = "scroll_to_top", .fn = [&](lv_indev_data_t* d) {
                        d->enc_diff = -10;
                      }};
}

auto scrollToBottom() -> HookCallback {
  return HookCallback{
      .name = "scroll_to_bottom",
      .fn = [&](lv_indev_data_t* d) { d->enc_diff = 10; }};
}

auto goBack() -> HookCallback {
  return HookCallback{.name = "back", .fn = [&](lv_indev_data_t* d) {
                        events::Ui().Dispatch(ui::internal::BackPressed{});
                      }};
}

auto volumeUp() -> HookCallback {
  return HookCallback{.name = "volume_up", .fn = [&](lv_indev_data_t* d) {
                        events::Audio().Dispatch(audio::StepUpVolume{});
                      }};
}

auto volumeDown() -> HookCallback {
  return HookCallback{.name = "volume_down", .fn = [&](lv_indev_data_t* d) {
                        events::Audio().Dispatch(audio::StepDownVolume{});
                      }};
}

auto nextTrack(audio::TrackQueue& queue) -> HookCallback {
  return HookCallback{.name = "next_track", .fn = [&](lv_indev_data_t* d) {
                        queue.next();
                      }};
}

auto skipBack() -> HookCallback {
  return HookCallback{.name = "skip_back", .fn = [&](lv_indev_data_t* d) {
    events::Ui().Dispatch(ui::SeekBack{.seconds = 25});
  }};
}

auto prevTrack(audio::TrackQueue& queue) -> HookCallback {
  return HookCallback{.name = "prev_track", .fn = [&](lv_indev_data_t* d) {
                        queue.previous();
                      }};
}

auto togglePlayPause() -> HookCallback {
  return HookCallback{.name = "toggle_play_pause", .fn = [&](lv_indev_data_t* d) {
                        events::Audio().Dispatch(audio::TogglePlayPause{});
                      }};
}

auto longPress() -> HookCallback {
  return HookCallback{.name = "open_context_menu", .fn = [&](lv_indev_data_t* d) {
                        auto indev = lv_indev_active();
                        if (!indev) return;
                        auto g = lv_indev_get_group(indev);
                        if (!g) return;
                        auto obj = lv_group_get_focused(g);
                        if (!obj) return;
                        lv_obj_send_event(obj, LV_EVENT_LONG_PRESSED, NULL);
                      }};
}

}  // namespace actions
}  // namespace input
