#pragma once

struct lua_State;

namespace lua {

auto RegisterDownloadModule(lua_State* state) -> void;

}
