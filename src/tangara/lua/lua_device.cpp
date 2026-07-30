#include "lua/lua_device.hpp"

#include <array>
#include <cstdint>
#include <cstdio>

#include "lua.hpp"

#include "esp_err.h"
#include "esp_mac.h"
#include "ff.h"

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

auto storage_info(lua_State* state) -> int {
  DWORD free_clusters = 0;
  FATFS* filesystem = nullptr;
  const FRESULT result = f_getfree("", &free_clusters, &filesystem);

  if (result != FR_OK || filesystem == nullptr) {
    lua_pushnil(state);
    lua_pushfstring(state, "storage query failed: %d", result);
    return 2;
  }

  const uint64_t bytes_per_cluster =
      static_cast<uint64_t>(filesystem->csize) * FF_MIN_SS;
  const uint64_t total_clusters =
      filesystem->n_fatent > 2 ? filesystem->n_fatent - 2 : 0;
  const uint64_t total_bytes = total_clusters * bytes_per_cluster;
  const uint64_t free_bytes =
      static_cast<uint64_t>(free_clusters) * bytes_per_cluster;

  lua_createtable(state, 0, 3);
  lua_pushinteger(state, static_cast<lua_Integer>(total_bytes));
  lua_setfield(state, -2, "total_bytes");
  lua_pushinteger(state, static_cast<lua_Integer>(free_bytes));
  lua_setfield(state, -2, "free_bytes");
  lua_pushinteger(
      state,
      static_cast<lua_Integer>(total_bytes - free_bytes)
  );
  lua_setfield(state, -2, "used_bytes");
  return 1;
}

const luaL_Reg kDeviceFunctions[] = {
    {"id", id},
    {"storage_root", storage_root},
    {"storage_info", storage_info},
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
