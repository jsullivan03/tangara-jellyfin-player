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

#include "drivers/nvs.hpp"
#include "ui/ui_events.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_controls";

static auto controls_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Buttons Only");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::InputModes::kButtonsOnly));

  lua_pushliteral(L, "D-Pad");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::InputModes::kDirectionalWheel));

  lua_pushliteral(L, "Touchwheel");
  lua_rawseti(
      L, -2, static_cast<int>(drivers::NvsStorage::InputModes::kRotatingWheel));

  return 1;
}

static auto locked_controls_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::LockedInputModes::kDisabled));

  lua_pushliteral(L, "Volume Only");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::LockedInputModes::kVolumeOnly));

  return 1;
}

static auto haptics_modes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Disabled");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::HapticsModes::kDisabled));

  lua_pushliteral(L, "Minimal");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::HapticsModes::kMinimal));

  lua_pushliteral(L, "Strong");
  lua_rawseti(
      L, -2, static_cast<int>(drivers::NvsStorage::HapticsModes::kStrong));

  return 1;
}

static const struct luaL_Reg kControlsFuncs[] = {{"schemes", controls_schemes},
                                                 {"locked_schemes", locked_controls_schemes},
                                                 {"haptics_modes", haptics_modes},
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
