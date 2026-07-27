local M = {}

local generation = 0
local last_reason = "startup"

function M.current()
    return generation
end

function M.invalidate(reason)
    generation = generation + 1

    if type(reason) == "string" and
        reason ~= "" then
        last_reason = reason
    else
        last_reason = "unspecified"
    end

    return generation
end

function M.snapshot()
    return {
        generation = generation,
        last_reason = last_reason,
    }
end

return M
