-- SPDX-FileCopyrightText: 2023 jacqueline <me@jacqueline.id.au>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `time` module contains functions for dealing with the current time
--- since boot.
--- @class time
local time = {}

--- Returns the time in milliseconds since the device booted.
--- @return integer
function time.ticks() end

return time
