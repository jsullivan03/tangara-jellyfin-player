/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "indev/lv_indev.h"

#include "drivers/gpios.hpp"
#include "drivers/haptics.hpp"
#include "drivers/touchwheel.hpp"
#include "input/input_device.hpp"
#include "input/input_hook.hpp"
#include "input/input_trigger.hpp"

namespace input {

class NavButtons : public IInputDevice {
 public:
  NavButtons(drivers::IGpios&);

  auto read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void override;

  auto name() -> std::string override;
  auto triggers() -> std::vector<std::reference_wrapper<TriggerHooks>> override;

  auto onLock(drivers::NvsStorage::LockedInputModes) -> void override;
  auto onUnlock() -> void override;

 private:
  drivers::IGpios& gpios_;

  TriggerHooks up_;
  TriggerHooks down_;

  bool locked_;
};

}  // namespace input
