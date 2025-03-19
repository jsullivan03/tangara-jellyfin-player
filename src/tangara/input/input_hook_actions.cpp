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

}  // namespace actions
}  // namespace input
