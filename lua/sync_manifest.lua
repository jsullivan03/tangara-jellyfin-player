local json = require("json")

local M = {}

function M.load(path)
    local file, open_error = io.open(path, "rb")

    if not file then
        return nil, open_error
    end

    local text = file:read("*a")
    file:close()

    local ok, manifest = pcall(json.decode, text)

    if not ok then
        return nil, manifest
    end

    if type(manifest) ~= "table" then
        return nil, "manifest root must be an object"
    end

    if type(manifest.device) ~= "table" then
        return nil, "manifest is missing device information"
    end

    if type(manifest.items) ~= "table" then
        return nil, "manifest is missing items"
    end

    return manifest
end

return M
