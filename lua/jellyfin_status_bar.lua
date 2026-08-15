local lvgl = require("lvgl")
local power = require("power")
local sync_config = require("sync_config")
local sync_runtime = require("sync_runtime")
local jellyfin_theme =
    require("jellyfin_theme")

local M = {}
local palette = jellyfin_theme.current()

-- Error feedback belongs in the status bar, but it should not permanently
-- replace progress across every screen.  Keep one short-lived notification
-- per unique runtime error; the failed row remains the durable retry affordance.
local sync_error_signature = nil
local sync_error_ticks_remaining = 0
local SYNC_ERROR_VISIBLE_TICKS = 16

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

local function connected_state()
    local status = sync_config.status()

    if not status.connected then
        return simulator_mode()
    end

    local library_result =
        sync_runtime.last_library_result()

    if type(library_result) == "table" then
        return library_result.ok == true
    end

    local result =
        sync_runtime.last_result()

    if type(result) == "table" then
        return result.ok == true
    end

    return status.connected == true
end

local function charging_state()
    local state =
        power.charge_state:get()

    return state ==
            "charge_regular" or
        state == "charge_fast" or
        state == "full_charge"
end

function M.create(parent)

    local root = parent:Object {
        x = 0,
        y = 0,
        w = 160,
        h = 13,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_color = palette.status_background,
        bg_opa = 255,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    root:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local connection_container =
        root:Object {
            x = 0,
            y = 0,
            w = 18,
            h = 13,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    connection_container:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local connection_ring =
        connection_container:Object {
            x = 5,
            y = 2,
            w = 8,
            h = 8,
            pad_all = 0,
            border_width = 1,
            border_color =
                palette.status_muted,
            radius = 5,
            bg_opa = 0,
        }

    local connection_dot =
        connection_ring:Object {
            x = 2,
            y = 2,
            w = 3,
            h = 3,
            pad_all = 0,
            border_width = 0,
            radius = 2,
            bg_color =
                palette.status_good,
            bg_opa = 0,
        }

    local sync_track =
        root:Object {
            x = 20,
            y = 5,
            w = 32,
            h = 3,
            pad_all = 0,
            border_width = 0,
            radius = 1,
            bg_color = palette.status_muted,
            bg_opa = 150,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    sync_track:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    sync_track:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    sync_track:add_flag(
        lvgl.FLAG.HIDDEN
    )

    local sync_fill =
        sync_track:Object {
            x = 0,
            y = 0,
            w = 1,
            h = 3,
            pad_all = 0,
            border_width = 0,
            radius = 1,
            bg_color = palette.accent,
            bg_opa = 255,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    sync_fill:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    sync_fill:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local sync_error =
        root:Label {
            x = 45,
            y = 0,
            w = 8,
            h = 12,
            text = "!",
            text_align = 2,
            text_color = palette.status_bad,
            text_font = font.fusion_10,
        }

    sync_error:clear_flag(
        lvgl.FLAG.CLICKABLE
    )
    sync_error:add_flag(
        lvgl.FLAG.HIDDEN
    )

    local clock = root:Label {
        x = 56,
        y = 2,
        w = 48,
        text = "--:--",
        text_align = 2,
        text_color = palette.foreground,
        text_font = font.fusion_10,
    }

    local battery = root:Object {
        x = 139,
        y = 3,
        w = 17,
        h = 8,
        pad_all = 0,
        border_width = 0,
        radius = 0,
        bg_opa = 0,
        scrollbar_mode =
            lvgl.SCROLLBAR_MODE.OFF,
    }

    battery:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )

    local battery_body =
        battery:Object {
            x = 0,
            y = 0,
            w = 14,
            h = 8,
            pad_all = 0,
            border_width = 1,
            border_color = palette.foreground,
            radius = 2,
            bg_opa = 0,
        }

    local battery_segments = {}

    for index = 1, 4 do
        battery_segments[index] =
            battery_body:Object {
                x = 1 + (
                    index - 1
                ) * 3,
                y = 2,
                w = 2,
                h = 4,
                pad_all = 0,
                border_width = 0,
                radius = 0,
                bg_color =
                    palette.status_muted,
                bg_opa = 190,
            }
    end

    local battery_terminal =
        battery:Object {
            x = 14,
            y = 2,
            w = 2,
            h = 4,
            pad_all = 0,
            border_width = 0,
            radius = 1,
            bg_color = palette.foreground,
            bg_opa = 255,
        }

    local battery_percentage =
        tonumber(
            power.battery_pct:get()
        ) or 0

    local is_charging =
        charging_state()

    local function update_battery()
        local percentage =
            math.max(
                0,
                math.min(
                    100,
                    battery_percentage
                )
            )

        local active_segments = 0

        if percentage > 0 then
            active_segments =
                math.ceil(
                    percentage / 25
                )
        end

        local active_color =
            palette.foreground

        if is_charging then
            active_color =
                palette.status_good
        elseif percentage <= 10 then
            active_color =
                palette.status_bad
        end

        battery_body:set {
            border_color =
                active_color,
        }

        battery_terminal:set {
            bg_color =
                active_color,
        }

        for index, segment in ipairs(
            battery_segments
        ) do
            segment:set {
                bg_color =
                    index <=
                        active_segments and
                    active_color or
                    palette.status_muted,
                bg_opa =
                    index <=
                        active_segments and
                    255 or
                    190,
            }
        end
    end

    local function update_connection()
        local connected =
            connected_state()

        connection_ring:set {
            border_color =
                connected and
                palette.status_good or
                palette.status_muted,
        }

        connection_dot:set {
            bg_opa =
                connected and
                255 or
                0,
        }
    end

    local sync_phase = 0

    local function optional_runtime_call(name)
        local callback = sync_runtime[name]

        if type(callback) ~= "function" then
            return nil
        end

        local ok, value = pcall(callback)

        if not ok then
            return nil
        end

        return value
    end

    local function update_sync_indicator()
        local activity =
            optional_runtime_call(
                "activity"
            )

        if type(activity) ~= "table" then
            activity = {
                mode = "idle",
            }
        end

        if activity.mode == "error" then
            local signature = tostring(
                activity.error or
                "sync operation failed"
            )

            if signature ~= sync_error_signature then
                sync_error_signature = signature
                sync_error_ticks_remaining =
                    SYNC_ERROR_VISIBLE_TICKS
                pcall(
                    print,
                    "[sync-error] " .. signature
                )
            end

            if sync_error_ticks_remaining > 0 then
                sync_error_ticks_remaining =
                    sync_error_ticks_remaining - 1
                sync_track:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
                sync_fill:set {
                    x = 0,
                    w = 32,
                    bg_color =
                        palette.status_bad,
                }
                sync_error:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
            else
                sync_track:add_flag(
                    lvgl.FLAG.HIDDEN
                )
                sync_error:add_flag(
                    lvgl.FLAG.HIDDEN
                )
            end
            return
        end

        sync_error_signature = nil
        sync_error_ticks_remaining = 0
        sync_error:add_flag(
            lvgl.FLAG.HIDDEN
        )

        if activity.mode == "determinate" then
            local bytes =
                tonumber(activity.bytes) or 0
            local total =
                tonumber(
                    activity.bytes_total
                ) or 0

            if total <= 0 then
                activity.mode = "indeterminate"
            else
                local ratio =
                    math.max(
                        0,
                        math.min(
                            1,
                            bytes / total
                        )
                    )

                sync_track:clear_flag(
                    lvgl.FLAG.HIDDEN
                )
                sync_fill:set {
                    x = 0,
                    w = math.max(
                        1,
                        math.floor(
                            32 * ratio + 0.5
                        )
                    ),
                    bg_color = palette.accent,
                }
                return
            end
        end

        if activity.mode == "indeterminate" then
            sync_phase =
                (sync_phase + 3) % 25

            sync_track:clear_flag(
                lvgl.FLAG.HIDDEN
            )
            sync_fill:set {
                x = sync_phase,
                w = 8,
                bg_color = palette.accent,
            }
            return
        end

        sync_track:add_flag(
            lvgl.FLAG.HIDDEN
        )
    end

    local bindings = {
        power.battery_pct:bind(
            function(percentage)
                battery_percentage =
                    tonumber(percentage) or 0
                update_battery()
            end
        ),
        power.charge_state:bind(
            function()
                is_charging =
                    charging_state()
                update_battery()
            end
        ),
        power.plugged_in:bind(
            function()
                is_charging =
                    charging_state()
                update_battery()
            end
        ),
    }

    local timer = nil
    local timer_retired = false

    local function retire_timer()
        if timer_retired then
            return
        end

        timer_retired = true

        if timer then
            pcall(
                function()
                    timer:delete()
                end
            )
            timer = nil
        end
    end

    timer =
        lvgl.Timer {
            period = 250,
            cb = function()
                if timer_retired then
                    return
                end

                local alive = pcall(
                    function()
                        clock:set {
                            text =
                                current_clock(),
                        }

                        update_connection()
                        update_sync_indicator()
                    end
                )

                if not alive then
                    retire_timer()
                end
            end,
        }

    clock:set {
        text = current_clock(),
    }

    update_connection()
    update_sync_indicator()
    update_battery()

    pcall(
        function()
            lvgl.group.remove_obj(root)
            lvgl.group.remove_obj(
                connection_container
            )
            lvgl.group.remove_obj(
                connection_ring
            )
            lvgl.group.remove_obj(
                connection_dot
            )
            lvgl.group.remove_obj(
                sync_track
            )
            lvgl.group.remove_obj(
                sync_fill
            )
            lvgl.group.remove_obj(
                sync_error
            )
            lvgl.group.remove_obj(clock)
            lvgl.group.remove_obj(battery)
        end
    )

    return {
        root = root,
        bindings = bindings,
        timer = timer,
        retire = retire_timer,
    }
end

return M
