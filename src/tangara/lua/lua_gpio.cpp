/*
 * Copyright 2025 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "driver/gpio.h"

#include "lua.hpp"

#include "lauxlib.h"
#include "lua.h"

namespace lua {
static const gpio_num_t kFaceplateInterruptPin = GPIO_NUM_25;

static void maybe_init_faceplate_interrupt() {
  static bool did_init = false;
  if (did_init)
    return;

  gpio_config_t int_config{
      .pin_bit_mask = 1ULL << kFaceplateInterruptPin,
      .mode = GPIO_MODE_INPUT,
      .pull_up_en = GPIO_PULLUP_ENABLE,
      .pull_down_en = GPIO_PULLDOWN_DISABLE,
      .intr_type = GPIO_INTR_DISABLE,
  };
  gpio_config(&int_config);
  did_init = true;
}

static int get_faceplate_interrupt_level(lua_State* L) {
  maybe_init_faceplate_interrupt();
  lua_pushinteger(L, gpio_get_level(kFaceplateInterruptPin));
  return 1;
}

static const struct luaL_Reg kFaceplateInterruptFuncs[] = {
    {"get_faceplate_interrupt_level", get_faceplate_interrupt_level},
    {NULL, NULL}};

static auto lua_gpio(lua_State* L) -> int {
  luaL_newlib(L, kFaceplateInterruptFuncs);
  return 1;
}

auto RegisterGPIOModule(lua_State* L) -> void {
  luaL_requiref(L, "gpio", lua_gpio, true);
  lua_pop(L, 1);
}

}  // namespace lua
