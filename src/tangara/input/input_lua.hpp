/*
 * Copyright 2024 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "indev/lv_indev.h"

#include "input/input_device.hpp"

namespace lua {
 class LuaThread;
}

namespace input {

class LuaInput : public IInputDevice {
 public:
  LuaInput(std::function<std::shared_ptr<lua::LuaThread>()> thread_factory);

  auto tryReloadScript() -> void;

  auto read(lv_indev_data_t* data, std::vector<InputEvent>& events) -> void override;
  auto name() -> std::string override;
  auto onLock(drivers::NvsStorage::LockedInputModes) -> void override;
  auto onUnlock() -> void override;

 private:
  std::shared_ptr<lua::LuaThread> thread_;
  std::function<std::shared_ptr<lua::LuaThread>()> thread_factory_;
};

}  // namespace input
