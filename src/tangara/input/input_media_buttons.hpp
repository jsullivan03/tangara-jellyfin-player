/*
 * Copyright 2025 ailurux <ailuruxx@gmail.com>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "audio/track_queue.hpp"
#include "indev/lv_indev.h"

#include "drivers/gpios.hpp"
#include "drivers/haptics.hpp"
#include "drivers/touchwheel.hpp"
#include "input/input_device.hpp"
#include "input/input_hook.hpp"

namespace input {

class MediaButtons : public IInputDevice {
 public:
  MediaButtons(drivers::IGpios&, audio::TrackQueue& queue);

  auto read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void override;

  auto name() -> std::string override;
  auto triggers() -> std::vector<std::reference_wrapper<TriggerHooks>> override;

  auto onLock() -> void override;
  auto onUnlock() -> void override;

 private:
  drivers::IGpios& gpios_;

  TriggerHooks up_;
  TriggerHooks down_;

  bool locked_;
  bool both_buttons_pressed_;
};

}  // namespace input
