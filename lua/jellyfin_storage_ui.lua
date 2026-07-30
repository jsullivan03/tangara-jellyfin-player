local backstack = require("backstack")
local lvgl = require("lvgl")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_storage =
    require("jellyfin_storage")
local jellyfin_sort =
    require("jellyfin_sort")
local jellyfin_theme =
    require("jellyfin_theme")
local jellyfin_virtual_list =
    require("jellyfin_virtual_list")
local jellyfin_virtual_track_list =
    require("jellyfin_virtual_track_list")
local screen = require("screen")

local M = {}

local StorageScreen
local AlbumsScreen
local TracksScreen
local ActionScreen
local ConfirmScreen

local function artwork_path(item)
    local artwork =
        item and item.artwork

    if type(artwork) == "table" then
        for _, key in ipairs({
            "thumbnail",
            "cover",
        }) do
            local value = artwork[key]

            if type(value) == "string" and
                value ~= "" then
                return value
            end
        end
    end

    return
        "//lua/img/playlist_placeholder.png"
end

local function load_snapshot(self)
    local snapshot, snapshot_error =
        jellyfin_storage.snapshot()

    if snapshot then
        return snapshot
    end

    local message =
        jellyfin_list_ui.add_message(
            self,
            snapshot_error or
                "Storage unavailable"
        )

    self.first_row = message.object
    return nil
end

local function add_sort_control(
    self,
    key,
    kind,
    on_apply
)
    jellyfin_sort.ensure(
        key,
        kind,
        {
            "alpha",
            "recent",
        }
    )

    local function state()
        local current =
            jellyfin_sort.current(
                key,
                kind
            )

        current.alpha_label =
            jellyfin_sort.order_label(
                key,
                "alpha",
                kind
            )
        current.recent_label =
            jellyfin_sort.order_label(
                key,
                "recent",
                kind
            )

        return current
    end

    local current = state()

    jellyfin_list_ui.add_sort_control(
        self,
        {
            methods = {
                "alpha",
                "recent",
            },
            current_method = current.method,
            current_label = current.label,
            alpha_label =
                current.alpha_label,
            recent_label =
                current.recent_label,
            on_highlight =
                function(method)
                    jellyfin_sort.choose(
                        key,
                        method,
                        kind
                    )
                    return state()
                end,
            on_toggle =
                function(method)
                    jellyfin_sort.toggle(
                        key,
                        method,
                        kind
                    )
                    return state()
                end,
            on_apply = on_apply,
        }
    )
end

ConfirmScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Confirm cleanup"
            )

            local message =
                jellyfin_list_ui.add_message(
                    self,
                    self.message or
                        "Remove local data?"
                )

            local cancel =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "Cancel",
                        {
                            selection_id =
                                "storage:cancel",
                            on_click =
                                function()
                                    backstack.pop()
                                end,
                        }
                    )

            local confirm
            confirm =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        self.confirm_label or
                            "Confirm",
                        {
                            selection_id =
                                "storage:confirm",
                            on_click =
                                function()
                                    local ok, err =
                                        self.on_confirm()

                                    if not ok then
                                        confirm:set_label(
                                            err or
                                            "Cleanup failed"
                                        )
                                        return
                                    end

                                    backstack.pop()

                                    if self.on_success then
                                        self.on_success()
                                    end
                                end,
                        }
                    )

            self.message_row = message
            self.cancel_row = cancel
            self.confirm_row = confirm
            self.first_row = cancel.object
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

ActionScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                self.title or
                    "Storage action"
            )

            local action =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        self.action_label,
                        {
                            selection_id =
                                "storage:remove",
                            on_click =
                                function()
                                    backstack.push(
                                        ConfirmScreen:new {
                                            message =
                                                self.confirm_message,
                                            confirm_label =
                                                self.action_label,
                                            on_confirm =
                                                self.on_confirm,
                                            on_success =
                                                function()
                                                    backstack.pop()

                                                    if self.on_success then
                                                        self.on_success()
                                                    end
                                                end,
                                        }
                                    )
                                end,
                        }
                    )

            self.action_row = action

            self.first_row = action.object
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

local function open_album_action(
    owner,
    album
)
    backstack.push(
        ActionScreen:new {
            title =
                album.name or
                "Downloaded album",
            action_label =
                "Remove album from this Tangara",
            confirm_message =
                "Keep the Jellyfin copy; remove only this Tangara album?",
            on_confirm = function()
                return
                    jellyfin_storage
                        .remove_album(album)
            end,
            on_success = function()
                owner:remove_item(album)
            end,
        }
    )
end

local function open_track_action(
    owner,
    track
)
    backstack.push(
        ActionScreen:new {
            title =
                track.title or
                "Downloaded track",
            action_label =
                "Remove track from this Tangara",
            confirm_message =
                "Keep the Jellyfin copy; remove only this Tangara track?",
            on_confirm = function()
                return
                    jellyfin_storage
                        .remove_track(track)
            end,
            on_success = function()
                owner:remove_item(track)
            end,
        }
    )
end

AlbumsScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Downloaded albums"
            )
            local snapshot =
                load_snapshot(self)

            if not snapshot then
                return
            end

            self.items = snapshot.albums
            self.selection_mode = false
            self.selected = {}

            if #self.items == 0 then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            "No downloaded albums"
                        )

                self.first_row = row.object
                return
            end

            local function item_id(item)
                item =
                    item._storage_item or
                    item
                return tostring(item.key)
            end

            local function selected_items()
                local selected = {}

                for _, item in ipairs(
                    self.items
                ) do
                    if self.selected[
                        item_id(item)
                    ] then
                        selected[#selected + 1] =
                            item
                    end
                end

                return selected
            end

            local function display_items(items)
                if not self.selection_mode then
                    return items
                end

                local displayed = {}

                for _, item in ipairs(items) do
                    local copy = {}

                    for key, value in pairs(item) do
                        copy[key] = value
                    end

                    copy.name =
                        (
                            self.selected[
                                item_id(item)
                            ] and
                            "[x] " or "[ ] "
                        ) ..
                        tostring(item.name or "")
                    copy._storage_item = item
                    displayed[#displayed + 1] =
                        copy
                end

                return displayed
            end

            local function refresh_select_row()
                local count = #selected_items()

                self.select_row:set_label(
                    self.selection_mode and
                        (
                            "Delete selected (" ..
                            tostring(count) ..
                            ")"
                        ) or
                        "Select multiple"
                )
            end

            local function toggle(album)
                local original =
                    album._storage_item or
                    album
                local id = item_id(original)

                self.selected[id] =
                    not self.selected[id] or
                    nil
                refresh_select_row()
                self.virtual_album_list
                    :set_items(
                        display_items(
                            self.sorted_items
                        )
                    )
            end

            local function activate(album)
                if self.selection_mode then
                    toggle(album)
                else
                    open_album_action(
                        self,
                        album._storage_item or
                            album
                    )
                end
            end

            local function create_list(items)
                self.virtual_album_list =
                    jellyfin_virtual_list
                        .create(
                            self,
                            items,
                            {
                                item_label = "album",
                                item_plural = "albums",
                                create_row =
                                    function(
                                        owner,
                                        album
                                    )
                                        local model =
                                            jellyfin_list_ui
                                                .add_album_row(
                                                    owner,
                                                    album,
                                                    artwork_path(
                                                        album
                                                    ),
                                                    function()
                                                        activate(album)
                                                    end
                                                )

                                        model.on_long_press =
                                            model.on_click
                                        return model
                                    end,
                                update_row =
                                    function(
                                        model,
                                        album,
                                        handlers
                                    )
                                        model:update(
                                            album,
                                            artwork_path(
                                                album
                                            ),
                                            handlers.on_click
                                        )
                                        model.on_long_press =
                                            handlers
                                                .on_long_press
                                    end,
                                on_click =
                                    activate,
                                on_long_press =
                                    activate,
                            }
                        )

                self.first_row =
                    self.media_rows[1].object
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        "storage:albums",
                        self.items,
                        "albums"
                    )

                self.sorted_items = sorted

                if self.virtual_album_list then
                    self.virtual_album_list
                        :set_items(
                            display_items(sorted),
                            {
                                reset_selection =
                                    true,
                            }
                        )
                else
                    create_list(
                        display_items(sorted)
                    )
                end
            end

            add_sort_control(
                self,
                "storage:albums",
                "albums",
                function()
                    self.apply_sort()
                end
            )

            self.select_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "",
                        {
                            leading = true,
                            selection_id =
                                "storage:albums:select",
                            on_click =
                                function()
                                    if not self.selection_mode then
                                        self.selection_mode =
                                            true
                                        self.selected = {}
                                        refresh_select_row()
                                        self.apply_sort()
                                        return
                                    end

                                    local selected =
                                        selected_items()

                                    if #selected == 0 then
                                        return
                                    end

                                    backstack.push(
                                        ConfirmScreen:new {
                                            message =
                                                "Remove " ..
                                                tostring(
                                                    #selected
                                                ) ..
                                                " selected albums from this Tangara?",
                                            confirm_label =
                                                "Delete selected",
                                            on_confirm =
                                                function()
                                                    return
                                                        jellyfin_storage
                                                            .remove_albums(
                                                                selected
                                                            )
                                                end,
                                            on_success =
                                                function()
                                                    self.selection_mode =
                                                        false
                                                    self.selected = {}
                                                    self:remove_items(
                                                        selected
                                                    )
                                                end,
                                        }
                                    )
                                end,
                        }
                    )
            self.select_row
                .virtual_list_boundary = true
            refresh_select_row()

            local normal_go_back =
                self.go_back

            self.go_back = function()
                if self.selection_mode then
                    self.selection_mode = false
                    self.selected = {}
                    refresh_select_row()
                    self.apply_sort()
                    return
                end

                normal_go_back()
            end

            function self:remove_items(items)
                local removing = {}

                for _, item in ipairs(items) do
                    removing[item.key] = true
                end

                local kept = {}

                for _, candidate in ipairs(
                    self.items
                ) do
                    if not removing[
                        candidate.key
                    ] then
                        table.insert(
                            kept,
                            candidate
                        )
                    end
                end

                self.items = kept
                self.selection_mode = false
                self.selected = {}
                refresh_select_row()

                if #kept > 0 then
                    self.apply_sort()
                else
                    backstack.pop()
                end
            end

            function self:remove_item(item)
                self:remove_items {item}
            end

            self.apply_sort()
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

TracksScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Downloaded tracks"
            )
            local snapshot =
                load_snapshot(self)

            if not snapshot then
                return
            end

            self.items = snapshot.tracks
            self.selection_mode = false
            self.selected = {}

            if #self.items == 0 then
                local row =
                    jellyfin_list_ui
                        .add_message(
                            self,
                            "No downloaded tracks"
                        )

                self.first_row = row.object
                return
            end

            local function item_id(item)
                item =
                    item._storage_item or
                    item
                return tostring(
                    item.id or
                    item.local_path
                )
            end

            local function selected_items()
                local selected = {}

                for _, item in ipairs(
                    self.items
                ) do
                    if self.selected[
                        item_id(item)
                    ] then
                        selected[#selected + 1] =
                            item
                    end
                end

                return selected
            end

            local function display_items(items)
                if not self.selection_mode then
                    return items
                end

                local displayed = {}

                for _, item in ipairs(items) do
                    local copy = {}

                    for key, value in pairs(item) do
                        copy[key] = value
                    end

                    copy.title =
                        (
                            self.selected[
                                item_id(item)
                            ] and
                            "[x] " or "[ ] "
                        ) ..
                        tostring(
                            item.title or ""
                        )
                    copy._storage_item = item
                    displayed[#displayed + 1] =
                        copy
                end

                return displayed
            end

            local function refresh_select_row()
                local count = #selected_items()

                self.select_row:set_label(
                    self.selection_mode and
                        (
                            "Delete selected (" ..
                            tostring(count) ..
                            ")"
                        ) or
                        "Select multiple"
                )
            end

            local function activate(track)
                if self.selection_mode then
                    local original =
                        track._storage_item or
                        track
                    local id =
                        item_id(original)

                    self.selected[id] =
                        not self.selected[id] or
                        nil
                    refresh_select_row()
                    self.virtual_track_list
                        :set_items(
                            display_items(
                                self.sorted_items
                            )
                        )
                else
                    open_track_action(
                        self,
                        track._storage_item or
                            track
                    )
                end
            end

            local function create_list(items)
                jellyfin_virtual_track_list.create(
                    self,
                    items,
                    {
                        artwork = artwork_path,
                        detail = function(track)
                            return track.artist
                        end,
                        on_click = activate,
                        on_long_press =
                            activate,
                    }
                )

                self.first_row =
                    self.media_rows[1].object
            end

            function self.apply_sort()
                local sorted =
                    jellyfin_sort.sort(
                        "storage:tracks",
                        self.items,
                        "tracks"
                    )

                self.sorted_items = sorted

                if self.virtual_track_list then
                    self.virtual_track_list
                        :set_items(
                            display_items(sorted),
                            {
                                reset_selection =
                                    true,
                            }
                        )
                else
                    create_list(
                        display_items(sorted)
                    )
                end
            end

            add_sort_control(
                self,
                "storage:tracks",
                "tracks",
                function()
                    self.apply_sort()
                end
            )

            self.select_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "",
                        {
                            leading = true,
                            selection_id =
                                "storage:tracks:select",
                            on_click =
                                function()
                                    if not self.selection_mode then
                                        self.selection_mode =
                                            true
                                        self.selected = {}
                                        refresh_select_row()
                                        self.apply_sort()
                                        return
                                    end

                                    local selected =
                                        selected_items()

                                    if #selected == 0 then
                                        return
                                    end

                                    backstack.push(
                                        ConfirmScreen:new {
                                            message =
                                                "Remove " ..
                                                tostring(
                                                    #selected
                                                ) ..
                                                " selected tracks from this Tangara?",
                                            confirm_label =
                                                "Delete selected",
                                            on_confirm =
                                                function()
                                                    return
                                                        jellyfin_storage
                                                            .remove_tracks(
                                                                selected
                                                            )
                                                end,
                                            on_success =
                                                function()
                                                    self.selection_mode =
                                                        false
                                                    self.selected = {}
                                                    self:remove_items(
                                                        selected
                                                    )
                                                end,
                                        }
                                    )
                                end,
                        }
                    )
            self.select_row
                .virtual_list_boundary = true
            refresh_select_row()

            local normal_go_back =
                self.go_back

            self.go_back = function()
                if self.selection_mode then
                    self.selection_mode = false
                    self.selected = {}
                    refresh_select_row()
                    self.apply_sort()
                    return
                end

                normal_go_back()
            end

            self.apply_sort()

            function self:remove_items(items)
                local removing = {}

                for _, item in ipairs(items) do
                    removing[item.id] = true
                end

                local kept = {}

                for _, candidate in ipairs(
                    self.items
                ) do
                    if not removing[
                        candidate.id
                    ] then
                        table.insert(
                            kept,
                            candidate
                        )
                    end
                end

                self.items = kept
                self.selection_mode = false
                self.selected = {}
                refresh_select_row()

                if #kept > 0 then
                    self.apply_sort()
                else
                    backstack.pop()
                end
            end

            function self:remove_item(item)
                self:remove_items {item}
            end
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

local function create_usage_bar(
    self,
    snapshot
)
    local palette =
        jellyfin_theme.current()
    local legend =
        self.root:Label {
            x = 4,
            y = 78,
            w = 152,
            h = 10,
            text =
                "Music  Art  Other  Free",
            text_align = 2,
            text_color =
                palette.muted_text,
            text_font = font.fusion_10,
        }

    legend:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local bar =
        self.root:Object {
            x = 4,
            y = 90,
            w = 152,
            h = 8,
            pad_all = 0,
            border_width = 1,
            border_color =
                palette.divider,
            radius = 2,
            bg_color = palette.surface,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    bar:clear_flag(lvgl.FLAG.SCROLLABLE)
    bar:clear_flag(lvgl.FLAG.CLICKABLE)

    local total =
        math.max(
            1,
            snapshot.total_bytes
        )
    local categories = {
        {
            name = "music",
            bytes = snapshot.music_bytes,
            color = palette.accent,
        },
        {
            name = "artwork",
            bytes = snapshot.artwork_bytes,
            color = palette.accent_muted,
        },
        {
            name = "system",
            bytes = snapshot.system_bytes,
            color = palette.muted_text,
        },
        {
            name = "free",
            bytes = snapshot.available_bytes,
            color = palette.surface,
        },
    }
    local x = 0

    for index, category in ipairs(
        categories
    ) do
        local width

        if index == #categories then
            width = math.max(0, 150 - x)
        else
            width =
                math.max(
                    0,
                    math.floor(
                        150 *
                        category.bytes /
                        total
                    )
                )
        end

        category.width = width

        if width > 0 then
            local segment =
                bar:Object {
                    x = x,
                    y = 0,
                    w = width,
                    h = 6,
                    pad_all = 0,
                    border_width = 0,
                    radius = 0,
                    bg_color =
                        category.color,
                    bg_opa = 255,
                }

            segment:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            segment:clear_flag(
                lvgl.FLAG.CLICKABLE
            )
            category.object = segment
        end

        x = x + width
    end

    self.storage_bar = {
        object = bar,
        legend = legend,
        categories = categories,
    }

    self.capacity_used =
        self.root:Label {
            x = 4,
            y = 101,
            w = 152,
            h = 10,
            text =
                jellyfin_storage
                    .format_bytes(
                        snapshot.used_bytes
                    ) ..
                " used / " ..
                jellyfin_storage
                    .format_bytes(
                        snapshot.total_bytes
                    ) ..
                " total",
            text_align = 2,
            text_color =
                palette.foreground,
            text_font = font.fusion_10,
        }

    self.capacity_available =
        self.root:Label {
            x = 4,
            y = 113,
            w = 152,
            h = 10,
            text =
                jellyfin_storage
                    .format_bytes(
                        snapshot.available_bytes
                    ) ..
                " available",
            text_align = 2,
            text_color =
                palette.muted_text,
            text_font = font.fusion_10,
        }
end

StorageScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Storage"
            )

            self.list:set {
                y = 29,
                h = 48,
                pad_row = 0,
            }
            self.list:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )

            local snapshot =
                load_snapshot(self)

            if not snapshot then
                return
            end

            self.snapshot = snapshot

            local albums =
                jellyfin_list_ui
                    .add_action_row(
                    self,
                    "Downloaded albums",
                    {
                        height = 24,
                        y = 5,
                        selection_id =
                            "storage:albums",
                        on_click = function()
                            backstack.push(
                                AlbumsScreen:new()
                            )
                        end,
                    }
                )

            jellyfin_list_ui.add_action_row(
                self,
                "Downloaded tracks",
                {
                    height = 24,
                    y = 5,
                    selection_id =
                        "storage:tracks",
                    on_click = function()
                        backstack.push(
                            TracksScreen:new()
                        )
                    end,
                }
            )

            self.first_row = albums.object
            create_usage_bar(
                self,
                snapshot
            )
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

M.Root = StorageScreen
M.Albums = AlbumsScreen
M.Tracks = TracksScreen
M.Action = ActionScreen
M.Confirm = ConfirmScreen

return M
