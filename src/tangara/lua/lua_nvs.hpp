/*
 * Copyright 2024 Clayton Craft <clayton@craftyguy.net>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include "lua.hpp"

namespace lua {

auto RegisterNvsModule(lua_State*) -> void;

}  // namespace lua
