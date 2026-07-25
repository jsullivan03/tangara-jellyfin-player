#pragma once

struct lua_State;

namespace lua {

auto RegisterDeviceModule(lua_State* state) -> void;

}
