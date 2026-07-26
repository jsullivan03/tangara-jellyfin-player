local lvgl = require("lvgl")
local power = require("power")
local sync_config = require("sync_config")
local sync_runtime = require("sync_runtime")

local M = {}

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
        bg_color = "#05060A",
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
            y = 3,
            w = 7,
            h = 7,
            pad_all = 0,
            border_width = 1,
            border_color = "#8A8C93",
            radius = 4,
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
            bg_color = "#8FB9A8",
            bg_opa = 0,
        }

    local clock = root:Label {
        x = 56,
        y = 2,
        w = 48,
        text = "--:--",
        text_align = 2,
        text_color = "#D4D5DA",
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
            border_color = "#D4D5DA",
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
                bg_color = "#4E5058",
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
            bg_color = "#D4D5DA",
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
            "#D4D5DA"

        if is_charging then
            active_color =
                "#74C991"
        elseif percentage <= 10 then
            active_color =
                "#E06666"
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
                    "#4E5058",
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
                "#8FB9A8" or
                "#8A8C93",
        }

        connection_dot:set {
            bg_opa =
                connected and
                255 or
                0,
        }
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

    local timer =
        lvgl.Timer {
            period = 1000,
            cb = function()
                clock:set {
                    text =
                        current_clock(),
                }

                update_connection()
            end,
        }

    clock:set {
        text = current_clock(),
    }

    update_connection()
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
            lvgl.group.remove_obj(clock)
            lvgl.group.remove_obj(battery)
        end
    )

    return {
        root = root,
        bindings = bindings,
        timer = timer,
    }
end

return M
