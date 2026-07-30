-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- @class device
local device = {}

--- @return string|nil id
--- @return string|nil error
function device.id() end

--- @return string|nil path
--- @return string|nil error
function device.storage_root() end

--- @return table|nil info
--- @return string|nil error
function device.storage_info() end

return device
