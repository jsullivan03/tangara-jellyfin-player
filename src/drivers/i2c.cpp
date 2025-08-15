/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "drivers/i2c.hpp"

#include <cstdint>

#include "assert.h"
#include "driver/i2c_master.h"
#include "driver/i2c_types.h"
#include "esp_err.h"
#include "hal/i2c_types.h"
#include "soc/clk_tree_defs.h"

namespace drivers {

static const i2c_port_t kI2CPort = I2C_NUM_0;
static const gpio_num_t kI2CSdaPin = GPIO_NUM_4;
static const gpio_num_t kI2CSclPin = GPIO_NUM_2;

static i2c_master_bus_handle_t sHandle;

esp_err_t init_i2c(void) {
  i2c_master_bus_config_t config = {
      .i2c_port = kI2CPort,
      .sda_io_num = kI2CSdaPin,
      .scl_io_num = kI2CSclPin,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .glitch_ignore_cnt = 7,
      .intr_priority = 0,
      .trans_queue_depth = 0,
      .flags = {.enable_internal_pullup = true, .allow_pd = false},
  };
  return i2c_new_master_bus(&config, &sHandle);
}

i2c_master_bus_handle_t i2c_handle() {
  return sHandle;
}

}  // namespace drivers
