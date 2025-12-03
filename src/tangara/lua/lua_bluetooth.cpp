/*
 * Copyright 2025 Nelbium <nelbium@proton.me>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_bluetooth.hpp"
#include <algorithm>
#include <cstddef>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <print>
#include <string>
#include <vector>
#include "drivers/bluetooth.hpp"
#include "drivers/bluetooth_types.hpp"
#include "lauxlib.h"
#include "lua/lua_version.hpp"

#include "lua.hpp"
#include "lua/bridge.hpp"

#include "lua.h"
#include "lua/lua_thread.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_bluetooth";

static auto forget_known_device(lua_State* state) -> int {
  Bridge* instance = Bridge::Get(state);
  size_t len = 0;

  // Get name of device to forget
  const char* nameChar = luaL_checklstring(state, 1, &len);
  if (!nameChar) {
    return 0;
  }
  // Convert to type string
  const std::string name(nameChar);

  // Get list of known devices
  const std::vector<drivers::bluetooth::MacAndName> knownDevices =
      instance->services().bluetooth().knownDevices();

  std::vector<drivers::bluetooth::MacAndName> matchedDevice;

  // Match known device to target name to forget
  std::copy_if(knownDevices.begin(), knownDevices.end(),
               std::back_inserter(matchedDevice),
               [&](const drivers::bluetooth::MacAndName& entry) {
                 return entry.name == name;
               });

  instance->services().bluetooth().forgetKnownDevice(matchedDevice[0].mac);

  return 1;
}

static const struct luaL_Reg kBluetoothFuncs[] = {
    {"forget_known_device", forget_known_device},
    {NULL, NULL}};

static auto lua_bluetooth(lua_State* state) -> int {
  luaL_newlib(state, kBluetoothFuncs);
  return 1;
}

auto RegisterBluetoothModule(lua_State* s) -> void {
  luaL_requiref(s, "bluetooth", lua_bluetooth, true);
  lua_pop(s, 1);
}

}  // namespace lua
