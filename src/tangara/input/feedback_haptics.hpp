/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "core/lv_obj.h"

#include "drivers/haptics.hpp"
#include "input/feedback_device.hpp"
#include "input/input_events.hpp"
#include "drivers/nvs.hpp"
#include "system_fsm/service_locator.hpp"

namespace input {

class Haptics : public IFeedbackDevice {
 public:
  Haptics(drivers::Haptics& haptics_,
          std::shared_ptr<system_fsm::ServiceLocator> services);

  auto feedback(lv_group_t*, uint8_t event_type) -> void override;
  auto feedback(lv_group_t*, InputEvent event) -> void override;

 private:
  drivers::Haptics& haptics_;
  std::shared_ptr<system_fsm::ServiceLocator> services_;
  lv_obj_t* last_selection_;
};

}  // namespace input
