/*
 * Copyright 2025 ailurux <ailuruxx@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_media_buttons.hpp"
#include "drivers/gpios.hpp"
#include "events/event_queue.hpp"
#include "input/input_hook_actions.hpp"

namespace input {

MediaButtons::MediaButtons(drivers::IGpios& gpios, audio::TrackQueue& queue)
    : gpios_(gpios),
      up_("upper", actions::nextTrack(queue), {}, {}, actions::volumeUp()),
      down_("lower", actions::prevTrack(queue), {}, {}, actions::volumeDown()),
      locked_(),
      both_buttons_pressed_(false) {}

auto MediaButtons::read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void {
  bool up = !gpios_.Get(drivers::IGpios::Pin::kKeyUp);
  bool down = !gpios_.Get(drivers::IGpios::Pin::kKeyDown);

  if ((up && down)) {
    up_.cancel();
    down_.cancel();
    both_buttons_pressed_ = true;
  } else if (!up && !down) {
    if (both_buttons_pressed_) {
      std::invoke(actions::togglePlayPause().fn, data);
      both_buttons_pressed_ = false;
      return;
    }
  }

  if (both_buttons_pressed_) {
    return;
  }

  up_.update(up, data);
  down_.update(down, data);
}

auto MediaButtons::name() -> std::string {
  return "buttons";
}

auto MediaButtons::triggers()
    -> std::vector<std::reference_wrapper<TriggerHooks>> {
  return {up_, down_};
}

auto MediaButtons::onLock() -> void {
  locked_ = true;
}

auto MediaButtons::onUnlock() -> void {
  locked_ = false;
}

}  // namespace input
