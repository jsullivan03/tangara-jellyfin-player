/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_touch_wheel.hpp"

#include <cstdint>
#include <variant>

#include "indev/lv_indev.h"

#include "drivers/haptics.hpp"
#include "drivers/nvs.hpp"
#include "drivers/touchwheel.hpp"
#include "events/event_queue.hpp"
#include "input/input_device.hpp"
#include "input/input_hook_actions.hpp"
#include "input/input_trigger.hpp"
#include "lua/property.hpp"
#include "ui/ui_events.hpp"

#include "esp_timer.h"

namespace input {

TouchWheel::TouchWheel(drivers::NvsStorage& nvs,
                       drivers::TouchWheel& wheel,
                       audio::TrackQueue& queue)
    : nvs_(nvs),
      wheel_(wheel),
      queue_(queue),
      sensitivity_(static_cast<int>(nvs.ScrollSensitivity()),
                   [&](const lua::LuaValue& val) {
                     if (!std::holds_alternative<int>(val)) {
                       return false;
                     }
                     int int_val = std::get<int>(val);
                     if (int_val < 0 || int_val > UINT8_MAX) {
                       return false;
                     }
                     nvs.ScrollSensitivity(int_val);
                     threshold_ = calculateThreshold(int_val);
                     return true;
                   }),
      centre_("centre", actions::select(), {}, actions::longPress(), {}),
      up_("up", {}, {}, actions::scrollToTop(), actions::scrollToTop()),
      right_("right", {}),
      down_("down",
            {},
            {},
            actions::scrollToBottom(),
            actions::scrollToBottom()),
      left_("left", {}, {}, actions::goBack(), {}),
      locked_(false),
      is_scrolling_(false),
      threshold_(calculateThreshold(nvs.ScrollSensitivity())),
      is_first_read_(true),
      last_angle_(0),
      last_wheel_touch_time_(0),
      buttons_active_(false) {}

auto TouchWheel::activate_buttons(bool activate) -> void {
  if (activate) {
    up_.override(Trigger::State::kClick, {actions::skipBack()});
    left_.override(Trigger::State::kClick, {actions::prevTrack(queue_)});
    right_.override(Trigger::State::kClick, {actions::nextTrack(queue_)});
    down_.override(Trigger::State::kClick, {actions::togglePlayPause()});
  } else {
    up_.override(Trigger::State::kClick, std::nullopt);
    left_.override(Trigger::State::kClick, std::nullopt);
    right_.override(Trigger::State::kClick, std::nullopt);
    down_.override(Trigger::State::kClick, std::nullopt);
  }
  buttons_active_ = activate;
}

auto TouchWheel::read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void {
  if (locked_) {
    return;
  }

  wheel_.Update();
  auto wheel_data = wheel_.GetTouchWheelData();
  int8_t ticks = calculateTicks(wheel_data);

  if (!wheel_data.is_wheel_touched) {
    // User has released the wheel.
    is_scrolling_ = false;
    data->enc_diff = 0;
  } else if (ticks != 0) {
    // User is touching the wheel, and has just passed the sensitivity
    // threshold for a scroll tick.
    is_scrolling_ = true;
    data->enc_diff = ticks;
  } else {
    // User is touching the wheel, but hasn't moved.
    data->enc_diff = 0;
  }

  // Prevent accidental center button touches while scrolling
  if (wheel_data.is_wheel_touched) {
    last_wheel_touch_time_ = esp_timer_get_time();
  }

  bool wheel_touch_timed_out =
      esp_timer_get_time() - last_wheel_touch_time_ > SCROLL_TIMEOUT_US;

  auto centre_state = centre_.update(wheel_touch_timed_out && wheel_data.is_button_touched &&
                     !wheel_data.is_wheel_touched,
                 data);
  if (centre_state == input::Trigger::State::kPress) {
    events.push_back(InputEvent::kOnPress);
  } else if (centre_state == input::Trigger::State::kLongPress) {
    events.push_back(InputEvent::kOnLongPress);
  }

  // If the user is touching the wheel but not scrolling, then they may be
  // clicking on one of the wheel's cardinal directions.
  const uint64_t now_us = esp_timer_get_time() / 1000;
  if (is_scrolling_) {
    up_.cancel();
    right_.cancel();
    down_.cancel();
    left_.cancel();
    last_scroll_ = now_us;
  } else {
    const auto time_since_last_scroll = last_scroll_ - now_us;
    bool pressing = wheel_data.is_wheel_touched &&
                    (time_since_last_scroll > SCROLL_TIMEOUT_US);

    const auto ustate =
        up_.update(pressing && drivers::TouchWheel::isAngleWithin(
                                   wheel_data.wheel_position, 0, 32),
                   data);
    const auto rstate =
        right_.update(pressing && drivers::TouchWheel::isAngleWithin(
                                      wheel_data.wheel_position, 192, 32),
                      data);
    const auto dstate =
        down_.update(pressing && drivers::TouchWheel::isAngleWithin(
                                     wheel_data.wheel_position, 128, 32),
                     data);
    const auto lstate =
        left_.update(pressing && drivers::TouchWheel::isAngleWithin(
                                     wheel_data.wheel_position, 64, 32),
                     data);

    // This is for haptic feedback.
    if (buttons_active_ &&
        (ustate == Trigger::State::kClick || rstate == Trigger::State::kClick ||
         dstate == Trigger::State::kClick ||
         lstate == Trigger::State::kClick)) {
      events.push_back(InputEvent::kOnPress);
    }
  }
}

auto TouchWheel::name() -> std::string {
  return "wheel";
}

auto TouchWheel::triggers()
    -> std::vector<std::reference_wrapper<TriggerHooks>> {
  return {centre_, up_, right_, down_, left_};
}

auto TouchWheel::onLock() -> void {
  wheel_.LowPowerMode(true);
  locked_ = true;
}

auto TouchWheel::onUnlock() -> void {
  wheel_.LowPowerMode(false);
  wheel_.Recalibrate();
  locked_ = false;
}

auto TouchWheel::sensitivity() -> lua::Property& {
  return sensitivity_;
}

auto TouchWheel::calculateTicks(const drivers::TouchWheelData& data) -> int8_t {
  if (!data.is_wheel_touched) {
    is_first_read_ = true;
    return 0;
  }

  uint8_t new_angle = data.wheel_position;
  if (is_first_read_) {
    is_first_read_ = false;
    last_angle_ = new_angle;
    return 0;
  }

  int delta = 128 - last_angle_;
  uint8_t rotated_angle = new_angle + delta;
  if (rotated_angle < 128 - threshold_) {
    last_angle_ = new_angle;
    return 1;
  } else if (rotated_angle > 128 + threshold_) {
    last_angle_ = new_angle;
    return -1;
  } else {
    return 0;
  }
}

auto TouchWheel::calculateThreshold(uint8_t sensitivity) -> uint8_t {
  int tmax = 35;
  int tmin = 5;
  return (((255. - sensitivity) / 255.) * (tmax - tmin) + tmin);
}

}  // namespace input
