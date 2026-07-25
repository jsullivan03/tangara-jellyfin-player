#include "lua/lua_wifi.hpp"

#include "lauxlib.h"
#include "lua.h"
#include "lua.hpp"
#include "lua/bridge.hpp"

namespace lua {

static auto started(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  lua_pushboolean(L, instance->services().wifi().started());
  return 1;
}

static auto connected(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  lua_pushboolean(L, instance->services().wifi().connected());
  return 1;
}

static auto reload(lua_State* L) -> int {
  Bridge* instance = Bridge::Get(L);
  lua_pushboolean(
      L,
      instance->services().wifi().reload() == ESP_OK
  );
  return 1;
}

static const struct luaL_Reg kWifiFuncs[] = {
    {"started", started},
    {"connected", connected},
    {"reload", reload},
    {NULL, NULL},
};

static auto lua_wifi(lua_State* L) -> int {
  luaL_newlib(L, kWifiFuncs);
  return 1;
}

auto RegisterWifiModule(lua_State* L) -> void {
  luaL_requiref(L, "wifi", lua_wifi, true);
  lua_pop(L, 1);
}

}
