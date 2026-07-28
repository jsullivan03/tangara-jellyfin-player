local lvgl = require("lvgl")
local backstack = require("backstack")
local jellyfin_track_actions =
    require("jellyfin_track_actions")
local styles = require("styles")
local sync_library_view =
    require("sync_library_view")
local sync_operation_queue =
    require("sync_operation_queue")
local widgets = require("widgets")

local TrackMenu
local AddToPlaylistScreen

local function text(value, fallback)
    if type(value) == "string" and
        value ~= "" then
        return value
    end

    return fallback or ""
end

local function create_content(self)
    return self.root:Object {
        flex = {
            flex_direction = "column",
            flex_wrap = "nowrap",
            justify_content = "flex-start",
            align_items = "flex-start",
            align_content = "flex-start",
        },
        w = lvgl.PCT(100),
        flex_grow = 1,
        pad_left = 2,
        pad_right = 2,
        pad_bottom = 2,
        pad_row = 2,
    }
end

local function create_status(parent, value)
    return parent:Label {
        w = lvgl.PCT(100),
        text = value or "",
        text_font = font.fusion_10,
        text_align = 2,
        long_mode = lvgl.LABEL.LONG_WRAP,
        pad_top = 1,
        pad_bottom = 1,
    }
end

local function create_list(parent)
    return lvgl.List(parent, {
        w = lvgl.PCT(100),
        h = lvgl.PCT(100),
        flex_grow = 1,
    })
end

local function add_button(
    list,
    label,
    callback
)
    local button =
        list:add_btn(nil, label)

    button:add_style(styles.list_item)
    button:onClicked(callback)

    return button
end

local function queue_result(
    status_label,
    result,
    error_message,
    success_message
)
    if result then
        status_label:set {
            text = success_message,
        }

        return true
    end

    status_label:set {
        text =
            error_message or
            "Unable to queue the change",
    }

    return false
end

AddToPlaylistScreen =
    widgets.MenuScreen:new {
        show_back = true,
        title = "Add to playlist",

        create_ui = function(self)
            widgets.MenuScreen.create_ui(self)

            local content =
                create_content(self)
            local status_label =
                create_status(
                    content,
                    text(
                        self.track.title,
                        "Track"
                    )
                )
            local list =
                create_list(content)
            local library, library_error =
                sync_library_view.current()

            local back_button =
                add_button(
                    list,
                    "Back",
                    backstack.pop
                )

            back_button:focus()

            if not library then
                status_label:set {
                    text =
                        library_error or
                        "Jellyfin library is unavailable",
                }

                return
            end

            for _, playlist in ipairs(
                library.playlists or {}
            ) do
                local playlist_copy =
                    playlist
                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id

                add_button(
                    list,
                    text(
                        playlist_copy.name,
                        "Playlist"
                    ),
                    function()
                        local operation,
                            operation_error =
                            sync_operation_queue
                                .enqueue_add_playlist_item(
                                    playlist_id,
                                    self.track.id
                                )

                        queue_result(
                            status_label,
                            operation,
                            operation_error,
                            "Added to " ..
                                text(
                                    playlist_copy.name,
                                    "playlist"
                                ) ..
                                "; waiting to sync"
                        )
                    end
                )
            end
        end,
    }

TrackMenu =
    widgets.MenuScreen:new {
        show_back = true,
        title = "Track options",

        create_ui = function(self)
            widgets.MenuScreen.create_ui(self)

            local content =
                create_content(self)
            local status_label =
                create_status(
                    content,
                    text(
                        self.track.title,
                        "Track"
                    )
                )
            local list =
                create_list(content)
            local library, library_error =
                sync_library_view.current()

            local back_button =
                add_button(
                    list,
                    "Back",
                    backstack.pop
                )

            back_button:focus()

            if not library then
                status_label:set {
                    text =
                        library_error or
                        "Jellyfin library is unavailable",
                }

                return
            end

            local favorite =
                jellyfin_track_actions
                    .favorite_state(
                        library,
                        self.track.id
                    )

            add_button(
                list,
                favorite and
                    "Remove favorite" or
                    "Add favorite",
                function()
                    local operation,
                        operation_error =
                        sync_operation_queue
                            .enqueue_set_favorite(
                                self.track.id,
                                not favorite
                            )

                    if queue_result(
                        status_label,
                        operation,
                        operation_error,
                        (
                            favorite and
                                "Favorite removal queued" or
                                "Favorite queued"
                        ) ..
                            "; waiting to sync"
                    ) then
                        favorite =
                            not favorite
                    end
                end
            )

            add_button(
                list,
                "Add to playlist",
                function()
                    backstack.push(
                        AddToPlaylistScreen:new {
                            track = self.track,
                        }
                    )
                end
            )

            if self.collection_kind ~=
                "playlist" then
                return
            end

            local entry_id =
                self.entry_id

            if type(entry_id) ~= "string" or
                entry_id == "" or
                entry_id:match(
                    "^local%-entry:"
                ) then
                add_button(
                    list,
                    "Waiting for playlist sync",
                    function()
                        status_label:set {
                            text =
                                "This new playlist entry must sync before it can be removed",
                        }
                    end
                )

                return
            end

            add_button(
                list,
                "Remove from playlist",
                function()
                    local operation,
                        operation_error =
                        sync_operation_queue
                            .enqueue_remove_playlist_item(
                                self.collection_id,
                                entry_id
                            )

                    queue_result(
                        status_label,
                        operation,
                        operation_error,
                        "Removal queued; waiting to sync"
                    )
                end
            )
        end,
    }

return TrackMenu

