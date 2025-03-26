/*
 * Copyright 2025 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_i2c.hpp"

#include <string>

#include "lua.hpp"

#include "lauxlib.h"
#include "lua.h"

#include "drivers/i2c.hpp"

namespace lua {

struct I2CCommand {
  enum class Type { start, stop, read, write } type;
  uint8_t data;      // for write
  bool ack;          // for read/write
};
static_assert(std::is_trivially_destructible<I2CCommand>());

static char const* kCommandMetatable = "i2c_command";

static auto make_i2c_command(lua_State* L) -> I2CCommand* {
  void* userdata = lua_newuserdata(L, sizeof(I2CCommand));
  I2CCommand* cmd = new (userdata) I2CCommand;
  luaL_getmetatable(L, kCommandMetatable);
  lua_setmetatable(L, -2);
  return cmd;
}

static auto check_i2c_command(lua_State* L, int i) -> I2CCommand* {
  return static_cast<I2CCommand*>(luaL_checkudata(L, i, kCommandMetatable));
}

static auto make_start(lua_State* L) -> int {
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::start;
  return 1;
}

static auto make_stop(lua_State* L) -> int {
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::stop;
  return 1;
}

static char const* const rw_opts[]{
    "write", "read", nullptr};  // order is important, 0=write 1=read in i2c
static char const* const ack_opts[]{
    "nack", "ack", nullptr};  // order also important, it's a boolean

static auto make_read(lua_State* L) -> int {
  auto ack = luaL_checkoption(L, 1, "ack", ack_opts);
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::read;
  c->ack = ack;
  return 1;
}

static auto make_write_addr(lua_State* L) -> int {
  auto addr = luaL_checkinteger(L, 1);
  auto is_read = luaL_checkoption(L, 2, nullptr, rw_opts);
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::write;
  c->data = addr << 1 | is_read;
  c->ack = true;
  return 1;
}

static auto make_write_ack(lua_State* L) -> int {
  auto data = luaL_checkinteger(L, 1);
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::write;
  c->data = data;
  return 1;
}

static auto execute(lua_State* L) -> int {
  int arg_count = lua_gettop(L);

  // first, how many bytes are we reading? allocate a place for them
  int read_count = 0;
  for (int i = 1; i <= arg_count; i++) {
    auto arg = check_i2c_command(L, i);
    if (arg->type == I2CCommand::Type::read) {
      read_count++;
    }
  }
  uint8_t* read_slots = static_cast<uint8_t*>(alloca(read_count));
  int read_index = 0;

  // build and execute the transaction
  drivers::I2CTransaction transaction;
  for (int i = 1; i <= arg_count; i++) {
    auto arg = check_i2c_command(L, i);
    switch (arg->type) {
      case I2CCommand::Type::start: {
        transaction.start();
        break;
      }
      case I2CCommand::Type::read: {
        transaction.read(&read_slots[read_index],
                         arg->ack ? I2C_MASTER_ACK : I2C_MASTER_NACK);
        read_index++;
        break;
      }
      case I2CCommand::Type::write: {
        transaction.write_ack(arg->data);
        break;
      }
      case I2CCommand::Type::stop: {
        transaction.stop();
        break;
      }
    }
  }
  esp_err_t err = transaction.Execute();

  if (err != ESP_OK) {
    return 0;
  }
  for (int i = 0; i < read_count; i++) {
    lua_pushinteger(L, read_slots[i]);
  }

  return read_count;
}

static const struct luaL_Reg kI2CFuncs[] = {{"start", make_start},
                                            {"stop", make_stop},
                                            {"read", make_read},
                                            {"write_addr", make_write_addr},
                                            {"write_ack", make_write_ack},
                                            {"execute", execute},
                                            {NULL, NULL}};

static auto lua_i2c(lua_State* L) -> int {
  luaL_newmetatable(L, kCommandMetatable);
  luaL_newlib(L, kI2CFuncs);
  return 1;
}

auto RegisterI2CModule(lua_State* L) -> void {
  luaL_requiref(L, "i2c", lua_i2c, true);
  lua_pop(L, 1);
}

}  // namespace lua
