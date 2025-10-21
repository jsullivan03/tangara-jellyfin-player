/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "drivers/samd.hpp"
#include <stdint.h>

#include <cstdint>
#include <format>
#include <optional>
#include <string>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "drivers/i2c.hpp"
#include "esp_err.h"
#include "esp_log.h"
#include "hal/gpio_types.h"
#include "hal/i2c_types.h"

#include "drivers/nvs.hpp"

static const uint8_t kAddress = 0x45;
[[maybe_unused]] static const char kTag[] = "SAMD";

namespace drivers {

static constexpr gpio_num_t kIntPin = GPIO_NUM_35;

auto Samd::chargeStatusToString(ChargeStatus status) -> std::string {
  switch (status) {
    case ChargeStatus::kNoBattery:
      return "no_battery";
    case ChargeStatus::kBatteryCritical:
      return "critical";
    case ChargeStatus::kDischarging:
      return "discharging";
    case ChargeStatus::kChargingRegular:
      return "charge_regular";
    case ChargeStatus::kChargingFast:
      return "charge_fast";
    case ChargeStatus::kFullCharge:
      return "full_charge";
    case ChargeStatus::kFault:
      return "fault";
    case ChargeStatus::kUnknown:
    default:
      return "unknown";
  }
}

Samd::Samd(NvsStorage& nvs) : nvs_(nvs) {
  gpio_set_direction(kIntPin, GPIO_MODE_INPUT);

  // Being able to interface with the SAMD properly is critical. To ensure we
  // will be able to, we begin by checking the I2C protocol version is
  // compatible, and throw if it's not.
  i2c_device_config_t config = {
      .dev_addr_length = I2C_ADDR_BIT_LEN_7,
      .device_address = kAddress,
      .scl_speed_hz = 100'000,
      .scl_wait_us = 0,
      .flags = {.disable_ack_check = false},
  };
  ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_handle(), &config, &i2c_));

  uint8_t cmd[] = {registerIdx(RegisterName::kSamdFirmwareMajorVersion)};
  uint8_t data[] = {0, 0};
  ESP_ERROR_CHECK(i2c_master_transmit_receive(i2c_, cmd, 1, data, 2, 100));
  version_major_ = data[0];
  version_minor_ = data[1];

  if (version_major_ < 6) {
    version_minor_ = 0;
  }
  ESP_LOGI(kTag, "samd firmware rev: %u.%u", version_major_, version_minor_);

  UpdateChargeStatus();
  UpdateUsbStatus();
  SetFastChargeEnabled(nvs.FastCharge());
}
Samd::~Samd() {}

auto Samd::Version() -> std::string {
  return std::format("{}.{}", version_major_, version_minor_);
}

auto Samd::GetChargeStatus() -> std::optional<ChargeStatus> {
  return charge_status_;
}

auto Samd::UpdateChargeStatus() -> void {
  uint8_t cmd[] = {registerIdx(RegisterName::kChargeStatus)};
  uint8_t data[] = {0};
  esp_err_t res = i2c_master_transmit_receive(i2c_, cmd, 1, data, 1, 100);
  if (res != ESP_OK) {
    return;
  }

  // Lower two bits are the usb power status, next three are the BMS status.
  // See 'gpio.c' in the SAMD21 firmware for how these bits get packed.
  uint8_t charge_state = (data[0] & 0b11100) >> 2;
  uint8_t usb_state = data[0] & 0b11;
  switch (charge_state) {
    case 0b000:
      charge_status_ = ChargeStatus::kNoBattery;
      break;
    case 0b001:
      // BMS says we're charging; work out how fast we're charging.
      if (usb_state >= 0b10 && nvs_.FastCharge()) {
        charge_status_ = ChargeStatus::kChargingFast;
      } else {
        charge_status_ = ChargeStatus::kChargingRegular;
      }
      break;
    case 0b010:
      charge_status_ = ChargeStatus::kFullCharge;
      break;
    case 0b011:
      charge_status_ = ChargeStatus::kFault;
      break;
    case 0b100:
      charge_status_ = ChargeStatus::kBatteryCritical;
      break;
    case 0b101:
      charge_status_ = ChargeStatus::kDischarging;
      break;
    case 0b110:
    case 0b111:
      charge_status_ = ChargeStatus::kUnknown;
      break;
  }
}

auto Samd::GetUsbStatus() -> UsbStatus {
  return usb_status_;
}

auto Samd::UpdateUsbStatus() -> void {
  uint8_t cmd[] = {registerIdx(RegisterName::kUsbStatus)};
  uint8_t data[] = {0};
  esp_err_t res = i2c_master_transmit_receive(i2c_, cmd, 1, data, 1, 100);
  if (res != ESP_OK) {
    return;
  }

  if (!(data[0] & 0b1)) {
    usb_status_ = UsbStatus::kDetached;
  }
  usb_status_ =
      (data[0] & 0b10) ? UsbStatus::kAttachedBusy : UsbStatus::kAttachedIdle;
}

auto Samd::ResetToFlashSamd() -> void {
  uint8_t cmd[] = {registerIdx(RegisterName::kUsbControl), 0b100};
  ESP_ERROR_CHECK(i2c_master_transmit(i2c_, cmd, 2, 100));
}

auto Samd::SetFastChargeEnabled(bool en) -> void {
  // Always update NVS, so that the setting is right after the SAMD firmware is
  // updated.
  nvs_.FastCharge(en);

  if (version_major_ < 4) {
    return;
  }

  uint8_t cmd[] = {registerIdx(RegisterName::kPowerControl),
                   static_cast<uint8_t>(en << 1)};
  ESP_ERROR_CHECK(i2c_master_transmit(i2c_, cmd, 2, 100));
}

auto Samd::PowerDown() -> void {
  uint8_t cmd[] = {registerIdx(RegisterName::kPowerControl), 0b1};
  ESP_ERROR_CHECK(i2c_master_transmit(i2c_, cmd, 2, 100));
}

auto Samd::UsbMassStorage(bool en) -> void {
  uint8_t cmd[] = {registerIdx(RegisterName::kUsbControl), en};
  ESP_ERROR_CHECK(i2c_master_transmit(i2c_, cmd, 2, 100));
}

auto Samd::UsbMassStorage() -> bool {
  uint8_t cmd[] = {registerIdx(RegisterName::kUsbControl)};
  uint8_t data[] = {0};
  esp_err_t res = i2c_master_transmit_receive(i2c_, cmd, 1, data, 1, 100);
  if (res != ESP_OK) {
    return false;
  }
  return data[0] & 1;
}

auto Samd::registerIdx(RegisterName r) -> uint8_t {
  switch (r) {
    case RegisterName::kSamdFirmwareMajorVersion:
      // Register 0 is always the major version.
      return 0;
    case RegisterName::kSamdFirmwareMinorVersion:
      // Firmwares before version 6 had no minor :(
      return version_major_ >= 6 ? 1 : 0;
    case RegisterName::kChargeStatus:
      return version_major_ >= 6 ? 2 : 1;
    case RegisterName::kUsbStatus:
      return version_major_ >= 6 ? 3 : 2;
    case RegisterName::kPowerControl:
      return version_major_ >= 6 ? 4 : 3;
    case RegisterName::kUsbControl:
      return version_major_ >= 6 ? 5 : 4;
  }
  assert(false);  // very very bad!!!
  return 0;
}

}  // namespace drivers
