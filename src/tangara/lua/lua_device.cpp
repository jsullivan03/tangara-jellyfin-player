#include "lua/lua_device.hpp"

#include <array>
#include <cstdio>

#include "lua.hpp"

#include "esp_err.h"
#include "esp_mac.h"

namespace lua {
namespace {

auto id(lua_State* state) -> int {
  std::array<uint8_t, 6> mac{};
  const esp_err_t error = esp_efuse_mac_get_default(mac.data());

  if (error != ESP_OK) {
    lua_pushnil(state);
    lua_pushstring(state, esp_err_to_name(error));
    return 2;
  }

  std::array<char, 21> device_id{};

  const int length = std::snprintf(
      device_id.data(),
      device_id.size(),
      "tangara-%02x%02x%02x%02x%02x%02x",
      mac[0],
      mac[1],
      mac[2],
      mac[3],
      mac[4],
      mac[5]
  );

  lua_pushlstring(
      state,
      device_id.data(),
      static_cast<size_t>(length)
  );

  return 1;
}

auto storage_root(lua_State* state) -> int {
  lua_pushliteral(state, "/sd");
  return 1;
}

const luaL_Reg kDeviceFunctions[] = {
    {"id", id},
    {"storage_root", storage_root},
    {nullptr, nullptr},
};

auto open_device(lua_State* state) -> int {
  luaL_newlib(state, kDeviceFunctions);
  return 1;
}

}

auto RegisterDeviceModule(lua_State* state) -> void {
  luaL_requiref(state, "device", open_device, true);
  lua_pop(state, 1);
}

}
