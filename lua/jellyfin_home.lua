local backstack = require("backstack")
local lvgl = require("lvgl")
local jellyfin_list_ui =
    require("jellyfin_list_ui")
local jellyfin_theme =
    require("jellyfin_theme")
local screen = require("screen")

local M = {}

local HomeScreen
local SyncScreen
local SettingsScreen

local function create_shell(
    self,
    title,
    message
)
    jellyfin_list_ui.create_root(
        self,
        title
    )

    local row =
        jellyfin_list_ui.add_message(
            self,
            message
        )

    self.first_row = row.object
end

SyncScreen =
    screen:new {
        create_ui = function(self)
            create_shell(
                self,
                "Sync",
                "Server synchronization"
            )
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

SettingsScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Settings"
            )

            local modes =
                jellyfin_theme.modes()
            local accents =
                jellyfin_theme.accents()

            local function rebuild(
                selection_id
            )
                backstack.reset(
                    HomeScreen:new()
                )
                backstack.push(
                    SettingsScreen:new {
                        initial_selection_id =
                            selection_id,
                    }
                )
            end

            local function next_value(
                values,
                current
            )
                for index, value in ipairs(
                    values
                ) do
                    if value == current then
                        return values[
                            index % #values + 1
                        ]
                    end
                end

                return values[1]
            end

            local mode_row
            mode_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "Mode",
                        {
                            width = 115,
                            selection_id =
                                "settings:mode",
                            on_click =
                                function()
                                    local value =
                                        next_value(
                                            modes,
                                            jellyfin_theme
                                                .mode()
                                        )

                                    jellyfin_theme
                                        .set_mode(value)
                                    rebuild(
                                        "settings:mode"
                                    )
                                end,
                        }
                    )

            mode_row.swatch =
                mode_row.object:Object {
                    x = 126,
                    y = 3,
                    w = 20,
                    h = 18,
                    pad_all = 0,
                    border_width = 1,
                    border_color =
                        jellyfin_theme.color(
                            "divider"
                        ),
                    radius = 3,
                    bg_color =
                        jellyfin_theme.color(
                            "background"
                        ),
                    bg_opa = 255,
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }

            mode_row.swatch:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            mode_row.swatch:clear_flag(
                lvgl.FLAG.CLICKABLE
            )

            local accent_row
            accent_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "Accent",
                        {
                            width = 115,
                            selection_id =
                                "settings:accent",
                            on_click =
                                function()
                                    local value =
                                        next_value(
                                            accents,
                                            jellyfin_theme
                                                .accent()
                                        )

                                    jellyfin_theme
                                        .set_accent(value)
                                    rebuild(
                                        "settings:accent"
                                    )
                                end,
                        }
                    )

            accent_row.swatch =
                accent_row.object:Object {
                    x = 126,
                    y = 3,
                    w = 20,
                    h = 18,
                    pad_all = 0,
                    border_width = 1,
                    border_color =
                        jellyfin_theme.color(
                            "divider"
                        ),
                    radius = 3,
                    bg_color =
                        jellyfin_theme.color(
                            "accent"
                        ),
                    bg_opa = 255,
                    scrollbar_mode =
                        lvgl.SCROLLBAR_MODE.OFF,
                }

            accent_row.swatch:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )
            accent_row.swatch:clear_flag(
                lvgl.FLAG.CLICKABLE
            )

            self.mode_row = mode_row
            self.accent_row = accent_row
            self.first_row =
                self.initial_selection_id ==
                    "settings:accent" and
                accent_row.object or
                mode_row.object
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

HomeScreen =
    screen:new {
        create_ui = function(self)
            jellyfin_list_ui.create_root(
                self,
                "Tangara",
                {
                    on_back = function()
                    end,
                }
            )

            self.list:set {
                y = 30,
                h = 96,
                pad_row = 0,
            }
            self.list:clear_flag(
                lvgl.FLAG.SCROLLABLE
            )

            local local_row =
                jellyfin_list_ui
                    .add_action_row(
                        self,
                        "Local",
                        {
                            height = 24,
                            y = 5,
                            selection_id =
                                "home:local",
                            on_click =
                                function()
                                    backstack.push(
                                        require(
                                            "jellyfin_local_library"
                                        ).Root:new()
                                    )
                                end,
                        }
                    )

            jellyfin_list_ui.add_action_row(
                self,
                "Sync",
                {
                    height = 24,
                    y = 5,
                    selection_id =
                        "home:sync",
                    on_click = function()
                        backstack.push(
                            SyncScreen:new()
                        )
                    end,
                }
            )

            jellyfin_list_ui.add_action_row(
                self,
                "Storage",
                {
                    height = 24,
                    y = 5,
                    selection_id =
                        "home:storage",
                    on_click = function()
                        backstack.push(
                            require(
                                "jellyfin_storage_ui"
                            ).Root:new()
                        )
                    end,
                }
            )

            jellyfin_list_ui.add_action_row(
                self,
                "Settings",
                {
                    height = 24,
                    y = 5,
                    selection_id =
                        "home:settings",
                    on_click = function()
                        backstack.push(
                            SettingsScreen:new()
                        )
                    end,
                }
            )

            self.first_row = local_row.object
        end,
        on_show =
            jellyfin_list_ui.install_controls,
        on_hide =
            jellyfin_list_ui.restore_controls,
    }

M.Home = HomeScreen
M.Sync = SyncScreen
M.Storage =
    require("jellyfin_storage_ui").Root
M.Settings = SettingsScreen

return M
