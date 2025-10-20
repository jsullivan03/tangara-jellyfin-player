
/*
 * Copyright 2025 Nelbium <nelbium@proton.me>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "lua/lua_playing_screen_settings.hpp"

#include <memory>
#include <string>

#include "lua.hpp"

#include "esp_log.h"
#include "lauxlib.h"
#include "lua.h"
#include "lvgl.h"

#include "drivers/nvs.hpp"
#include "ui/ui_events.hpp"

namespace lua {

[[maybe_unused]] static constexpr char kTag[] = "lua_playing_screen_settings";

static auto long_text_schemes(lua_State* L) -> int {
  lua_newtable(L);

  lua_pushliteral(L, "Default");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::LongTextModes::kDefault));

  lua_pushliteral(L, "Ellipsize");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::LongTextModes::kEllipsize));

  lua_pushliteral(L, "Scroll");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::LongTextModes::kScroll));
  lua_pushliteral(L, "Scroll Circular");
  lua_rawseti(
      L, -2,
      static_cast<int>(drivers::NvsStorage::LongTextModes::kScrollCircular));
  lua_pushliteral(L, "Clip");
  lua_rawseti(L, -2,
              static_cast<int>(drivers::NvsStorage::LongTextModes::kClip));

  return 1;
}

static const struct luaL_Reg kPlayingScreenSettingsFuncs[] = {
    {"long_text_schemes", long_text_schemes},
    {NULL, NULL}};

static auto lua_playing_screen_settings(lua_State* state) -> int {
  luaL_newlib(state, kPlayingScreenSettingsFuncs);
  return 1;
}

auto RegisterPlayingScreenSettingsModule(lua_State* s) -> void {
  luaL_requiref(s, "playing_screen_settings", lua_playing_screen_settings,
                true);
  lua_pop(s, 1);
}

}  // namespace lua
