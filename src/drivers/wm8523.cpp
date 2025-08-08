/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
#include "drivers/wm8523.hpp"
#include <stdint.h>

#include <cstdint>

#include "driver/i2c_master.h"
#include "driver/i2c_types.h"
#include "esp_err.h"

#include "drivers/i2c.hpp"
#include "hal/i2c_types.h"

namespace drivers {
namespace wm8523 {

const uint16_t kAbsoluteMaxVolume = 0x1ff;
const uint16_t kAbsoluteMinVolume = 0b0;

// This is 3dB below what the DAC considers to be '0dB', and 9.5dB above line
// level reference.
const uint16_t kMaxVolumeBeforeClipping = 0x184;

// This is 12.5 dB below what the DAC considers to be '0dB'.
const uint16_t kLineLevelReferenceVolume = 0x15E;

// Default to -24 dB, which I will claim is 'arbitrarily chosen to be safe but
// audible', but is in fact just a nice value for my headphones in particular.
const uint16_t kDefaultVolume = kLineLevelReferenceVolume - 96;

// Default to +6dB == 2Vrms == 'CD Player'
const uint16_t kDefaultMaxVolume = kLineLevelReferenceVolume + 12;

const uint16_t kZeroDbVolume = 0x190;

static const uint8_t kAddress = 0b0011010;
static i2c_master_dev_handle_t sI2C;

auto Init() -> esp_err_t {
  i2c_device_config_t config = {
      .dev_addr_length = I2C_ADDR_BIT_LEN_7,
      .device_address = kAddress,
      .scl_speed_hz = 400'000,
      .scl_wait_us = 0,
      .flags = {.disable_ack_check = false},
  };
  return i2c_master_bus_add_device(i2c_handle(), &config, &sI2C);
}

auto ReadRegister(Register reg) -> std::optional<uint16_t> {
  uint8_t cmd[] = {static_cast<uint8_t>(reg)};
  uint8_t data[] = {0, 0};
  if (i2c_master_transmit_receive(sI2C, cmd, 1, data, 2, 100) != ESP_OK) {
    return {};
  }
  return (data[0] << 8) | data[1];
}

auto WriteRegister(Register reg, uint16_t data) -> bool {
  return WriteRegister(reg, (data >> 8) & 0xFF, data & 0xFF);
}

auto WriteRegister(Register reg, uint8_t msb, uint8_t lsb) -> bool {
  uint8_t cmd[] = {static_cast<uint8_t>(reg), msb, lsb};
  return i2c_master_transmit(sI2C, cmd, 3, 100) == ESP_OK;
}

}  // namespace wm8523
}  // namespace drivers
