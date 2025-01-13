-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `controls` module contains Properties relating to the device's physical
--- controls. These controls include the touchwheel, the lock switch, and the
--- side buttons.
--- @class controls
--- @field scheme Property The currently configured control scheme
--- @field scroll_sensitivity Property How much rotational motion is required on the touchwheel per scroll tick.
--- @field lock_switch Property  The current state of the device's lock switch.
--- @field hooks funtion Returns a table containing the inputs and actions associated with the current control scheme.
local controls = {}

return controls
