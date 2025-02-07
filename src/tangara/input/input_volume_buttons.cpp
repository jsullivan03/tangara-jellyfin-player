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

  bool input_disabled = locked_.has_value() && (locked_ != drivers::NvsStorage::LockedInputModes::kVolumeOnly);

  if ((up && down) || input_disabled) {
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

auto VolumeButtons::onLock(drivers::NvsStorage::LockedInputModes mode) -> void {
  locked_ = mode;
}

auto VolumeButtons::onUnlock() -> void {
  locked_ = {};
}

}  // namespace input
