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
/*
api looks like this:
t = i2c.execute(
  i2c.start(),
  i2c.write_addr(0x12, 'write'),
  i2c.write_ack(0x34),
  i2c.start(),
  i2c.write_addr(0x12, 'read'),
  -- read() takes a key to be used in the table execute() returns
  -- and an optional second parameter, 'ack' or 'nack', defaults to 'ack'
  i2c.read('high_byte'),
  i2c.read('low_byte', 'nack'),
  i2c.stop()
)
print(t.high_byte)

everything passed to execute() is lua-specific placeholder objects. they are
transformed into the real i2c operations as part of execute()

doing this instead of the function chaining thing the c++ api does means we
don't have to figure out how to pass a pointer to uint8_t from lua to c++ and
have it remain valid across several function calls
*/

struct I2CCommand {
  enum class Type { start, stop, read, write } type;
  std::string name;  // for read
  uint8_t data;      // for write
  bool ack;          // for read/write
};
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
  auto name = luaL_checkstring(L, 1);
  auto ack = luaL_checkoption(L, 2, "ack", ack_opts);
  auto c = make_i2c_command(L);
  c->type = I2CCommand::Type::read;
  c->name = name;
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

  // match the read values with their names, and stuff them into a table to return
  lua_createtable(L, 0, read_count);
  if (err != ESP_OK) {
    lua_pushstring(L, esp_err_to_name(err));
    lua_setfield(L, -2, "i2c_error");
  }
  read_index = 0;
  for (int i = 1; i <= arg_count; i++) {
    auto arg = check_i2c_command(L, i);
    if (arg->type == I2CCommand::Type::read) {
      lua_pushinteger(L, read_slots[read_index]);
      lua_setfield(L, -2, arg->name.c_str());
      read_index++;
    }
  }

  return 1;
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
