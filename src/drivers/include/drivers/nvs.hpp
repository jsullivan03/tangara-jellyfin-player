/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <stdint.h>
#include <memory>
#include <optional>

#include "esp_err.h"
#include "nvs.h"

#include "drivers/bluetooth_types.hpp"
#include "lru_cache.hpp"

namespace drivers {

/*
 * Wrapper for a single NVS setting, with its backing value cached in memory.
 * NVS values that are just plain old data should generally use these for
 * simpler implementation.
 */
template <typename T>
class Setting {
 public:
  Setting(const char* name) : name_(name), val_(), dirty_(false) {}

  auto set(const std::optional<T>&& v) -> void {
    if (val_.has_value() != v.has_value() || *val_ != *v) {
      val_ = v;
      dirty_ = true;
    }
  }
  auto get() -> std::optional<T> { return val_; }

  /* Reads the stored value from NVS and parses it into the correct type. */
  auto load(nvs_handle_t) -> std::optional<T>;
  /* Encodes the given value and writes it to NVS. */
  auto store(nvs_handle_t, T v) -> void;

  auto read(nvs_handle_t nvs) -> void { val_ = load(nvs); }
  auto write(nvs_handle_t nvs) -> void {
    if (!dirty_) {
      return;
    }
    dirty_ = false;
    if (val_) {
      store(nvs, *val_);
    } else {
      nvs_erase_key(nvs, name_);
    }
  }

 private:
  const char* name_;
  std::optional<T> val_;
  bool dirty_;
};

class NvsStorage {
 public:
  static auto OpenSync() -> NvsStorage*;

  auto Read() -> void;
  auto Write() -> bool;

  // Hardware Compatibility
  auto LockPolarity() -> bool;
  auto LockPolarity(bool) -> void;

  auto DisplaySize()
      -> std::pair<std::optional<uint16_t>, std::optional<uint16_t>>;
  auto DisplaySize(std::pair<std::optional<uint16_t>, std::optional<uint16_t>>)
      -> void;

  auto HapticMotorIsErm() -> bool;
  auto HapticMotorIsErm(bool) -> void;

  struct LraData {
    uint8_t compensation;
    uint8_t back_emf;
    uint8_t gain;

    bool operator==(const LraData&) const = default;
  };

  auto LraCalibration() -> std::optional<LraData>;
  auto LraCalibration(const LraData&) -> void;

  auto FastCharge() -> bool;
  auto FastCharge(bool) -> void;

  auto DisplayLeftPadding() -> uint8_t;
  auto DisplayLeftPadding(uint8_t) -> void;

  auto PreferredBluetoothDevice() -> std::optional<bluetooth::MacAndName>;
  auto PreferredBluetoothDevice(std::optional<bluetooth::MacAndName>) -> void;

  auto BluetoothVolume(const bluetooth::mac_addr_t&) -> uint8_t;
  auto BluetoothVolume(const bluetooth::mac_addr_t&, uint8_t) -> void;

  auto BluetoothNames() -> std::vector<bluetooth::MacAndName>;
  auto BluetoothName(const bluetooth::mac_addr_t&, std::optional<std::string>)
      -> void;

  enum class Output : uint8_t {
    kHeadphones = 0,
    kBluetooth = 1,
  };
  auto OutputMode() -> Output;
  auto OutputMode(Output) -> void;

  enum class HapticsModes : uint8_t {
    kDisabled = 0,
    kMinimal = 1,
    kStrong = 2,
  };
  auto HapticsMode() -> HapticsModes;
  auto HapticsMode(HapticsModes) -> void;
  static auto intToHapticsMode(int raw) -> HapticsModes;

  enum class LongTextModes : uint8_t {
    kDefault = 0,
    kEllipsize = 1,
    kScroll = 2,
    kScrollCircular = 3,
    kClip = 4,
  };

  auto LongTextMode() -> LongTextModes;
  auto LongTextMode(LongTextModes) -> void;
  static auto intToLongTextMode(int raw) -> LongTextModes;

  auto ScreenBrightness() -> uint_fast8_t;
  auto ScreenBrightness(uint_fast8_t) -> void;

  auto UITextToSpeech() -> bool;
  auto UITextToSpeech(bool) -> void;

  auto InterfaceTheme() -> std::optional<std::string>;
  auto InterfaceTheme(std::string) -> void;

  auto ScrollSensitivity() -> uint_fast8_t;
  auto ScrollSensitivity(uint_fast8_t) -> void;

  auto AmpMaxVolume() -> uint16_t;
  auto AmpMaxVolume(uint16_t) -> void;

  auto AmpCurrentVolume() -> uint16_t;
  auto AmpCurrentVolume(uint16_t) -> void;

  auto AmpLeftBias() -> int_fast8_t;
  auto AmpLeftBias(int_fast8_t) -> void;

  enum class WheelInputModes : uint8_t {
    kDisabled = 0,
    kDirectionalWheel = 1,
    kRotatingWheel = 2,
    kWheelWithButtons = 3,
  };

  auto WheelInput() -> WheelInputModes;
  auto WheelInput(WheelInputModes) -> void;

  enum class ButtonInputModes : uint8_t {
    kDisabled = 0,
    kVolumeOnly = 1,
    kMediaControls = 2,
    kNavigation = 3,
  };

  auto ButtonInput() -> ButtonInputModes;
  auto ButtonInput(ButtonInputModes) -> void;

  auto LockedInput() -> ButtonInputModes;
  auto LockedInput(ButtonInputModes) -> void;

  auto QueueRepeatMode() -> uint8_t;
  auto QueueRepeatMode(uint8_t) -> void;

  auto DbAutoIndex() -> bool;
  auto DbAutoIndex(bool) -> void;

  auto DbSkipVerification() -> bool;
  auto DbSkipVerification(bool) -> void;

  explicit NvsStorage(nvs_handle_t);
  ~NvsStorage();

 private:
  auto DowngradeSchemaSync() -> bool;
  auto SchemaVersionSync() -> uint8_t;

  std::mutex mutex_;
  nvs_handle_t handle_;

  Setting<uint8_t> lock_polarity_;
  Setting<uint16_t> display_cols_;
  Setting<uint16_t> display_rows_;
  Setting<uint8_t> display_left_padding_;
  Setting<uint8_t> haptic_motor_type_;
  Setting<LraData> lra_calibration_;
  Setting<uint8_t> fast_charge_;

  Setting<uint8_t> brightness_;
  Setting<uint8_t> text_to_speech_;
  Setting<uint8_t> sensitivity_;
  Setting<uint16_t> amp_max_vol_;
  Setting<uint16_t> amp_cur_vol_;
  Setting<int8_t> amp_left_bias_;
  Setting<uint8_t> wheel_input_mode_;
  Setting<uint8_t> button_input_mode_;
  Setting<uint8_t> locked_input_mode_;
  Setting<uint8_t> output_mode_;
  Setting<uint8_t> haptics_mode_;
  Setting<uint8_t> long_text_mode_;

  Setting<std::string> theme_;

  Setting<bluetooth::MacAndName> bt_preferred_;
  Setting<std::vector<bluetooth::MacAndName>> bt_names_;

  Setting<uint8_t> db_auto_index_;
  Setting<uint8_t> db_skip_verification_;

  Setting<uint8_t> queue_repeat_mode_;

  util::LruCache<10, bluetooth::mac_addr_t, uint8_t> bt_volumes_;
  bool bt_volumes_dirty_;

  auto readBtVolumes() -> void;
  auto writeBtVolumes() -> void;
};

}  // namespace drivers
