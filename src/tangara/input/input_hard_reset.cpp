/*
 * Copyright 2025 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_hard_reset.hpp"

#include "drivers/gpios.hpp"
#include "esp_system.h"
#include "input/input_hook_actions.hpp"

namespace input {

HardReset::HardReset(drivers::IGpios& gpios) : gpios_(gpios) {}

auto HardReset::read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void {
  bool buttons_pressed = !gpios_.Get(drivers::IGpios::Pin::kKeyUp) &&
                         !gpios_.Get(drivers::IGpios::Pin::kKeyDown);
  if (!buttons_pressed) {
    stage_ = 0;
    return;
  }

  bool locked = gpios_.IsLocked();

  if (stage_ == 0 && !locked) {
    stage_++;
    return;
  }
  if (stage_ == 1 && locked) {
    stage_++;
    return;
  }
  if (stage_ == 2 && !locked) {
    // Bye!
    esp_restart();
  }
}

auto HardReset::name() -> std::string {
  return "hard_reset";
}

auto HardReset::triggers()
    -> std::vector<std::reference_wrapper<TriggerHooks>> {
  return {};
}

}  // namespace input
