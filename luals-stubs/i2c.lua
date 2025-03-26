-- SPDX-FileCopyrightText: 2025 emily <emily@uni.horse>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `i2c` module contains functions for performing I2C communication.
--
-- Example usage:
-- t = i2c.execute(
--   i2c.start(),
--   i2c.write_addr(0x12, 'write'),
--   i2c.write_ack(0x34),
--   i2c.start(),
--   i2c.write_addr(0x12, 'read'),
--   -- read() takes a key to be used in the table execute() returns
--   -- and an optional second parameter, 'ack' or 'nack', defaults to 'ack'
--   i2c.read('high_byte'),
--   i2c.read('low_byte', 'nack'),
--   i2c.stop()
-- )
-- print(t.high_byte)
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
-- @param name key in the returned table. (@see execute)
-- @param ackiness 'ack' or 'nack'
-- @return userdata
function i2c.read(name, ackiness) end

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
-- @return a table, in which the keys are the names passed to read() and the values are the bytes read.
-- the table also contains the special key `i2c_error`, an esp_err_t integer value.
function i2c.execute(...) end

return i2c

