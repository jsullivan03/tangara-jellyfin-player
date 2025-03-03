-- SPDX-FileCopyrightText: 2025 emily <emily@uni.horse>
--
-- SPDX-License-Identifier: GPL-3.0-only

--- @meta

--- The `i2c` module contains functions for performing I2C communication.
--- @class i2c
local i2c = {}

--- Create an I2C command representing a start condition.
function i2c.start() end

--- Create an I2C command representing a stop condition.
function i2c.stop() end

--- Create an I2C command representing a byte read.
-- @param name key in the returned table. (@see execute)
-- @param ackiness 'ack' or 'nack'
function i2c.read(name, ackiness) end

--- Create an I2C command representing an address write.
-- @param address the 7-bit I2C peripheral address
-- @param direction 'read' or 'write'
function i2c.write_addr(address, direction) end

--- Create an I2C command representing a data write followed by an ack.
-- @param data the byte to write
function i2c.write_ack(data) end

--- Execute a series of I2C commands in one transaction.
-- @return a table, in which the keys are the names passed to read() and the values are the bytes read.
-- the table also contains the special key `i2c_error`, an esp_err_t integer value.
function i2c.execute(...) end

return i2c

