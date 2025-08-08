/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "drivers/gpios.hpp"
#include <stdint.h>

#include <cstdint>

#include "assert.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_attr.h"
#include "esp_err.h"
#include "esp_intr_alloc.h"
#include "hal/gpio_types.h"

#include "drivers/i2c.hpp"

namespace drivers {

static const uint8_t kPca8575Address = 0x20;

// Port A:
// 0 - sd card mux switch
// 1 - sd card mux enable (active low)
// 2 - key up
// 3 - key down
// 4 - key lock
// 5 - display reset (active low)
// 6 - NC
// 7 - sd card power
// Default to SD card off, inputs high, display running
static const uint8_t kPortADefault = 0b00111110;

// Port B:
// 0 - 3.5mm jack detect (active low)
// 1 - headphone amp power enable
// 2 - sd card detect
// 3 - amplifier unmute (revisions < r8)
// 4 - amplifier mute (revisions >= r8)
// 5 - NC
// 6 - NC
// 7 - NC
// Default inputs high, amp off.
static const uint8_t kPortBDefault = 0b00011111;

/*
 * Convenience mehod for packing the port a and b bytes into a single 16 bit
 * value.
 */
constexpr uint16_t pack(uint8_t a, uint8_t b) {
  return ((uint16_t)b) << 8 | a;
}

/*
 * Convenience mehod for unpacking the result of `pack` back into two single
 * byte port datas.
 */
constexpr std::pair<uint8_t, uint8_t> unpack(uint16_t ba) {
  return std::pair((uint8_t)ba, (uint8_t)(ba >> 8));
}

static constexpr gpio_num_t kIntPin = GPIO_NUM_34;

auto Gpios::Create(bool invert_lock) -> Gpios* {
  Gpios* instance = new Gpios(invert_lock);
  // Read and write initial values on initialisation so that we do not have a
  // strange partially-initialised state.
  if (!instance->Flush() || !instance->Read()) {
    return nullptr;
  }
  return instance;
}

Gpios::Gpios(bool invert_lock)
    : ports_(pack(kPortADefault, kPortBDefault)),
      inputs_(0),
      invert_lock_switch_(invert_lock) {
  gpio_set_direction(kIntPin, GPIO_MODE_INPUT);
  i2c_device_config_t config = {
      .dev_addr_length = I2C_ADDR_BIT_LEN_7,
      .device_address = kPca8575Address,
      .scl_speed_hz = 400'000,
      .scl_wait_us = 0,
      .flags = {.disable_ack_check = false},
  };
  ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_handle(), &config, &i2c_));
}

Gpios::~Gpios() {}

auto Gpios::WriteBuffered(Pin pin, bool value) -> void {
  if (value) {
    ports_ |= (1 << static_cast<int>(pin));
  } else {
    ports_ &= ~(1 << static_cast<int>(pin));
  }
}

auto Gpios::WriteSync(Pin pin, bool value) -> bool {
  WriteBuffered(pin, value);
  return Flush();
}

auto Gpios::ShouldRead() -> bool {
  if (!gpio_get_level(GPIO_NUM_34) || has_written_) {
    has_written_ = false;
    return true;
  }
  return false;
}

auto Gpios::Flush() -> bool {
  std::pair<uint8_t, uint8_t> ports_ab = unpack(ports_);
  uint8_t data[] = {ports_ab.first, ports_ab.second};
  has_written_ = true;
  return i2c_master_transmit(i2c_, data, 2, 100) == ESP_OK;
}

auto Gpios::Get(Pin pin) const -> bool {
  return (inputs_ & (1 << static_cast<int>(pin))) > 0;
}

auto Gpios::IsLocked() const -> bool {
  bool pin = Get(Pin::kKeyLock);
  if (invert_lock_switch_) {
    return pin;
  } else {
    return !pin;
  }
}

auto Gpios::Read() -> bool {
  uint8_t data[] = {0, 0};
  esp_err_t ret = i2c_master_receive(i2c_, data, 2, 100);
  if (ret != ESP_OK) {
    return false;
  }
  inputs_ = pack(data[0], data[1]);
  return true;
}

auto Gpios::SdMuxEnable(bool en) -> void {
  std::unique_lock<std::mutex> lock(mux_mutex_);
  mux_en_ = en;
  if (SdMuxTarget() == SD_MUX_ESP) {
    WriteSync(Pin::kSdMuxDisable, !en);
  }
  // Don't touch the mux if it's pointed at the SAMD21. We'll write the new
  // value when the mux points back at us again.
}

auto Gpios::SdMuxTarget(SdTarget target) -> void {
  std::unique_lock<std::mutex> lock(mux_mutex_);
  WriteBuffered(Pin::kSdMuxSwitch, target);
  if (target == SD_MUX_ESP) {
    WriteBuffered(Pin::kSdMuxDisable, !mux_en_);
  } else {
    // Mux is always enabled when it's pointing at the SAMD21, since it's the
    // only thing on that SPI bus.
    WriteBuffered(Pin::kSdMuxDisable, 0);
  }
  Flush();
}

auto Gpios::SdMuxTarget() -> SdTarget {
  return static_cast<SdTarget>(
      (ports_ & (1 << static_cast<int>(Pin::kSdMuxSwitch))) > 0);
}

}  // namespace drivers
