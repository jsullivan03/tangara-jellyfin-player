-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `controls` module contains Properties relating to the device's physical
--- controls. These controls include the touchwheel, the lock switch, and the
--- side buttons.
--- @class controls
--- @field wheel_scheme Property The currently configured control scheme for the touchwheel
--- @field button_scheme Property The currently configured control scheme for the side buttons
--- @field locked_scheme Property The currently configured control scheme for the side buttons when locked
--- @field scroll_sensitivity Property How much rotational motion is required on the touchwheel per scroll tick.
--- @field lock_switch Property  The current state of the device's lock switch.
--- @field hooks function Returns a table containing the inputs and actions associated with the current control scheme.
local controls = {}

--- @return table
function controls.schemes() end

--- @return table
function controls.locked_schemes() end

--- @return table
function controls.haptics_modes() end

--- @return boolean
function controls.haptics_present() end

--- @return boolean
function controls.touchwheel_present() end

return controls
