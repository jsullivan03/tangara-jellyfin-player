local lvgl = require("lvgl")
local jellyfin_theme =
    require("jellyfin_theme")

local M = {}

local DEFAULTS = {
    x = 153,
    y = 2,
    width = 2,
    height = 96,
    minimum_thumb_height = 6,
    visible_items = 3,
    thumb_opacity = 255,
}

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

local function rounded(value)
    return math.floor(value + 0.5)
end

local function positive_integer(
    value,
    fallback
)
    return
        math.max(
            1,
            math.floor(
                tonumber(value) or
                fallback
            )
        )
end

function M.create(
    list,
    options
)
    if options == false or not list then
        return nil
    end

    if type(options) ~= "table" then
        options = {}
    end

    local model = {
        x =
            math.floor(
                tonumber(options.x) or
                DEFAULTS.x
            ),
        y =
            math.floor(
                tonumber(options.y) or
                DEFAULTS.y
            ),
        width =
            positive_integer(
                options.width,
                DEFAULTS.width
            ),
        height =
            positive_integer(
                options.height,
                DEFAULTS.height
            ),
        minimum_thumb_height =
            positive_integer(
                options.minimum_thumb_height,
                DEFAULTS
                    .minimum_thumb_height
            ),
        visible_items =
            positive_integer(
                options.visible_items,
                DEFAULTS.visible_items
            ),
        thumb_color =
            options.thumb_color or
            jellyfin_theme.color(
                "accent"
            ),
        thumb_opacity =
            tonumber(
                options.thumb_opacity
            ) or
            DEFAULTS.thumb_opacity,
    }

    model.minimum_thumb_height =
        math.min(
            model.minimum_thumb_height,
            model.height
        )

    model.thumb =
        list:Object {
            x = model.x,
            y = model.y,
            w = model.width,
            h = model.height,
            pad_all = 0,
            border_width = 0,
            radius = model.width,
            bg_color = model.thumb_color,
            bg_opa = model.thumb_opacity,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    model.thumb:add_flag(
        lvgl.FLAG.FLOATING
    )
    model.thumb:set {
        x = model.x,
        y = model.y,
    }
    model.thumb:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    model.thumb:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    function model:thumb_height_for(
        item_count
    )
        local total =
            math.max(
                1,
                math.floor(
                    tonumber(item_count) or 1
                )
            )
        local visible =
            math.min(
                total,
                self.visible_items
            )

        -- Compress the normal visible/total ratio so the
        -- thumb remains readable on the 128 px display.
        local scaled_fraction =
            math.sqrt(
                visible / total
            )

        return
            clamp(
                rounded(
                    self.height *
                        scaled_fraction
                ),
                self.minimum_thumb_height,
                self.height
            )
    end

    function model:update(
        item_count,
        selected_index
    )
        local total =
            math.max(
                0,
                math.floor(
                    tonumber(item_count) or 0
                )
            )

        if total <= self.visible_items then
            self.thumb:add_flag(
                lvgl.FLAG.HIDDEN
            )
            self.hidden = true
            self.thumb_height = self.height
            self.thumb_y = 0
            return
        end

        self.thumb:clear_flag(
            lvgl.FLAG.HIDDEN
        )
        self.hidden = false

        local thumb_height =
            self:thumb_height_for(total)
        local travel =
            math.max(
                0,
                self.height - thumb_height
            )
        local index =
            clamp(
                math.floor(
                    tonumber(selected_index) or 1
                ),
                1,
                total
            )
        local progress =
            total > 1 and
            (index - 1) / (total - 1) or
            0

        local thumb_y =
            clamp(
                rounded(
                    travel * progress
                ),
                0,
                travel
            )

        self.thumb_height = thumb_height
        self.thumb_y = thumb_y

        self.thumb:set {
            y = self.y + thumb_y,
            h = thumb_height,
        }
    end

    model:update(0, 1)

    return model
end

return M
