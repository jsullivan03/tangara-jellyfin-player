local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local screen = require("screen")

local M = {}

local COLORS = jellyfin_list_ui.colors
local palette =
    require("jellyfin_theme").current()

local function remove_from_group(object)
    pcall(function()
        lvgl.group.remove_obj(object)
    end)
end

local function focus_object(object)
    if not object then
        return
    end

    pcall(function()
        lvgl.group.focus_obj(object)
    end)

    pcall(function()
        object:scroll_to_view_recursive(false)
    end)
end

local function build_tokens()
    local tokens = {}

    -- Letters appear once in the rotary sequence. The Caps control changes
    -- their rendered and inserted case instead of duplicating the alphabet.
    for code = string.byte("a"),
        string.byte("z") do
        table.insert(tokens, {
            value = string.char(code),
            kind = "letter",
        })
    end

    for code = string.byte("0"),
        string.byte("9") do
        table.insert(tokens, {
            value = string.char(code),
            kind = "character",
        })
    end

    for _, value in ipairs({
        "-", "_", "'", "&", ".", "(", ")",
        "!", "?",
    }) do
        table.insert(tokens, {
            value = value,
            kind = "character",
        })
    end

    return tokens
end

local TOKENS = build_tokens()

local function trim(value)
    return tostring(value or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function remove_last_character(value)
    if value == "" then
        return value
    end

    if utf8 and type(utf8.offset) ==
            "function" then
        local start = utf8.offset(value, -1)

        if start then
            return value:sub(1, start - 1)
        end
    end

    return value:sub(1, -2)
end

local function create_icon_piece(
    parent,
    x,
    y,
    width,
    height
)
    local piece =
        parent:Object {
            x = x,
            y = y,
            w = width,
            h = height,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_color = COLORS.secondary,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    piece:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    piece:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    remove_from_group(piece)

    return piece
end

local function create_icon(parent, runs)
    local pieces = {}

    for _, run in ipairs(runs) do
        table.insert(
            pieces,
            create_icon_piece(
                parent,
                run[1],
                run[2],
                run[3],
                run[4] or 1
            )
        )
    end

    return pieces
end

local function set_icon_color(pieces, color)
    for _, piece in ipairs(pieces or {}) do
        piece:set {
            bg_color = color,
        }
    end
end

local TextEntryScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                self.title or "Enter text"
            )

            self.value =
                tostring(self.initial_value or "")
            self.token_index = 1
            self.max_length =
                tonumber(self.max_length) or 64
            self.carousel_active = false
            self.caps_locked =
                self.initial_caps_locked == true

            local default_back = self.go_back

            local preview =
                self.list:Object {
                    w = lvgl.PCT(100),
                    h = 35,
                    pad_all = 0,
                    border_width = 0,
                    radius = 3,
                    bg_color = palette.surface,
                    bg_opa = 255,
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }

            preview:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            preview:clear_flag(
                lvgl.FLAG.CLICKABLE
            )
            remove_from_group(preview)

            self.preview_label =
                preview:Label {
                    x = 4,
                    y = 10,
                    w = 148,
                    h = 14,
                    text = self.value,
                    text_align = 1,
                    text_color = COLORS.primary,
                    text_font = font.fusion_10,
                }

            self.preview_label:clear_flag(
                lvgl.FLAG.CLICKABLE
            )

            self.token_row =
                jellyfin_list_ui.add_action_row(
                    self,
                    "",
                    {
                        height = 37,
                        selection_id =
                            "text-entry:carousel",
                        on_click = function()
                            if self.carousel_active then
                                self:append_token()
                            else
                                self:enter_carousel()
                            end
                        end,
                    }
                )

            local function add_carousel_label(
                x,
                width,
                color
            )
                local label =
                    self.token_row.object:Label {
                        x = x,
                        y = 11,
                        w = width,
                        h = 14,
                        text = "",
                        text_align = 2,
                        text_color = color,
                        text_font = font.fusion_10,
                    }

                label:clear_flag(
                    lvgl.FLAG.CLICKABLE
                )

                return label
            end

            -- Five fixed slots make the current character unambiguously
            -- centered while exposing two neighboring choices on each side.
            self.previous_two_token_label =
                add_carousel_label(
                    18,
                    20,
                    palette.divider
                )
            self.previous_token_label =
                add_carousel_label(
                    43,
                    20,
                    palette.muted_text
                )
            self.current_token_label =
                add_carousel_label(
                    66,
                    24,
                    COLORS.primary
                )
            self.next_token_label =
                add_carousel_label(
                    93,
                    20,
                    palette.muted_text
                )
            self.next_two_token_label =
                add_carousel_label(
                    118,
                    20,
                    palette.divider
                )

            local action_bar =
                self.list:Object {
                    w = lvgl.PCT(100),
                    h = 25,
                    pad_all = 0,
                    border_width = 0,
                    radius = 0,
                    bg_opa = 0,
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }

            action_bar:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            action_bar:clear_flag(
                lvgl.FLAG.CLICKABLE
            )
            remove_from_group(action_bar)

            local function add_action_button(
                x,
                selection_id,
                runs,
                callback
            )
                local button =
                    action_bar:Button {
                        x = x,
                        y = 1,
                        w = 26,
                        h = 23,
                        pad_all = 0,
                        border_width = 0,
                        outline_width = 0,
                        shadow_width = 0,
                        radius = 4,
                        bg_color = COLORS.selected,
                        bg_opa = 0,
                    }

                local pieces =
                    create_icon(button, runs)

                local model = {
                    object = button,
                    selection_id = selection_id,
                    icon_pieces = pieces,
                    on_click = callback,
                    owner = self,
                }

                button:onevent(
                    lvgl.EVENT.FOCUSED,
                    function()
                        button:set {
                            bg_color = COLORS.selected,
                            bg_opa = 255,
                        }
                        set_icon_color(
                            pieces,
                            COLORS.primary
                        )
                    end
                )

                button:onevent(
                    lvgl.EVENT.DEFOCUSED,
                    function()
                        button:set {
                            bg_opa = 0,
                        }
                        set_icon_color(
                            pieces,
                            COLORS.secondary
                        )
                    end
                )

                button:onevent(
                    lvgl.EVENT.PRESSED,
                    function()
                        focus_object(button)
                    end
                )

                button:onClicked(callback)
                remove_from_group(button)

                table.insert(self.rows, model)

                return model
            end

            local function add_text_action_button(
                x,
                selection_id,
                text,
                callback
            )
                local button =
                    action_bar:Button {
                        x = x,
                        y = 1,
                        w = 26,
                        h = 23,
                        pad_all = 0,
                        border_width = 0,
                        outline_width = 0,
                        shadow_width = 0,
                        radius = 4,
                        bg_color = COLORS.selected,
                        bg_opa = 0,
                    }

                local label =
                    button:Label {
                        x = 0,
                        y = 5,
                        w = 26,
                        h = 14,
                        text = text,
                        text_align = 2,
                        text_color = COLORS.secondary,
                        text_font = font.fusion_10,
                    }

                label:clear_flag(
                    lvgl.FLAG.CLICKABLE
                )
                remove_from_group(label)

                local model = {
                    object = button,
                    selection_id = selection_id,
                    text_label = label,
                    on_click = callback,
                    owner = self,
                }

                button:onevent(
                    lvgl.EVENT.FOCUSED,
                    function()
                        button:set {
                            bg_color = COLORS.selected,
                            bg_opa = 255,
                        }
                        label:set {
                            text_color = COLORS.primary,
                        }
                    end
                )

                button:onevent(
                    lvgl.EVENT.DEFOCUSED,
                    function()
                        button:set {
                            bg_opa = 0,
                        }
                        label:set {
                            text_color = COLORS.secondary,
                        }
                    end
                )

                button:onevent(
                    lvgl.EVENT.PRESSED,
                    function()
                        focus_object(button)
                    end
                )

                button:onClicked(callback)
                remove_from_group(button)
                table.insert(self.rows, model)

                return model
            end

            self.caps_button =
                add_text_action_button(
                    11,
                    "text-entry:caps",
                    "A",
                    function()
                        self:toggle_caps()
                    end
                )

            self.space_button =
                add_action_button(
                    47,
                    "text-entry:space",
                    {
                        {6, 11, 14, 1},
                        {6, 8, 1, 4},
                        {19, 8, 1, 4},
                    },
                    function()
                        self:insert_space()
                    end
                )

            self.backspace_button =
                add_action_button(
                    83,
                    "text-entry:backspace",
                    {
                        {6, 11, 14, 1},
                        {6, 11, 1, 1},
                        {7, 10, 1, 1},
                        {8, 9, 1, 1},
                        {7, 12, 1, 1},
                        {8, 13, 1, 1},
                    },
                    function()
                        self:backspace()
                    end
                )

            self.confirm_button =
                add_action_button(
                    119,
                    "text-entry:confirm",
                    {
                        {7, 12, 1, 1},
                        {8, 13, 1, 1},
                        {9, 14, 1, 1},
                        {10, 15, 1, 1},
                        {11, 14, 1, 1},
                        {12, 13, 1, 1},
                        {13, 12, 1, 1},
                        {14, 11, 1, 1},
                        {15, 10, 1, 1},
                        {16, 9, 1, 1},
                        {17, 8, 1, 1},
                        {18, 7, 1, 1},
                    },
                    function()
                        self:submit()
                    end
                )

            self.first_row =
                self.token_row.object
            self.initial_focus_object =
                self.token_row.object
            self.preserve_leading_controls_on_open =
                true

            local function token_at(offset)
                local index =
                    (
                        self.token_index - 1 +
                        offset
                    ) % #TOKENS + 1

                return TOKENS[index]
            end

            local function token_text(token)
                if not token then
                    return ""
                end

                if token.kind == "letter" then
                    if self.caps_locked then
                        return token.value:upper()
                    end

                    return token.value:lower()
                end

                return token.value
            end

            function self:update_preview()
                local shown = self.value

                if shown == "" then
                    shown = "_"
                end

                self.preview_label:set {
                    text = shown,
                }
            end

            function self:update_token()
                self.previous_two_token_label:set {
                    text = token_text(token_at(-2)),
                }
                self.previous_token_label:set {
                    text = token_text(token_at(-1)),
                }
                self.current_token_label:set {
                    text = token_text(token_at(0)),
                }
                self.next_token_label:set {
                    text = token_text(token_at(1)),
                }
                self.next_two_token_label:set {
                    text = token_text(token_at(2)),
                }

                if self.caps_button and
                    self.caps_button.text_label then
                    self.caps_button.text_label:set {
                        text = self.caps_locked and
                            "A" or "a",
                    }
                end
            end

            function self:rotate(diff)
                diff = math.floor(
                    tonumber(diff) or 0
                )

                if diff == 0 then
                    return
                end

                self.token_index =
                    (
                        self.token_index - 1 +
                        diff
                    ) % #TOKENS + 1

                self:update_token()
            end

            self.encoder_callback =
                function(diff)
                    -- Match normal list navigation direction while the
                    -- carousel has captured the encoder.
                    self:rotate(-diff)
                end

            function self:enter_carousel()
                if self.carousel_active then
                    return true
                end

                self.carousel_active = true
                self.token_row.object:set {
                    border_width = 1,
                    border_color = COLORS.primary,
                }

                pcall(
                    controls.set_encoder_handler,
                    self.encoder_callback
                )

                return true
            end

            function self:leave_carousel()
                if not self.carousel_active then
                    return false
                end

                self.carousel_active = false
                pcall(
                    controls.set_encoder_handler,
                    nil
                )
                self.token_row.object:set {
                    border_width = 0,
                }
                focus_object(
                    self.token_row.object
                )

                return true
            end

            function self:set_token(label)
                label = tostring(label or "")
                local lowered = label:lower()

                for index, token in ipairs(
                    TOKENS
                ) do
                    if token.value == label or
                        (
                            token.kind == "letter" and
                            token.value == lowered
                        ) then
                        if token.kind == "letter" then
                            self.caps_locked =
                                label == label:upper()
                        end

                        self.token_index = index
                        self:update_token()
                        return true
                    end
                end

                return false
            end

            function self:append_token()
                local value =
                    token_text(
                        TOKENS[self.token_index]
                    )

                if value ~= "" and
                    #self.value + #value <=
                        self.max_length then
                    self.value =
                        self.value .. value
                    self:update_preview()
                end

                return true
            end

            function self:toggle_caps()
                self.caps_locked =
                    not self.caps_locked
                self:update_token()
                return true
            end

            -- Preserve the old public method name for tests and any callers.
            self.activate_token = self.append_token

            function self:insert_space()
                if #self.value < self.max_length then
                    self.value = self.value .. " "
                    self:update_preview()
                end

                return true
            end

            function self:backspace()
                self.value =
                    remove_last_character(
                        self.value
                    )
                self:update_preview()
                return true
            end

            function self:submit()
                local name = trim(self.value)

                if name == "" then
                    self.preview_label:set {
                        text = "Name required",
                    }
                    return false
                end

                if type(self.on_submit) ==
                        "function" then
                    local accepted, message =
                        self.on_submit(name)

                    if accepted == "handled" then
                        return true
                    end

                    if accepted == false then
                        self.preview_label:set {
                            text =
                                message or
                                "Unable to save",
                        }
                        return false
                    end
                end

                backstack.pop()
                return true
            end

            function self:text_entry_state()
                return {
                    value = self.value,
                    token = token_text(token_at(0)),
                    previous_token =
                        token_text(token_at(-1)),
                    previous_two_token =
                        token_text(token_at(-2)),
                    next_token =
                        token_text(token_at(1)),
                    next_two_token =
                        token_text(token_at(2)),
                    token_index = self.token_index,
                    token_count = #TOKENS,
                    caps_locked =
                        self.caps_locked == true,
                    carousel = true,
                    carousel_active =
                        self.carousel_active == true,
                    carousel_positions = {
                        previous_two = 28,
                        previous = 53,
                        current = 78,
                        next = 103,
                        next_two = 128,
                    },
                    actions = {
                        "caps",
                        "space",
                        "backspace",
                        "confirm",
                    },
                    action_icons = {
                        space = "bounded_line",
                        backspace_max_thickness = 1,
                        confirm_max_thickness = 1,
                    },
                    hint_visible = false,
                    cancel_action_visible = false,
                }
            end

            self.go_back = function()
                if self.carousel_active then
                    self:leave_carousel()
                    return
                end

                default_back()
            end

            self:update_preview()
            self:update_token()
        end,

        on_show = function(self)
            jellyfin_list_ui.install_controls(
                self
            )

            if self.initial_carousel_active then
                self:enter_carousel()
            else
                pcall(
                    controls.set_encoder_handler,
                    nil
                )
            end
        end,

        on_hide = function(self)
            self.carousel_active = false
            pcall(
                controls.set_encoder_handler,
                nil
            )
            jellyfin_list_ui.restore_controls(
                self
            )
        end,
    }

function M.new(options)
    options = options or {}

    return TextEntryScreen:new(options)
end

M.Screen = TextEntryScreen
M.tokens = TOKENS

return M
