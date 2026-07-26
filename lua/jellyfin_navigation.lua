local M = {}

local back_handler = nil

function M.set_back(handler)
    if type(handler) == "function" then
        back_handler = handler
    else
        back_handler = nil
    end
end

function M.clear_back(handler)
    if handler == nil or
        back_handler == handler then
        back_handler = nil
    end
end

function M.back()
    if type(back_handler) ~= "function" then
        return false
    end

    back_handler()
    return true
end

return M
