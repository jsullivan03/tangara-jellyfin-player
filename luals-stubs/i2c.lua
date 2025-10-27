-- SPDX-FileCopyrightText: 2025 emily <emily@uni.horse>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `i2c` module contains functions for performing I2C communication.
--
-- Example usage:
-- device = i2c.make_device { address = 0x12 }
-- device:write(0x34, 0x56) -- write value 0x56 to register 0x34
-- device:write(0x34, 0x56, 0x78) -- write multiple registers in one transaction
-- low_byte, high_byte = device:read(0x34, 2) -- read registers

--- @class i2c
local i2c = {}

---Create an I2C device.
--- @param config DeviceConfig configuration for the device
--- @return I2CDevice
function i2c.device(config) end

--- @alias DeviceConfig { address: integer, address_is_ten_bit: boolean, scl_speed_hz: integer, scl_wait_us: integer, disable_ack_check: boolean }

--- @class I2CDevice
local I2CDevice = {}

--- Read bytes from a device's registers.
--- @param register integer the first register to read
--- @param count integer the number of registers to read
--- @return ... the bytes read
function I2CDevice:read(register, count) end

--- Write bytes to a device's registers.
--- @param register integer the first register to write
--- @param ... integer the values to write into the registers
--- @return nil
function I2CDevice:write(register, ...) end

return i2c

