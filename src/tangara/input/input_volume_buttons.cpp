/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_volume_buttons.hpp"
#include "drivers/gpios.hpp"
#include "events/event_queue.hpp"
#include "input/input_hook_actions.hpp"

namespace input {

VolumeButtons::VolumeButtons(drivers::IGpios& gpios)
    : gpios_(gpios),
      up_("upper", actions::volumeUp()),
      down_("lower", actions::volumeDown()),
      locked_() {}

auto VolumeButtons::read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void {
  bool up = !gpios_.Get(drivers::IGpios::Pin::kKeyUp);
  bool down = !gpios_.Get(drivers::IGpios::Pin::kKeyDown);

  if ((up && down)) {
    up = false;
    down = false;
  }

  up_.update(up, data);
  down_.update(down, data);
}

auto VolumeButtons::name() -> std::string {
  return "buttons";
}

auto VolumeButtons::triggers()
    -> std::vector<std::reference_wrapper<TriggerHooks>> {
  return {up_, down_};
}

auto VolumeButtons::onLock() -> void {
  locked_ = true;
}

auto VolumeButtons::onUnlock() -> void {
  locked_ = false;
}

}  // namespace input
