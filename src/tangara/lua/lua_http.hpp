#pragma once

struct lua_State;

namespace lua {

auto RegisterHttpModule(lua_State* state) -> void;

}
