/*
 * Copyright 2025 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_i2c.hpp"

#include <string>

#include "driver/i2c.h"
#include "esp_log.h"
#include "lua.hpp"

#include "lauxlib.h"
#include "lua.h"

#include "drivers/i2c.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_i2c";

struct I2CDevice {
  i2c_master_dev_handle_t handle;
};
static_assert(std::is_trivially_destructible<I2CDevice>());
static char const* kDeviceMetatable = "i2c_device";

static auto make_device(lua_State* L) -> int {
  luaL_argexpected(L, lua_istable(L, 1), 1, "options table");

  i2c_device_config_t dev_config;

  lua_getfield(L, 1, "address");
  dev_config.device_address = luaL_checkinteger(L, -1);
  lua_pop(L, 1);

  lua_getfield(L, 1, "address_is_ten_bit");
  dev_config.dev_addr_length =
      lua_toboolean(L, -1) ? I2C_ADDR_BIT_LEN_10 : I2C_ADDR_BIT_LEN_7;
  lua_pop(L, 1);

  lua_getfield(L, 1, "scl_speed_hz");
  dev_config.scl_speed_hz =
      lua_isinteger(L, -1) ? lua_tointeger(L, -1) : 400000;
  lua_pop(L, 1);

  lua_getfield(L, 1, "scl_wait_us");
  dev_config.scl_wait_us = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : 0;
  lua_pop(L, 1);

  lua_getfield(L, 1, "disable_ack_check");
  dev_config.flags.disable_ack_check = lua_toboolean(L, -1);
  lua_pop(L, 1);

  ESP_LOGW(kTag, "make_device: address=%02x dev_addr_length=%d scl_speed_hz=%d scl_wait_us=%d disable_ack_check=%d",
           dev_config.device_address,
           dev_config.dev_addr_length,
           dev_config.scl_speed_hz,
           dev_config.scl_wait_us,
           dev_config.flags.disable_ack_check);

  void* userdata = lua_newuserdata(L, sizeof(I2CDevice));
  I2CDevice* device = new (userdata) I2CDevice;
  luaL_getmetatable(L, kDeviceMetatable);
  lua_setmetatable(L, -2);

  int err = i2c_master_bus_add_device(drivers::i2c_handle(), &dev_config,
                                      &device->handle);
  if (err != ESP_OK) {
    auto err_text = esp_err_to_name(err);
    ESP_LOGE(kTag, "i2c_master_bus_add_device failed (err=%s)", err_text);
    luaL_error(L, "make_device failed: %s", err_text);
    return 0;
  }

  return 1;
}

static auto check_device(lua_State* L, int pos) -> I2CDevice* {
  return reinterpret_cast<I2CDevice*>(
      luaL_checkudata(L, pos, kDeviceMetatable));
}

static auto device_read_register(lua_State* L) -> int {
  auto device = check_device(L, 1);
  auto reg = luaL_checkinteger(L, 2);
  auto count = luaL_checkinteger(L, 3);
  uint8_t tx[] = {static_cast<uint8_t>(reg)};
  uint8_t* rx = reinterpret_cast<uint8_t*>(alloca(count));
  auto err = i2c_master_transmit_receive(device->handle, tx, 1, rx, count, 100);
  if (err != ESP_OK) {
    auto err_text = esp_err_to_name(err);
    ESP_LOGE(kTag, "i2c_master_transmit_receive failed (err=%s)", err_text);
    luaL_error(L, "read failed: %s", err_text);
  }
  for (size_t i = 0; i < count; i++) {
    lua_pushinteger(L, rx[i]);
  }
  return count;
}

static auto device_write_register(lua_State* L) -> int {
  int argc = lua_gettop(L);
  auto device = check_device(L, 1);
  auto count = argc - 1;
  uint8_t* tx = reinterpret_cast<uint8_t*>(alloca(count));
  for (size_t i = 0; i < count; i++) {
    tx[i] = luaL_checkinteger(L, 2 + i);
  }
  auto err = i2c_master_transmit(device->handle, tx, count, 100);
  if (err != ESP_OK) {
    auto err_text = esp_err_to_name(err);
    ESP_LOGE(kTag, "i2c_master_transmit failed (err=%s)", err_text);
    luaL_error(L, "write failed: %s", err_text);
  }

  return 0;
}

static auto device_destroy(lua_State* L) -> int {
  auto device = check_device(L, 1);
  if (device->handle) {
    i2c_master_bus_rm_device(device->handle);
    device->handle = nullptr;
  }
  return 0;
}

static const struct luaL_Reg kI2CFuncs[] = {{"device", make_device},
                                            {NULL, NULL}};

static const struct luaL_Reg kI2CDeviceFuncs[] = {
    {"read", device_read_register},
    {"write", device_write_register},
    {"__gc", device_destroy},
    {"__close", device_destroy},
    {nullptr, nullptr}};

static auto lua_i2c(lua_State* L) -> int {
  luaL_newmetatable(L, kDeviceMetatable);
  luaL_setfuncs(L, kI2CDeviceFuncs, 0);
  lua_pushliteral(L, "__index");
  lua_pushvalue(L, -2);
  lua_settable(L, -3);  // metatable.__index = metatable

  luaL_newlib(L, kI2CFuncs);
  return 1;
}

auto RegisterI2CModule(lua_State* L) -> void {
  luaL_requiref(L, "i2c", lua_i2c, true);
  lua_pop(L, 1);
}

}  // namespace lua
