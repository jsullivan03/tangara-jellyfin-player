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
