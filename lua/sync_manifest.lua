local json = require("json")

local M = {}

function M.validate(manifest)
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

function M.decode(text)
    if type(text) ~= "string" then
        return nil, "manifest text must be a string"
    end

    local ok, manifest = pcall(json.decode, text)

    if not ok then
        return nil, manifest
    end

    return M.validate(manifest)
end

function M.load(path)
    local file, open_error = io.open(path, "rb")

    if not file then
        return nil, open_error
    end

    local text = file:read("*a")
    file:close()

    return M.decode(text)
end

return M
