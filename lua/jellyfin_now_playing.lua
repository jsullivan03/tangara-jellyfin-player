local lvgl = require("lvgl")
local backstack = require("backstack")
local controls = require("controls")
local jellyfin_playback =
    require("jellyfin_playback")
local jellyfin_track_menu =
    require("jellyfin_track_menu")
local playback = require("playback")
local power = require("power")
local premium =
    require("premium_now_playing_screen")
local screen = require("screen")
local sync_config = require("sync_config")
local sync_runtime = require("sync_runtime")

local function format_time(value)
    value =
        math.max(
            0,
            math.floor(value or 0)
        )

    return string.format(
        "%d:%02d",
        math.floor(value / 60),
        value % 60
    )
end

local function current_clock()
    local ok, value =
        pcall(
            function()
                return os.date("%H:%M")
            end
        )

    if ok and
        type(value) == "string" and
        value ~= "" then
        return value
    end

    return "--:--"
end

local function simulator_mode()
    local ok, value =
        pcall(
            function()
                return os.getenv(
                    "TANGARA_SIM_SERVER_URL"
                )
            end
        )

    return ok and
        type(value) == "string" and
        value ~= ""
end

local function charging_state()
    local state =
        power.charge_state:get()

    return state ==
            "charge_regular" or
        state == "charge_fast" or
        state == "full_charge"
end

local function artwork_value(
    active,
    name,
    fallback
)
    local item_artwork =
        active and
        active.item and
        active.item.artwork

    local track_artwork =
        active and
        active.track and
        active.track.artwork

    if type(item_artwork) == "table" and
        type(item_artwork[name]) ==
            "string" and
        item_artwork[name] ~= "" then
        return item_artwork[name]
    end

    if type(track_artwork) == "table" and
        type(track_artwork[name]) ==
            "string" and
        track_artwork[name] ~= "" then
        return track_artwork[name]
    end

    return fallback
end

local function server_connected(active)
    if active and
        active.context and
        active.context.server_connected ~=
            nil then
        return active.context
            .server_connected == true
    end

    local status = sync_config.status()

    if not status.connected then
        return simulator_mode()
    end

    local library_result =
        sync_runtime.last_library_result()

    if type(library_result) ==
            "table" then
        return library_result.ok == true
    end

    local result =
        sync_runtime.last_result()

    if type(result) == "table" then
        return result.ok == true
    end

    return status.connected == true
end

local NowPlaying =
    screen:new {
        create_ui = function(self)
            local active =
                jellyfin_playback.current()

            local track =
                active and
                active.track or {}

            local duration =
                tonumber(track.duration)
                or tonumber(
                    active and
                    active.item and
                    active.item.duration
                )
                or 0

            self.go_back =
                function()
                    backstack.pop()
                end

            self.open_menu =
                function()
                    local current =
                        jellyfin_playback
                            .current()

                    if not current or
                        not current.track then
                        return
                    end

                    backstack.push(
                        jellyfin_track_menu:new {
                            track =
                                current.track,
                            collection_kind =
                                current.context
                                    .collection_kind,
                            collection_id =
                                current.context
                                    .collection_id,
                            entry_id =
                                current.context
                                    .entry_id,
                        }
                    )
                end

            self.view =
                premium.create {
                    background =
                        artwork_value(
                            active,
                            "background",
                            "//lua/img/background_placeholder.png"
                        ),
                    cover =
                        artwork_value(
                            active,
                            "cover",
                            "//lua/img/cover_placeholder.png"
                        ),
                    title =
                        track.title or
                        "Nothing playing",
                    artist =
                        track.artist or "",
                    progress = 0,
                    elapsed = "0:00",
                    remaining =
                        format_time(
                            duration
                        ),
                    clock =
                        current_clock(),
                    connected =
                        server_connected(
                            active
                        ),
                    battery_pct =
                        power.battery_pct
                            :get(),
                    charging =
                        charging_state(),
                    on_back =
                        self.go_back,
                    focus_back =
                        simulator_mode(),
                }

            self.root = self.view.root

            self.root:onevent(
                lvgl.EVENT.LONG_PRESSED,
                self.open_menu
            )

            self.position_binding =
                playback.position:bind(
                    function(position)
                        local current =
                            jellyfin_playback
                                .current()

                        local current_track =
                            current and
                            current.track or {}

                        local current_duration =
                            tonumber(
                                current_track
                                    .duration
                            )
                            or duration

                        local progress = 0

                        if current_duration >
                                0 then
                            progress =
                                math.max(
                                    0,
                                    math.min(
                                        1,
                                        (
                                            position
                                            or 0
                                        ) /
                                        current_duration
                                    )
                                )
                        end

                        self.view:update {
                            progress =
                                progress,
                            elapsed =
                                format_time(
                                    position
                                ),
                            remaining =
                                format_time(
                                    math.max(
                                        0,
                                        current_duration -
                                        (
                                            position
                                            or 0
                                        )
                                    )
                                ),
                        }
                    end
                )

            self.battery_binding =
                power.battery_pct:bind(
                    function(percentage)
                        self.view:update {
                            battery_pct =
                                percentage,
                        }
                    end
                )

            self.charge_binding =
                power.charge_state:bind(
                    function()
                        self.view:update {
                            charging =
                                charging_state(),
                        }
                    end
                )

            self.plugged_binding =
                power.plugged_in:bind(
                    function()
                        self.view:update {
                            charging =
                                charging_state(),
                        }
                    end
                )

            self.status_timer =
                lvgl.Timer {
                    period = 1000,
                    cb = function()
                        self.view:update {
                            clock =
                                current_clock(),
                            connected =
                                server_connected(
                                    jellyfin_playback
                                        .current()
                                ),
                        }
                    end,
                }
        end,

        on_show = function(self)
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
                self.previous_up =
                    input_method.up
                        .short_press

                input_method.up
                    .short_press =
                    self.go_back
            end

            if input_method.center then
                self.previous_center_long =
                    input_method.center
                        .long_press

                input_method.center
                    .long_press =
                    self.open_menu
            end
        end,

        on_hide = function(self)
            local input_method =
                self.input_method

            if not input_method then
                return
            end

            if input_method.up and
                input_method.up
                    .short_press ==
                    self.go_back then
                input_method.up
                    .short_press =
                    self.previous_up
            end

            if input_method.center and
                input_method.center
                    .long_press ==
                    self.open_menu then
                input_method.center
                    .long_press =
                    self.previous_center_long
            end

            self.input_method = nil
        end,
    }

return NowPlaying
