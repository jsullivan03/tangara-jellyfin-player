/*
 * Copyright 2024 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "input/input_lua.hpp"

#include "esp_log.h"
#include "ff.h"
#include "indev/lv_indev.h"
#include "input_trigger.hpp"
#include "lua/lua_thread.hpp"

namespace input {

#define WARN(...) ESP_LOGW("input_lua", __VA_ARGS__)

auto LuaInput::IsScriptPresent() -> bool {
  FILINFO info;
  bool exists = (f_stat(kScriptPath.c_str(), &info) == FR_OK);
  return exists;
}

// Secret bonus module, only available in input scripts.
static char const* const kReadFunc = "input_read_func";
static char const* const kLockFunc = "input_lock_func";
static char const* const kUnlockFunc = "input_unlock_func";
static char const* const kTriggerMetatable = "input_trigger";

static auto register_read_func(lua_State* L) -> int {
  lua_pushstring(L, kReadFunc);
  lua_pushvalue(L, 1);
  lua_settable(L, LUA_REGISTRYINDEX);
  return 0;
}

static auto register_lock_func(lua_State* L) -> int {
  lua_pushstring(L, kLockFunc);
  lua_pushvalue(L, 1);
  lua_settable(L, LUA_REGISTRYINDEX);
  return 0;
}

static auto register_unlock_func(lua_State* L) -> int {
  lua_pushstring(L, kUnlockFunc);
  lua_pushvalue(L, 1);
  lua_settable(L, LUA_REGISTRYINDEX);
  return 0;
}

static auto make_trigger(lua_State* L) -> int {
  void* userdata = lua_newuserdata(L, sizeof(Trigger));
  new (userdata) Trigger;
  luaL_getmetatable(L, kTriggerMetatable);
  lua_setmetatable(L, -2);
  return 1;
}

static const struct luaL_Reg kInputDriverFuncs[] = {
    {"register_read_func", register_read_func},
    {"register_lock_func", register_lock_func},
    {"register_unlock_func", register_unlock_func},
    {"make_trigger", make_trigger},
    {nullptr, nullptr}};

static auto update_trigger(lua_State* L) -> int {
  auto trigger =
      static_cast<Trigger*>(luaL_checkudata(L, 1, kTriggerMetatable));
  auto is_pressed = lua_toboolean(L, 2);
  auto state = trigger->update(is_pressed);
  static char const* state_strings[]{
      "none", "click", "doubleclick", "longpress", "repeatpress", "press",
  };
  lua_pushstring(L, state_strings[int(state)]);
  return 1;
}

static const struct luaL_Reg kTriggerFuncs[] = {{"update", update_trigger},
                                                {nullptr, nullptr}};

LuaInput::LuaInput(std::shared_ptr<lua::LuaThread> ui_thread)
    : ui_thread_(ui_thread) {}

void LuaInput::tryReloadScript() {
  if (!IsScriptPresent()) {
    WARN("tryReloadScript: script not present");
    return;
  }
  auto state = ui_thread_->state();
  luaL_requiref(
      state, "input_device",
      [](lua_State* L) -> int {
        luaL_newmetatable(L, kTriggerMetatable);
        lua_pushliteral(L, "__index");
        lua_pushvalue(L, -2);
        lua_settable(L, -3);  // metatable.__index = metatable
        luaL_setfuncs(L, kTriggerFuncs, 0);
        luaL_newlib(L, kInputDriverFuncs);
        return 1;
      },
      true);

  ui_thread_->RunScript("/sd/" + kScriptPath);
  lua_settop(state, 0);
}

// read t[key], converting booleans to integer 1 or 0
static auto get_int_from_table(lua_State* L, char const* key)
    -> std::optional<int> {
  if (!lua_istable(L, -1)) {
    return {};
  }
  lua_pushstring(L, key);
  lua_gettable(L, -2);
  std::optional<int> rv;
  if (lua_isinteger(L, -1)) {
    rv = lua_tointeger(L, -1);
  } else if (lua_isboolean(L, -1)) {
    rv = lua_toboolean(L, -1) ? 1 : 0;
  }
  lua_pop(L, 1);  // leave the table as the top item
  return rv;
}

static auto do_callback(std::shared_ptr<lua::LuaThread> thread,
                        char const* callback_name,
                        std::function<void(lua_State*)> with_result = nullptr)
    -> void {
  if (!thread) {
    return;
  }
  auto L = thread->state();
  lua_pushstring(L, callback_name);
  lua_gettable(L, LUA_REGISTRYINDEX);
  if (lua_isfunction(L, -1)) {
    int err = lua::CallProtected(L, 0, with_result ? 1 : 0);
    if (err == LUA_OK) {
      if (with_result) {
        with_result(thread->state());
      }
    }
  }
  lua_settop(L, 0);
}

auto LuaInput::read(lv_indev_data_t* data, std::vector<InputEvent>& events)
    -> void {
  do_callback(ui_thread_, kReadFunc, [=](lua_State* L) {
    data->enc_diff += get_int_from_table(L, "encoder_diff").value_or(0);
    if (data->state == LV_INDEV_STATE_RELEASED) {
      data->state = lv_indev_state_t(
          get_int_from_table(L, "encoder_button_pressed").value_or(0));
    }
  });
}

auto LuaInput::name() -> std::string {
  return "lua scripted input";
}

auto LuaInput::onLock() -> void {
  do_callback(ui_thread_, kLockFunc);
}

auto LuaInput::onUnlock() -> void {
  do_callback(ui_thread_, kUnlockFunc);
}
}  // namespace input
