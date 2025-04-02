/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>
#include <memory>

#include "input/feedback_device.hpp"
#include "input/input_device.hpp"
#include "input/input_touch_wheel.hpp"
#include "input/input_hard_reset.hpp"
#include "drivers/nvs.hpp"
#include "system_fsm/service_locator.hpp"

namespace input {

class DeviceFactory {
 public:
  DeviceFactory(std::shared_ptr<system_fsm::ServiceLocator>);

  auto createInputs()
      -> std::vector<std::shared_ptr<IInputDevice>>;
  auto createLockedInputs()
      -> std::vector<std::shared_ptr<IInputDevice>>;

  auto createFeedbacks() -> std::vector<std::shared_ptr<IFeedbackDevice>>;

  auto touch_wheel() -> std::shared_ptr<TouchWheel> { return wheel_; }

  auto lua_input() -> std::shared_ptr<LuaInput> { return lua_input_; }

 private:
  std::shared_ptr<system_fsm::ServiceLocator> services_;

  // HACK: the touchwheel is current a special case, since it's the only input
  // device that has some kind of setting/configuration; scroll sensitivity.
  std::shared_ptr<TouchWheel> wheel_;

  // Another special case, the hard reset input should persist between
  // lock modes, and always be added to the created inputs
  std::shared_ptr<HardReset> reset_;

  // We need to keep a handle to the lua input driver around so we can tell it when to reload.
  // (You get a special case! And *you* get a special case!)
  std::shared_ptr<LuaInput> lua_input_;
};

}  // namespace input
