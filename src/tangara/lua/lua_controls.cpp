/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_controls.hpp"

#include <memory>
#include <string>

#include "lua.hpp"

#include "esp_log.h"
#include "lauxlib.h"
#include "lua.h"
#include "lvgl.h"

#include "bridge.hpp"
#include "drivers/haptics.hpp"
#include "drivers/nvs.hpp"
#include "drivers/touchwheel.hpp"
#include "ui/ui_events.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_controls";

static auto wheel_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(
      L, -2, static_cast<int>(drivers::NvsStorage::WheelInputModes::kDisabled));

  lua_pushliteral(L, "D-Pad");
  lua_rawseti(L, -2,
              static_cast<int>(
                  drivers::NvsStorage::WheelInputModes::kDirectionalWheel));

  lua_pushliteral(L, "Touchwheel");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::WheelInputModes::kRotatingWheel));
  lua_pushliteral(L, "Wheel with Buttons");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::WheelInputModes::kWheelWithButtons));

  return 1;
}

static auto button_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kDisabled));

  lua_pushliteral(L, "Volume Only");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kVolumeOnly));
  lua_pushliteral(L, "Media Controls");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kMediaControls));
  lua_pushliteral(L, "Navigation");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kNavigation));

  return 1;
}

static auto locked_button_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kDisabled));

  lua_pushliteral(L, "Volume Only");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kVolumeOnly));
  lua_pushliteral(L, "Media Controls");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::ButtonInputModes::kMediaControls));

  return 1;
}

static auto haptics_modes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::HapticsModes::kDisabled));

  lua_pushliteral(L, "Minimal");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::HapticsModes::kMinimal));

  lua_pushliteral(L, "Strong");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::HapticsModes::kStrong));

  return 1;
}

static auto haptics_present(lua_State* L) -> int {
  lua_pushboolean(L, drivers::Haptics::IsHardwarePresent());
  return 1;
}

static auto touchwheel_present(lua_State* L) -> int {
  lua_pushboolean(L, drivers::TouchWheel::IsHardwarePresent());
  return 1;
}

static const struct luaL_Reg kControlsFuncs[] = {
    {"wheel_schemes", wheel_schemes},
    {"button_schemes", button_schemes},
    {"locked_schemes", locked_button_schemes},
    {"haptics_modes", haptics_modes},
    {"haptics_present", haptics_present},
    {"touchwheel_present", touchwheel_present},
    {NULL, NULL}};

static auto lua_controls(lua_State* state) -> int {
  luaL_newlib(state, kControlsFuncs);
  return 1;
}

auto RegisterControlsModule(lua_State* s) -> void {
  luaL_requiref(s, "controls", lua_controls, true);
  lua_pop(s, 1);
}

}  // namespace lua
