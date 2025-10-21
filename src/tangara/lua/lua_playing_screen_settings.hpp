/*
 * Copyright 2025 Nelbium <nelbium@proton.me>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include "lua.hpp"

namespace lua {

auto RegisterPlayingScreenSettingsModule(lua_State*) -> void;

}  // namespace lua
