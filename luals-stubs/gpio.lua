-- SPDX-FileCopyrightText: 2025 emily <emily@uni.horse>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `gpio` module contains a function for reading the faceplate interrupt line.
--- @class gpio
local gpio = {}

--- Returns 1 if the faceplate interrupt line is currently high, 0 if low.
--- @return integer
function gpio.get_faceplate_interrupt_level() end

return gpio
