local M = {}

local function date_value(item)
    if type(item) ~= "table" or
        type(item.date_created) ~= "string" then
        return ""
    end

    return item.date_created
end

function M.newest_added(items)
    local decorated = {}

    for index, item in ipairs(items or {}) do
        table.insert(decorated, {
            item = item,
            index = index,
            date_created = date_value(item),
        })
    end

    table.sort(
        decorated,
        function(left, right)
            local left_date =
                left.date_created
            local right_date =
                right.date_created

            if left_date == right_date then
                return left.index <
                    right.index
            end

            if left_date == "" then
                return false
            end

            if right_date == "" then
                return true
            end

            return left_date > right_date
        end
    )

    local sorted = {}

    for _, entry in ipairs(decorated) do
        table.insert(sorted, entry.item)
    end

    return sorted
end

return M
