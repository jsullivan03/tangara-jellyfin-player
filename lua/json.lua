local M = {}

M.null = {}

local function fail(position, message)
    error(
        string.format("JSON error at byte %d: %s", position, message),
        0
    )
end

local function skip_whitespace(text, position)
    while position <= #text do
        local byte = text:byte(position)

        if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            break
        end

        position = position + 1
    end

    return position
end

local escape_values = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

local function parse_string(text, position)
    position = position + 1

    local pieces = {}
    local start = position

    while position <= #text do
        local byte = text:byte(position)

        if byte == 34 then
            if start < position then
                pieces[#pieces + 1] = text:sub(start, position - 1)
            end

            return table.concat(pieces), position + 1
        end

        if byte == 92 then
            if start < position then
                pieces[#pieces + 1] = text:sub(start, position - 1)
            end

            local escape = text:sub(position + 1, position + 1)
            local replacement = escape_values[escape]

            if replacement then
                pieces[#pieces + 1] = replacement
                position = position + 2
                start = position
            elseif escape == "u" then
                local hexadecimal = text:sub(position + 2, position + 5)
                local codepoint = tonumber(hexadecimal, 16)

                if #hexadecimal ~= 4 or not codepoint then
                    fail(position, "invalid Unicode escape")
                end

                position = position + 6

                if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                    if text:sub(position, position + 1) ~= "\\u" then
                        fail(position, "missing Unicode low surrogate")
                    end

                    local low_hexadecimal = text:sub(
                        position + 2,
                        position + 5
                    )
                    local low = tonumber(low_hexadecimal, 16)

                    if not low or low < 0xDC00 or low > 0xDFFF then
                        fail(position, "invalid Unicode low surrogate")
                    end

                    codepoint =
                        0x10000
                        + (codepoint - 0xD800) * 0x400
                        + (low - 0xDC00)

                    position = position + 6
                elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                    fail(position, "unexpected Unicode low surrogate")
                end

                pieces[#pieces + 1] = utf8.char(codepoint)
                start = position
            else
                fail(position, "invalid escape sequence")
            end
        elseif byte < 32 then
            fail(position, "control character inside string")
        else
            position = position + 1
        end
    end

    fail(position, "unterminated string")
end

local function parse_number(text, position)
    local start = position

    if text:sub(position, position) == "-" then
        position = position + 1
    end

    local first = text:byte(position)

    if first == 48 then
        position = position + 1
    elseif first and first >= 49 and first <= 57 then
        repeat
            position = position + 1
            first = text:byte(position)
        until not first or first < 48 or first > 57
    else
        fail(position, "invalid number")
    end

    if text:sub(position, position) == "." then
        position = position + 1

        local digit = text:byte(position)

        if not digit or digit < 48 or digit > 57 then
            fail(position, "invalid fractional number")
        end

        repeat
            position = position + 1
            digit = text:byte(position)
        until not digit or digit < 48 or digit > 57
    end

    local exponent = text:sub(position, position)

    if exponent == "e" or exponent == "E" then
        position = position + 1

        local sign = text:sub(position, position)

        if sign == "+" or sign == "-" then
            position = position + 1
        end

        local digit = text:byte(position)

        if not digit or digit < 48 or digit > 57 then
            fail(position, "invalid exponent")
        end

        repeat
            position = position + 1
            digit = text:byte(position)
        until not digit or digit < 48 or digit > 57
    end

    local value = tonumber(text:sub(start, position - 1))

    if not value then
        fail(start, "invalid number")
    end

    return value, position
end

local parse_value

local function parse_array(text, position)
    local result = {}
    position = skip_whitespace(text, position + 1)

    if text:sub(position, position) == "]" then
        return result, position + 1
    end

    while true do
        local value

        value, position = parse_value(text, position)
        result[#result + 1] = value
        position = skip_whitespace(text, position)

        local separator = text:sub(position, position)

        if separator == "]" then
            return result, position + 1
        end

        if separator ~= "," then
            fail(position, "expected ',' or ']'")
        end

        position = skip_whitespace(text, position + 1)
    end
end

local function parse_object(text, position)
    local result = {}
    position = skip_whitespace(text, position + 1)

    if text:sub(position, position) == "}" then
        return result, position + 1
    end

    while true do
        if text:sub(position, position) ~= '"' then
            fail(position, "expected object key")
        end

        local key
        key, position = parse_string(text, position)
        position = skip_whitespace(text, position)

        if text:sub(position, position) ~= ":" then
            fail(position, "expected ':'")
        end

        local value
        value, position = parse_value(
            text,
            skip_whitespace(text, position + 1)
        )

        result[key] = value
        position = skip_whitespace(text, position)

        local separator = text:sub(position, position)

        if separator == "}" then
            return result, position + 1
        end

        if separator ~= "," then
            fail(position, "expected ',' or '}'")
        end

        position = skip_whitespace(text, position + 1)
    end
end

parse_value = function(text, position)
    position = skip_whitespace(text, position)

    local character = text:sub(position, position)

    if character == '"' then
        return parse_string(text, position)
    end

    if character == "{" then
        return parse_object(text, position)
    end

    if character == "[" then
        return parse_array(text, position)
    end

    if character == "-" or character:match("%d") then
        return parse_number(text, position)
    end

    if text:sub(position, position + 3) == "true" then
        return true, position + 4
    end

    if text:sub(position, position + 4) == "false" then
        return false, position + 5
    end

    if text:sub(position, position + 3) == "null" then
        return M.null, position + 4
    end

    fail(position, "unexpected value")
end

function M.decode(text)
    if type(text) ~= "string" then
        error("json.decode expects a string", 2)
    end

    local value, position = parse_value(text, 1)
    position = skip_whitespace(text, position)

    if position <= #text then
        fail(position, "trailing content")
    end

    return value
end

return M
