/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/device_factory.hpp"

#include <memory>

#include "input/feedback_haptics.hpp"
#include "input/feedback_tts.hpp"
#include "input/input_device.hpp"
#include "input/input_hard_reset.hpp"
#include "input/input_lua.hpp"
#include "input/input_media_buttons.hpp"
#include "input/input_nav_buttons.hpp"
#include "input/input_touch_dpad.hpp"
#include "input/input_touch_wheel.hpp"
#include "input/input_volume_buttons.hpp"
#include "lua/lua_registry.hpp"

namespace input {

DeviceFactory::DeviceFactory(
    std::shared_ptr<system_fsm::ServiceLocator> services)
    : services_(services) {
  if (services->touchwheel()) {
    wheel_ =
        std::make_shared<TouchWheel>(services->nvs(), **services->touchwheel());
  }
  lua_input_ = std::make_shared<LuaInput>(
      lua::Registry::instance(*services_).uiThread());
  reset_ = std::make_shared<HardReset>(services_->gpios());
}

auto DeviceFactory::createLockedInputs()
    -> std::vector<std::shared_ptr<IInputDevice>> {
  auto locked_mode = services_->nvs().LockedInput();
  std::vector<std::shared_ptr<IInputDevice>> ret;
  switch (locked_mode) {
    case drivers::NvsStorage::ButtonInputModes::kDisabled:
      break;
    case drivers::NvsStorage::ButtonInputModes::kMediaControls:
      ret.push_back(std::make_shared<MediaButtons>(services_->gpios(),
                                                   services_->track_queue()));
      break;
    case drivers::NvsStorage::ButtonInputModes::kNavigation:
      // I don't think we want navigation to work when locked?
      // ret.push_back(std::make_shared<NavButtons>(services_->gpios()));
      break;
    case drivers::NvsStorage::ButtonInputModes::kVolumeOnly:
      ret.push_back(std::make_shared<VolumeButtons>(services_->gpios()));
      break;
  }
  ret.push_back(reset_);
  return ret;
}

auto DeviceFactory::createInputs()
    -> std::vector<std::shared_ptr<IInputDevice>> {
  std::vector<std::shared_ptr<IInputDevice>> ret;
  auto wheel_mode = services_->nvs().WheelInput();
  auto buttons_mode = services_->nvs().ButtonInput();
  // Make sure we always have a navigational input
  if (wheel_mode == drivers::NvsStorage::WheelInputModes::kDisabled) {
    if (buttons_mode != drivers::NvsStorage::ButtonInputModes::kNavigation) {
      wheel_mode = drivers::NvsStorage::WheelInputModes::kRotatingWheel;
      services_->nvs().WheelInput(wheel_mode);
    }
  }
  switch (wheel_mode) {
    case drivers::NvsStorage::WheelInputModes::kDisabled:
      break;
    case drivers::NvsStorage::WheelInputModes::kDirectionalWheel:
      if (services_->touchwheel()) {
        ret.push_back(std::make_shared<TouchDPad>(**services_->touchwheel()));
      }
      break;
    case drivers::NvsStorage::WheelInputModes::kRotatingWheel:
    default:  // Don't break input over a bad enum value.
      if (wheel_) {
        ret.push_back(wheel_);
      }
      break;
  }
  switch (buttons_mode) {
    case drivers::NvsStorage::ButtonInputModes::kDisabled:
      break;
    case drivers::NvsStorage::ButtonInputModes::kMediaControls:
      ret.push_back(std::make_shared<MediaButtons>(services_->gpios(),
                                                   services_->track_queue()));
      break;
    case drivers::NvsStorage::ButtonInputModes::kNavigation:
      ret.push_back(std::make_shared<NavButtons>(services_->gpios()));
      break;
    case drivers::NvsStorage::ButtonInputModes::kVolumeOnly:
    default:
      ret.push_back(std::make_shared<VolumeButtons>(services_->gpios()));
      break;
  }
  ret.push_back(reset_);

  ret.push_back(lua_input_);

  return ret;
}

auto DeviceFactory::createFeedbacks()
    -> std::vector<std::shared_ptr<IFeedbackDevice>> {
  std::vector<std::shared_ptr<IFeedbackDevice>> ret;
  if (services_->haptics()) {
    std::make_shared<Haptics>(**services_->haptics(), services_);
  }
  ret.push_back(std::make_shared<TextToSpeech>(services_->tts()));
  return ret;
}

}  // namespace input
