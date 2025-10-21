/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstdint>

#include "driver/i2c_master.h"
#include "driver/i2c_types.h"

namespace drivers {

esp_err_t init_i2c(void);
i2c_master_bus_handle_t i2c_handle();

}  // namespace drivers
