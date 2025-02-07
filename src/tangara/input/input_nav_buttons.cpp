/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_nav_buttons.hpp"

#include "indev/lv_indev.h"

#include "drivers/gpios.hpp"
#include "events/event_queue.hpp"
#include "input/input_hook_actions.hpp"

namespace input {

NavButtons::NavButtons(drivers::IGpios& gpios)
    : gpios_(gpios),
      up_("upper", {}, actions::scrollUp(), actions::select(), {}),
      down_("lower", {}, actions::scrollDown(), actions::select(), {}),
      locked_(false) {}

auto NavButtons::read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void {
  bool up = !gpios_.Get(drivers::IGpios::Pin::kKeyUp);
  bool down = !gpios_.Get(drivers::IGpios::Pin::kKeyDown);

  if ((up && down) || locked_) {
    up = false;
    down = false;
  }

  up_.update(up, data);
  down_.update(down, data);
}

auto NavButtons::name() -> std::string {
  return "buttons";
}

auto NavButtons::triggers()
    -> std::vector<std::reference_wrapper<TriggerHooks>> {
  return {up_, down_};
}

auto NavButtons::onLock(drivers::NvsStorage::LockedInputModes mode) -> void {
  locked_ = true;
}

auto NavButtons::onUnlock() -> void {
  locked_ = false;
}

}  // namespace input
