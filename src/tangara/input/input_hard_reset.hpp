/*
 * Copyright 2025 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "indev/lv_indev.h"

#include "drivers/gpios.hpp"
#include "input/input_device.hpp"
#include "input/input_hook.hpp"

namespace input {

class HardReset : public IInputDevice {
 public:
  HardReset(drivers::IGpios&);

  auto read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void override;

  auto name() -> std::string override;
  auto triggers() -> std::vector<std::reference_wrapper<TriggerHooks>> override;

 private:
  drivers::IGpios& gpios_;

  int stage_;
};

}  // namespace input
