local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")

local M = {}

local function resolve(
    value,
    item
)
    if type(value) == "function" then
        return value(item)
    end

    return value
end

function M.create(
    screen,
    items,
    options
)
    options = options or {}

    local controller =
        jellyfin_virtual_list.create(
            screen,
            items,
            {
                item_label = "track",
                item_plural = "tracks",
                item_id = options.item_id,
                pool_size = options.pool_size,
                anchor = options.anchor,
                row_height = options.row_height,
                row_gap = options.row_gap,
                fixed_viewport =
                    options.fixed_viewport,
                viewport_height =
                    options.viewport_height,
                motion_duration =
                    options.motion_duration,
                total_count =
                    options.total_count,
                scroll_indicator =
                    options.scroll_indicator,
                on_focus = options.on_focus,
                on_click = options.on_click,
                on_long_press =
                    options.on_long_press,
                create_row =
                    function(owner, track)
                        return
                            jellyfin_list_ui
                                .add_track_row(
                                    owner,
                                    track,
                                    {
                                        artwork =
                                            resolve(
                                                options.artwork,
                                                track
                                            ),
                                        detail =
                                            resolve(
                                                options.detail,
                                                track
                                            ),
                                        available =
                                            resolve(
                                                options.available,
                                                track
                                            ),
                                    }
                                )
                    end,
                update_row =
                    function(
                        model,
                        track,
                        handlers
                    )
                        model:update(
                            track,
                            {
                                artwork =
                                    resolve(
                                        options.artwork,
                                        track
                                    ),
                                detail =
                                    resolve(
                                        options.detail,
                                        track
                                    ),
                                available =
                                    resolve(
                                        options.available,
                                        track
                                    ),
                                on_click =
                                    handlers.on_click,
                                on_long_press =
                                    handlers
                                        .on_long_press,
                            }
                        )
                    end,
            }
        )

    screen.virtual_track_list =
        controller

    return controller
end

return M
