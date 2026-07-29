local lvgl = require("lvgl")
local backstack = require("backstack")
local jellyfin_navigation =
    require("jellyfin_navigation")
local jellyfin_text_entry =
    require("jellyfin_text_entry")
local sync_operation_queue =
    require("sync_operation_queue")

local M = {}

local SCREEN_WIDTH = 160
local SCREEN_HEIGHT = 128
local BUTTON_HEIGHT = 15

local function remove_from_group(object)
    if not object then
        return
    end

    pcall(function()
        lvgl.group.remove_obj(object)
    end)
end

local function add_to_group(group, object)
    if not group or not object then
        return
    end

    local ok = pcall(function()
        lvgl.group.add_obj(group, object)
    end)

    if not ok then
        pcall(function()
            group:add_obj(object)
        end)
    end
end

local function focus_object(object)
    if not object then
        return
    end

    if not pcall(function()
        lvgl.group.focus_obj(object)
    end) then
        pcall(function()
            object:focus()
        end)
    end
end

local function add_button(
    list,
    label,
    callback,
    on_focus
)
    local button = list:add_btn(nil, label)

    button:set {
        w = lvgl.PCT(100),
        h = BUTTON_HEIGHT,
        pad_left = 7,
        pad_right = 3,
        pad_top = 0,
        pad_bottom = 0,
        border_width = 0,
        outline_width = 0,
        shadow_width = 0,
        radius = 0,
        bg_opa = 0,
        text_color = "#FFFFFF",
        text_font = font.fusion_10,
    }

    button:onevent(
        lvgl.EVENT.FOCUSED,
        function()
            if on_focus then
                on_focus(button)
            end
        end
    )
    button:onClicked(callback)
    remove_from_group(button)

    return button
end

local function controller_for(owner)
    local controller = {
        owner = owner,
        is_open = false,
        page = "main",
        buttons = {},
        playlist = nil,
        highlighted = nil,
        owner_scroll_y = nil,
    }

    local original_go_back = owner.go_back

    local function owner_rows()
        return owner.rows or {}
    end

    local function read_owner_scroll()
        local anchor =
            owner_rows()[1]

        if not owner.list or
            not anchor or
            not anchor.object then
            return nil
        end

        local ok, value = pcall(function()
            local list_coordinates =
                owner.list:get_coords()
            local anchor_coordinates =
                anchor.object:get_coords()

            return
                list_coordinates.y1 -
                anchor_coordinates.y1
        end)

        if not ok then
            return nil
        end

        return tonumber(value)
    end

    local function restore_owner_scroll(value)
        value = tonumber(value)

        if not value or not owner.list then
            return
        end

        pcall(function()
            owner.list:scroll_to {
                x = 0,
                y = value,
                anim = false,
            }
        end)
    end

    local function restore_owner_scroll_soon(value)
        restore_owner_scroll(value)

        pcall(function()
            lvgl.Timer {
                period = 1,
                repeat_count = 1,
                cb = function()
                    if owner.ui_active then
                        restore_owner_scroll(value)
                    end
                end,
            }
        end)
    end

    local function refresh_highlight(focused)
        controller.highlighted = focused

        for _, button in ipairs(
            controller.buttons
        ) do
            pcall(function()
                button:set {
                    bg_opa = 0,
                    text_color =
                        button == focused and
                        "#72AFFF" or
                        "#FFFFFF",
                }
            end)
        end
    end

    local function remove_buttons()
        for _, button in ipairs(
            controller.buttons
        ) do
            remove_from_group(button)
        end
    end

    local function remove_owner_rows()
        for _, model in ipairs(owner_rows()) do
            remove_from_group(
                model and model.object
            )
        end
    end

    local function add_owner_rows(group)
        if not owner.ui_active then
            return
        end

        for _, model in ipairs(owner_rows()) do
            add_to_group(
                group,
                model and model.object
            )
        end
    end

    local function prepare_focus()
        local group =
            controller.group or
            owner.focus_group or
            lvgl.group.get_default()

        if not group then
            return nil
        end

        if not controller.group then
            controller.group = group

            local ok, wrap = pcall(function()
                return group:get_wrap()
            end)
            controller.previous_wrap =
                ok and wrap or true

            local focus_ok, focused =
                pcall(function()
                    return group:get_focused()
                end)

            if focus_ok then
                controller.previous_focus = focused
            end
        end

        pcall(function()
            group:set_wrap(false)
        end)
        remove_owner_rows()
        remove_buttons()

        return group
    end

    local function activate_buttons(initial)
        local group = prepare_focus()

        if not group then
            return
        end

        for _, button in ipairs(
            controller.buttons
        ) do
            add_to_group(group, button)
        end

        focus_object(
            initial or controller.buttons[1]
        )
        restore_owner_scroll_soon(
            controller.owner_scroll_y
        )
    end

    local function ensure_ui()
        if controller.overlay then
            return
        end

        local overlay =
            owner.root:Object {
                x = 0,
                y = 0,
                w = SCREEN_WIDTH,
                h = SCREEN_HEIGHT,
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_opa = 0,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        overlay:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )
        overlay:add_flag(
            lvgl.FLAG.HIDDEN
        )

        local dimmer =
            overlay:Button {
                x = 0,
                y = 0,
                w = SCREEN_WIDTH,
                h = SCREEN_HEIGHT,
                pad_all = 0,
                border_width = 0,
                outline_width = 0,
                shadow_width = 0,
                radius = 0,
                bg_color = "#000000",
                bg_opa = 95,
            }

        remove_from_group(dimmer)

        local sheet =
            overlay:Object {
                x = 0,
                y = 94,
                w = SCREEN_WIDTH,
                h = 34,
                pad_all = 0,
                border_width = 1,
                border_color = "#555862",
                radius = 8,
                bg_color = "#11131A",
                bg_opa = 248,
                scrollbar_mode =
                    lvgl.SCROLLBAR_MODE.OFF,
            }

        sheet:clear_flag(
            lvgl.FLAG.SCROLLABLE
        )

        local list =
            lvgl.List(
                sheet,
                {
                    x = 2,
                    y = 2,
                    w = 156,
                    h = 30,
                }
            )

        list:set {
            pad_all = 0,
            pad_row = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

        controller.overlay = overlay
        controller.dimmer = dimmer
        controller.sheet = sheet
        controller.list = list

        dimmer:onClicked(function()
            controller:close()
        end)
    end

    local function rebuild(buttons)
        ensure_ui()
        remove_buttons()
        controller.list:clean()
        controller.buttons = {}
        controller.actions = buttons

        for _, definition in ipairs(buttons) do
            table.insert(
                controller.buttons,
                add_button(
                    controller.list,
                    definition.label,
                    definition.activate,
                    refresh_highlight
                )
            )
        end

        activate_buttons(
            controller.buttons[1]
        )
    end

    local function reload_owner_soon()
        if type(owner.request_playlist_rebuild) ~=
                "function" then
            return
        end

        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = function()
                owner:request_playlist_rebuild()
            end,
        }
    end

    function controller:close()
        if not self.is_open then
            return
        end

        local saved_scroll =
            self.owner_scroll_y

        remove_buttons()
        self.overlay:add_flag(
            lvgl.FLAG.HIDDEN
        )

        local group =
            self.group or
            owner.focus_group or
            lvgl.group.get_default()

        add_owner_rows(group)

        if group and
            self.previous_wrap ~= nil then
            pcall(function()
                group:set_wrap(
                    self.previous_wrap ~= false
                )
            end)
        end

        if owner.ui_active then
            focus_object(
                self.previous_focus or
                owner.first_row
            )
        end

        restore_owner_scroll_soon(
            saved_scroll
        )

        self.group = nil
        self.previous_wrap = nil
        self.previous_focus = nil
        self.owner_scroll_y = nil
        self.is_open = false
        self.page = "main"
        self.highlighted = nil

        jellyfin_navigation.set_back(
            owner.go_back
        )
    end

    local function show_main()
        controller.page = "main"

        rebuild {
            {
                id = "rename",
                label = "Rename playlist",
                activate = function()
                    local playlist =
                        controller.playlist
                    local playlist_id =
                        playlist.local_id or
                        playlist.id

                    controller:close()

                    backstack.push(
                        jellyfin_text_entry.new {
                            title = "Rename playlist",
                            initial_value =
                                playlist.name or "",
                            on_submit =
                                function(name)
                                    local operation,
                                        operation_error =
                                        sync_operation_queue
                                            .enqueue_rename_playlist(
                                                playlist_id,
                                                name
                                            )

                                    if not operation then
                                        return false,
                                            operation_error
                                    end

                                    owner.needs_playlist_rebuild =
                                        true
                                    return true
                                end,
                        }
                    )
                end,
            },
            {
                id = "delete",
                label = "Delete playlist",
                activate = function()
                    controller.page = "confirm"

                    rebuild {
                        {
                            id = "cancel_delete",
                            label = "Cancel",
                            activate = show_main,
                        },
                        {
                            id = "confirm_delete",
                            label = "Confirm delete",
                            activate = function()
                                local playlist =
                                    controller.playlist
                                local playlist_id =
                                    playlist.local_id or
                                    playlist.id

                                local operation,
                                    operation_error =
                                    sync_operation_queue
                                        .enqueue_delete_playlist(
                                            playlist_id
                                        )

                                if not operation then
                                    controller.buttons[2]
                                        :set {
                                            text =
                                                operation_error or
                                                "Unable to delete",
                                        }
                                    return
                                end

                                owner.needs_playlist_rebuild =
                                    true
                                controller:close()
                                reload_owner_soon()
                            end,
                        },
                    }
                end,
            },
        }
    end

    function controller:open(playlist)
        if self.is_open or
            type(playlist) ~= "table" then
            return false
        end

        self.owner_scroll_y =
            read_owner_scroll()
        ensure_ui()
        self.playlist = playlist
        self.is_open = true
        self.overlay:clear_flag(
            lvgl.FLAG.HIDDEN
        )

        if owner.virtual_list_controller then
            owner.virtual_list_controller
                :suspend_continuous_input()
        end

        owner.go_back = function()
            controller:close()
        end
        jellyfin_navigation.set_back(
            owner.go_back
        )

        show_main()
        return true
    end

    function controller:activate(action)
        local definition = nil

        if type(action) == "number" then
            definition =
                self.actions and
                self.actions[action]
        else
            for _, candidate in ipairs(
                self.actions or {}
            ) do
                if candidate.id == action or
                    candidate.label == action then
                    definition = candidate
                    break
                end
            end
        end

        if definition and
            type(definition.activate) ==
                "function" then
            definition.activate()
            return true
        end

        return false
    end

    function controller:state()
        local labels = {}

        -- LVGL button wrappers do not consistently expose their label text as
        -- button.text in the simulator or firmware bindings. The action
        -- definitions are the authoritative source for the visible labels.
        for _, action in ipairs(
            self.actions or {}
        ) do
            table.insert(
                labels,
                action.label or ""
            )
        end

        return {
            open = self.is_open,
            page = self.page,
            button_count = #self.buttons,
            labels = labels,
            playlist_id =
                self.playlist and
                (
                    self.playlist.local_id or
                    self.playlist.id
                ) or nil,
        }
    end

    -- Restore the owner's original back callback after a close.
    local close = controller.close
    controller.close = function(self)
        close(self)
        owner.go_back = original_go_back
        jellyfin_navigation.set_back(
            owner.go_back
        )
    end

    return controller
end

function M.attach(owner)
    if owner.playlist_action_sheet then
        return owner.playlist_action_sheet
    end

    owner.playlist_action_sheet =
        controller_for(owner)

    return owner.playlist_action_sheet
end

return M
