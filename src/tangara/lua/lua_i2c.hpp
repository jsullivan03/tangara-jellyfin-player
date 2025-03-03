/*
 * Copyright 2025 emily <emily@uni.horse>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include "lua.hpp"

namespace lua {
auto RegisterI2CModule(lua_State*) -> void;
}
