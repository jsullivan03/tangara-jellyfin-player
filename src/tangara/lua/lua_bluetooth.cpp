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

  drivers::bluetooth::mac_addr_t mac;
  if (lua_isuserdata(state, 1)) {
    mac = *reinterpret_cast<drivers::bluetooth::mac_addr_t*>(
        lua_touserdata(state, 1));
  } else
    return 0;

  instance->services().bluetooth().forgetKnownDevice(mac);

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
