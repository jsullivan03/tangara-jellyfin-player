/*
 * Copyright 2024 Clayton Craft <clayton@craftyguy.net>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_nvs.hpp"

#include <optional>
#include <string>

#include "lauxlib.h"
#include "lua.h"
#include "lua.hpp"
#include "lua/bridge.hpp"

namespace lua {

static auto push_optional_string(
    lua_State* L,
    const std::optional<std::string>& value
) -> int {
  if (!value) {
    lua_pushnil(L);
    return 1;
  }

  lua_pushlstring(L, value->data(), value->size());
  return 1;
}

static auto write(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  lua_pushboolean(L, instance->services().nvs().Write());
  return 1;
}

static auto wifi_ssid(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  return push_optional_string(
      L,
      instance->services().nvs().WifiSsid()
  );
}

static auto set_wifi_ssid(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  instance->services().nvs().WifiSsid(
      std::string{luaL_checkstring(L, 1)}
  );
  lua_pushboolean(L, instance->services().nvs().Write());
  return 1;
}

static auto wifi_password(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  return push_optional_string(
      L,
      instance->services().nvs().WifiPassword()
  );
}

static auto set_wifi_password(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  instance->services().nvs().WifiPassword(
      std::string{luaL_checkstring(L, 1)}
  );
  lua_pushboolean(L, instance->services().nvs().Write());
  return 1;
}

static auto sync_server_url(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  return push_optional_string(
      L,
      instance->services().nvs().SyncServerUrl()
  );
}

static auto set_sync_server_url(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  instance->services().nvs().SyncServerUrl(
      std::string{luaL_checkstring(L, 1)}
  );
  lua_pushboolean(L, instance->services().nvs().Write());
  return 1;
}

static const struct luaL_Reg kNvsFuncs[] = {
    {"write", write},
    {"wifi_ssid", wifi_ssid},
    {"set_wifi_ssid", set_wifi_ssid},
    {"wifi_password", wifi_password},
    {"set_wifi_password", set_wifi_password},
    {"sync_server_url", sync_server_url},
    {"set_sync_server_url", set_sync_server_url},
    {NULL, NULL},
};

static auto lua_nvs(lua_State* L) -> int {
  luaL_newlib(L, kNvsFuncs);
  return 1;
}

auto RegisterNvsModule(lua_State* L) -> void {
  luaL_requiref(L, "nvs", lua_nvs, true);
  lua_pop(L, 1);
}

}  // namespace lua
