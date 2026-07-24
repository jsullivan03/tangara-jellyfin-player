package.path =
    "desktop-sim/?.lua;"
    .. "lua/?.lua;"
    .. package.path

local lvgl = require("lvgl")

-- Tangara normally reads image data through its embedded filesystem. For this
-- first desktop pass, preserve the path as an LVGL image source string instead.
lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local ok, message = pcall(dofile, "lua/main.lua")

if not ok then
    error("Failed to load Tangara UI:\n" .. tostring(message))
end
