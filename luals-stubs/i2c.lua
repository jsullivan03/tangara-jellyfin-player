-- SPDX-FileCopyrightText: 2025 emily <emily@uni.horse>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `i2c` module contains functions for performing I2C communication.
--
-- Example usage:
-- low_byte, high_byte = i2c.execute(
--   i2c.start(),
--   i2c.write_addr(0x12, 'write'),
--   i2c.write_ack(0x34),
--   i2c.start(),
--   i2c.write_addr(0x12, 'read'),
--   -- read() takes an optional second parameter, 'ack' or 'nack', defaults to 'ack'
--   i2c.read(),
--   i2c.read('nack'),
--   i2c.stop()
-- )
-- print(high_byte)
-- 
--- @class i2c

local i2c = {}

--- Create an I2C command representing a start condition.
-- @return userdata
function i2c.start() end

--- Create an I2C command representing a stop condition.
-- @return userdata
function i2c.stop() end

--- Create an I2C command representing a byte read.
-- @param ackiness 'ack' or 'nack'
-- @return userdata
function i2c.read(ackiness) end

--- Create an I2C command representing an address write.
-- @param address the 7-bit I2C peripheral address
-- @param direction 'read' or 'write'
-- @return userdata
function i2c.write_addr(address, direction) end

--- Create an I2C command representing a data write followed by an ack.
-- @param data the byte to write
-- @return userdata
function i2c.write_ack(data) end

--- Execute a series of I2C commands in one transaction.
-- @return multiple values, one for each read byte, in the same order as the read() calls.
function i2c.execute(...) end

return i2c

