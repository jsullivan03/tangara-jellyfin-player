local M = {}

local escapes = {
    ["\\"] = "\\\\",
    ['"'] = '\\"',
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_character(character)
    return escapes[character] or
        string.format(
            "\\u%04x",
            character:byte()
        )
end

local function encode_string(value)
    return '"' ..
        value:gsub(
            '[%z\1-\31\\"]',
            escape_character
        ) ..
        '"'
end

local encode_value

local function table_kind(value)
    local count = 0
    local maximum = 0
    local has_string_key = false

    for key in pairs(value) do
        if type(key) == "number" then
            if key < 1 or
                key ~= math.floor(key) then
                return nil,
                    "table contains an invalid numeric key"
            end

            count = count + 1

            if key > maximum then
                maximum = key
            end
        elseif type(key) == "string" then
            has_string_key = true
        else
            return nil,
                "table contains an unsupported key type"
        end
    end

    if has_string_key then
        if count > 0 then
            return nil,
                "table mixes array and object keys"
        end

        return "object"
    end

    if count == 0 then
        return "array"
    end

    if maximum ~= count then
        return nil,
            "array table is sparse"
    end

    return "array"
end

local function encode_table(value, stack)
    if stack[value] then
        error("JSON table contains a cycle")
    end

    stack[value] = true

    local kind, kind_error =
        table_kind(value)

    if not kind then
        stack[value] = nil
        error(kind_error)
    end

    local parts = {}

    if kind == "array" then
        for index = 1, #value do
            parts[index] =
                encode_value(
                    value[index],
                    stack
                )
        end

        stack[value] = nil

        return "[" ..
            table.concat(parts, ",") ..
            "]"
    end

    local keys = {}

    for key in pairs(value) do
        table.insert(keys, key)
    end

    table.sort(keys)

    for _, key in ipairs(keys) do
        table.insert(
            parts,
            encode_string(key) ..
                ":" ..
                encode_value(
                    value[key],
                    stack
                )
        )
    end

    stack[value] = nil

    return "{" ..
        table.concat(parts, ",") ..
        "}"
end

encode_value = function(value, stack)
    local value_type = type(value)

    if value_type == "nil" then
        return "null"
    end

    if value_type == "boolean" then
        return value and "true" or "false"
    end

    if value_type == "number" then
        if value ~= value or
            value == math.huge or
            value == -math.huge then
            error(
                "JSON cannot encode a non-finite number"
            )
        end

        return string.format("%.17g", value)
    end

    if value_type == "string" then
        return encode_string(value)
    end

    if value_type == "table" then
        return encode_table(
            value,
            stack
        )
    end

    error(
        "JSON cannot encode type " ..
        value_type
    )
end

function M.encode(value)
    return encode_value(value, {})
end

return M
