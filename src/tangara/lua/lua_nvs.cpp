/*
 * Copyright 2024 Clayton Craft <clayton@craftyguy.net>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_version.hpp"

#include "lua.hpp"
#include "lua/bridge.hpp"

#include "lua.h"
#include "lua/lua_thread.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_nvs";

static auto write(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  instance->services().nvs().Write();

  return 1;
}

static const struct luaL_Reg kNvsFuncs[] = {{"write", write},
                                             {NULL, NULL}};

static auto lua_nvs(lua_State* L) -> int {
  luaL_newlib(L, kNvsFuncs);
  return 1;
}

auto RegisterNvsModule(lua_State* L) -> void {
  luaL_requiref(L, "nvs", lua_nvs, true);
  lua_pop(L, 1);
}

}  // namespace lua
