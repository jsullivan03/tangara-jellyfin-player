local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_now_playing =
    require("jellyfin_now_playing")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_status_bar =
    require("jellyfin_status_bar")
local jellyfin_track_menu =
    require("jellyfin_track_menu")
local screen = require("screen")
local sync_library_view =
    require("sync_library_view")

local LibraryScreen
local CollectionScreen

local function text(value, fallback)
    if type(value) == "string" and
        value ~= "" then
        return value
    end

    return fallback or ""
end

local function track_count_text(count)
    count = tonumber(count) or 0

    if count == 1 then
        return "1 track"
    end

    return tostring(count) ..
        " tracks"
end

local function artwork_path(
    collection,
    fallback
)
    if type(collection) == "table" and
        type(collection.artwork) ==
            "table" and
        type(collection.artwork.cover) ==
            "string" and
        collection.artwork.cover ~= "" then
        return collection.artwork.cover
    end

    return fallback
end

local function create_text_window(
    parent,
    options
)
    local view =
        parent:Object {
            x = options.x,
            y = options.y,
            w = options.w,
            h = options.h,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    view:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    view:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local label =
        view:Label {
            x = 0,
            y = 0,
            text = options.text or "",
            text_color =
                options.text_color or
                "#FFFFFF",
            text_font =
                options.text_font or
                font.fusion_10,
        }

    label:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local function set_mode(mode)
        label:set {
            long_mode = mode,
            w = options.w,
            h = options.h,
        }
    end

    local function stop()
        set_mode(
            lvgl.LABEL.LONG_CLIP
        )
    end

    local function start()
        set_mode(
            lvgl.LABEL
                .LONG_SCROLL_CIRCULAR
        )
    end

    stop()

    return {
        view = view,
        label = label,
        start = start,
        stop = stop,
    }
end

local function create_root(
    self,
    title
)
    self.root = lvgl.Object(nil, {
        x = 0,
        y = 0,
        w = 160,
        h = 128,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = "#07080C",
        bg_opa = 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    })

    self.root:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    self.go_back =
        function()
            backstack.pop()
        end

    self.status =
        jellyfin_status_bar.create(
            self.root
        )

    self.bindings =
        self.status.bindings

    self.header =
        self.root:Label {
            x = 5,
            y = 15,
            w = 150,
            h = 11,
            text = title or "",
            text_align = 2,
            text_color = "#FFFFFF",
            text_font = font.fusion_10,
        }

    self.list =
        lvgl.List(
            self.root,
            {
                x = 2,
                y = 28,
                w = 156,
                h = 100,
            }
        )

    self.list:set {
        pad_all = 0,
        pad_row = 1,
        border_width = 0,
        radius = 0,
        bg_color = "#07080C",
        bg_opa = 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }
end

local function install_controls(self)
    local group =
        lvgl.group.get_default()

    self.focus_group = group

    local got_wrap, previous_wrap =
        pcall(
            function()
                return group:get_wrap()
            end
        )

    self.previous_group_wrap =
        got_wrap and
        previous_wrap or
        true

    pcall(
        function()
            group:set_wrap(false)
        end
    )

    if self.list then
        lvgl.group.remove_obj(
            self.list
        )
    end

    if self.first_row then
        lvgl.group.focus_obj(
            self.first_row
        )
    end

    jellyfin_navigation.set_back(
        self.go_back
    )

    local hooks =
        controls.hooks()

    local input_method =
        hooks.wheel or
        hooks.dpad

    if not input_method then
        return
    end

    self.input_method =
        input_method

    if input_method.up then
        self.previous_up_long =
            input_method.up.long_press

        input_method.up.long_press =
            self.go_back
    end
end

local function restore_controls(self)
    jellyfin_navigation.clear_back(
        self.go_back
    )

    if self.focus_group then
        pcall(
            function()
                self.focus_group:set_wrap(
                    self.previous_group_wrap
                        ~= false
                )
            end
        )
    end

    self.focus_group = nil

    local input_method =
        self.input_method

    if not input_method then
        return
    end

    if input_method.up and
        input_method.up.long_press ==
            self.go_back then
        input_method.up.long_press =
            self.previous_up_long
    end

    self.input_method = nil
end

local function set_row_focus(
    row,
    focused
)
    row:set {
        bg_color = "#34363F",
        bg_opa =
            focused and
            255 or
            0,
    }
end

local function add_playlist_row(
    list,
    collection,
    fallback_artwork,
    callback,
    focus
)
    local row =
        list:Button {
            w = lvgl.PCT(100),
            h = 32,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local artwork_view =
        row:Object {
            x = 2,
            y = 2,
            w = 28,
            h = 28,
            pad_all = 0,
            border_width = 0,
            radius = 2,
            bg_color = "#161820",
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    artwork_view:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    artwork_view:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local artwork =
        artwork_view:Image {
        x = 0,
        y = 0,
        src =
            lvgl.ImgData(
                artwork_path(
                    collection,
                    fallback_artwork
                )
            ),
        }

    artwork:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local name =
        create_text_window(
            row,
            {
                x = 35,
                y = 4,
                w = 116,
                h = 11,
                text =
                    text(
                        collection.name,
                        "Playlist"
                    ),
                text_color =
                    "#FFFFFF",
            }
        )

    local detail =
        track_count_text(
            collection.track_count or
            #(collection.items or {})
        )

    if collection.pending then
        detail =
            detail .. " - pending"
    end

    create_text_window(
        row,
        {
            x = 35,
            y = 17,
            w = 116,
            h = 10,
            text = detail,
            text_color = "#AEB0B8",
        }
    )

    row:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            set_row_focus(
                row,
                true
            )
            name.start()
        end
    )

    row:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            set_row_focus(
                row,
                false
            )
            name.stop()
        end
    )

    row:onevent(
        lvgl.EVENT.PRESSED,
        function()
            lvgl.group.focus_obj(row)
        end
    )

    row:onClicked(callback)

    if focus then
        row:focus()
    end

    return row
end

local function add_track_row(
    list,
    track,
    click_callback,
    context_callback,
    focus
)
    local row =
        list:Button {
            w = lvgl.PCT(100),
            h = 25,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    local title =
        create_text_window(
            row,
            {
                x = 5,
                y = 3,
                w = 146,
                h = 11,
                text =
                    text(
                        track.title,
                        "Unknown Track"
                    ),
                text_color =
                    "#FFFFFF",
            }
        )

    create_text_window(
        row,
        {
            x = 5,
            y = 14,
            w = 146,
            h = 9,
            text =
                text(
                    track.artist,
                    track.album
                ),
            text_color = "#AEB0B8",
        }
    )

    local suppress_click = false

    row:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            set_row_focus(
                row,
                true
            )
            title.start()
        end
    )

    row:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            set_row_focus(
                row,
                false
            )
            title.stop()
        end
    )

    row:onevent(
        lvgl.EVENT.LONG_PRESSED,
        function()
            suppress_click = true
            context_callback()

            lvgl.Timer {
                period = 1000,
                repeat_count = 1,
                cb = function()
                    suppress_click = false
                end,
            }
        end
    )

    row:onevent(
        lvgl.EVENT.PRESSED,
        function()
            lvgl.group.focus_obj(row)
        end
    )

    row:onClicked(
        function()
            if suppress_click then
                suppress_click = false
                return
            end

            click_callback()
        end
    )

    if focus then
        row:focus()
    end

    return row
end

local function add_message(
    list,
    message,
    focus
)
    local row =
        list:Button {
            w = lvgl.PCT(100),
            h = 25,
            pad_all = 0,
            border_width = 0,
            outline_width = 0,
            shadow_width = 0,
            radius = 3,
            bg_opa = 0,
        }

    row:Label {
        x = 5,
        y = 7,
        w = 146,
        text = message,
        text_align = 2,
        text_color = "#B8BAC2",
        text_font = font.fusion_10,
    }

    row:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            set_row_focus(
                row,
                true
            )
        end
    )

    row:onevent(
        lvgl.EVENT.DEFOCUSED,
        function()
            set_row_focus(
                row,
                false
            )
        end
    )

    row:onevent(
        lvgl.EVENT.PRESSED,
        function()
            lvgl.group.focus_obj(row)
        end
    )

    if focus then
        row:focus()
    end

    return row
end

local function find_playlist(
    library,
    playlist_id
)
    for _, playlist in ipairs(
        library.playlists or {}
    ) do
        if playlist.id == playlist_id or
            playlist.local_id ==
                playlist_id then
            return playlist
        end
    end

    return nil
end

CollectionScreen =
    screen:new {
        create_ui = function(self)
            create_root(
                self,
                self.title or
                    "Playlist"
            )

            local library, library_error =
                sync_library_view.current()

            if not library then
                self.first_row =
                    add_message(
                        self.list,
                        library_error or
                            "Library unavailable",
                        false
                    )

                return
            end

            local collection

            if self.collection_kind ==
                "favorites" then
                collection =
                    library.favorites
            else
                collection =
                    find_playlist(
                        library,
                        self.collection_id
                    )
            end

            if not collection then
                self.first_row =
                    add_message(
                        self.list,
                        "Playlist unavailable",
                        false
                    )

                return
            end

            local sorted_items =
                jellyfin_sort.newest_added(
                    collection.items or {}
                )

            if #sorted_items == 0 then
                self.first_row =
                    add_message(
                        self.list,
                        "No tracks",
                        false
                    )

                return
            end

            for index, track in ipairs(
                sorted_items
            ) do
                local track_copy = track
                local context = {
                    collection_kind =
                        self.collection_kind,
                    collection_id =
                        self.collection_id,
                    entry_id =
                        track_copy
                            .playlist_entry_id,
                }

                local row =
                    add_track_row(
                        self.list,
                        track_copy,
                        function()
                            local played =
                                jellyfin_playback
                                    .play(
                                        track_copy,
                                        context
                                    )

                            if not played then
                                return
                            end

                            backstack.push(
                                jellyfin_now_playing
                                    :new()
                            )
                        end,
                        function()
                            backstack.push(
                                jellyfin_track_menu
                                    :new {
                                        track =
                                            track_copy,
                                        collection_kind =
                                            context
                                                .collection_kind,
                                        collection_id =
                                            context
                                                .collection_id,
                                        entry_id =
                                            context
                                                .entry_id,
                                    }
                            )
                        end,
                        false
                    )

                if index == 1 then
                    self.first_row = row
                end
            end
        end,

        on_show = install_controls,
        on_hide = restore_controls,
    }

LibraryScreen =
    screen:new {
        create_ui = function(self)
            create_root(
                self,
                "Playlists"
            )

            local library, library_error =
                sync_library_view.current()

            if not library then
                self.first_row =
                    add_message(
                        self.list,
                        library_error or
                            "Library unavailable",
                        false
                    )

                return
            end

            local favorites =
                library.favorites

            self.first_row =
                add_playlist_row(
                    self.list,
                    favorites,
                    "//lua/img/favorites_playlist.png",
                    function()
                        backstack.push(
                            CollectionScreen:new {
                                title = "Favorites",
                                collection_kind =
                                    "favorites",
                            }
                        )
                    end,
                    false
                )

            for _, playlist in ipairs(
                library.playlists or {}
            ) do
                local playlist_copy =
                    playlist

                local playlist_id =
                    playlist_copy.local_id or
                    playlist_copy.id

                add_playlist_row(
                    self.list,
                    playlist_copy,
                    "//lua/img/playlist_placeholder.png",
                    function()
                        backstack.push(
                            CollectionScreen:new {
                                title =
                                    text(
                                        playlist_copy
                                            .name,
                                        "Playlist"
                                    ),
                                collection_kind =
                                    "playlist",
                                collection_id =
                                    playlist_id,
                            }
                        )
                    end,
                    false
                )
            end
        end,

        on_show = install_controls,
        on_hide = restore_controls,
    }

return LibraryScreen
