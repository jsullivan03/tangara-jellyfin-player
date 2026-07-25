local lvgl = require("lvgl")
local styles = require("styles")
local sync_link = require("sync_link")
local widgets = require("widgets")

local active_screen = nil
local poll_timer = nil

local function set_hidden(object, hidden)
    if hidden then
        object:add_flag(lvgl.FLAG.HIDDEN)
    else
        object:clear_flag(lvgl.FLAG.HIDDEN)
    end
end

local function update_ui(self, state)
    state = state or sync_link.state()

    local account_name = "Not linked"
    local status_text = "Ready to link a Jellyfin account"
    local action_text = "Link account"
    local show_code = false
    local action_force = false

    if state.phase == "starting" then
        status_text = "Contacting Jellyfin..."
        action_text = "Working..."
    elseif state.phase == "waiting" or
        state.phase == "polling" then
        status_text =
            "Enter this code in Jellyfin Quick Connect"
        action_text = "Waiting..."
        show_code =
            type(state.code) == "string" and
            state.code ~= ""
    elseif state.phase == "linked" then
        if type(state.user) == "table" and
            type(state.user.name) == "string" and
            state.user.name ~= "" then
            account_name = state.user.name
        else
            account_name = "Linked"
        end

        status_text = "Account linked successfully"
        action_text = "Relink account"
        action_force = true
    elseif state.phase == "error" then
        status_text =
            state.error or
            "Jellyfin account linking failed"
        action_text = "Try again"
    end

    self.account_value:set {
        text = account_name,
    }

    self.status_label:set {
        text = status_text,
    }

    self.code_label:set {
        text = state.code or "",
    }

    self.action_label:set {
        text = action_text,
    }

    self.action_force = action_force

    set_hidden(
        self.code_title,
        not show_code
    )

    set_hidden(
        self.code_label,
        not show_code
    )

    if state.active then
        self.action_button:add_state(
            lvgl.STATE.DISABLED
        )
    else
        self.action_button:clear_state(
            lvgl.STATE.DISABLED
        )
    end
end

local function begin_link(self, force)
    local state = sync_link.state()

    if state.active then
        update_ui(self, state)
        return
    end

    sync_link.reset()

    local started, start_error =
        sync_link.start(force == true)

    if started then
        self.retry_force = nil
        update_ui(self, sync_link.state())
        return
    end

    if start_error ==
        "HTTP request already in progress" then
        self.retry_force = force == true

        self.status_label:set {
            text = "Waiting for the sync connection...",
        }

        return
    end

    self.retry_force = nil

    self.status_label:set {
        text =
            start_error or
            "Unable to start Jellyfin linking",
    }

    self.action_label:set {
        text = "Try again",
    }
end

local function poll_active_screen()
    local self = active_screen

    if not self then
        return
    end

    if self.retry_force ~= nil then
        local force = self.retry_force
        begin_link(self, force)
        return
    end

    local event, poll_error =
        sync_link.poll()

    if poll_error then
        self.status_label:set {
            text = poll_error,
        }
    end

    update_ui(
        self,
        event or sync_link.state()
    )
end

local function ensure_timer()
    if poll_timer then
        return
    end

    poll_timer = lvgl.Timer {
        period = 1000,
        cb = function()
            poll_active_screen()
        end,
    }
end

local JellyfinSettings =
    widgets.MenuScreen:new {
        show_back = true,
        title = "Jellyfin",

        create_ui = function(self)
            widgets.MenuScreen.create_ui(self)

            self.content = self.root:Object {
                flex = {
                    flex_direction = "column",
                    flex_wrap = "nowrap",
                    justify_content = "flex-start",
                    align_items = "flex-start",
                    align_content = "flex-start",
                },
                w = lvgl.PCT(100),
                flex_grow = 1,
                pad_left = 4,
                pad_right = 4,
                pad_row = 4,
            }

            local account =
                widgets.Row(
                    self.content,
                    "Account",
                    "Checking..."
                )

            self.account_value = account.right

            self.status_label =
                self.content:Label {
                    w = lvgl.PCT(100),
                    text = "",
                    long_mode =
                        lvgl.LABEL.LONG_WRAP,
                }

            self.code_title =
                self.content:Label {
                    w = lvgl.PCT(100),
                    text = "Quick Connect code",
                    text_align = 2,
                }

            self.code_label =
                self.content:Label {
                    w = lvgl.PCT(100),
                    text = "",
                    text_align = 2,
                    text_font = font.fusion_12,
                    pad_top = 2,
                    pad_bottom = 2,
                }

            local action_container =
                self.content:Object {
                    w = lvgl.PCT(100),
                    h = lvgl.SIZE_CONTENT,
                    flex = {
                        flex_direction = "row",
                        justify_content = "center",
                        align_items = "center",
                        align_content = "center",
                    },
                    pad_top = 4,
                }

            action_container:add_style(
                styles.list_item
            )

            self.action_button =
                action_container:Button {}

            self.action_label =
                self.action_button:Label {
                    text = "Link account",
                }

            self.action_button:onClicked(
                function()
                    begin_link(
                        self,
                        self.action_force == true
                    )
                end
            )

            self.action_button:focus()
            self.retry_force = nil
            self.action_force = false

            active_screen = self
            ensure_timer()

            local state = sync_link.state()
            update_ui(self, state)

            if state.phase == "idle" or
                state.phase == "error" then
                begin_link(self, false)
            end
        end,

        on_show = function(self)
            active_screen = self
            ensure_timer()
            update_ui(self, sync_link.state())
        end,

        on_hide = function(self)
            if active_screen == self then
                active_screen = nil
            end

            self.retry_force = nil
        end,
    }

return JellyfinSettings
