local lvgl = require("lvgl")

local M = {}

local DEFAULT_HOLD_MS = 900
local DEFAULT_MS_PER_PIXEL = 18
local DEFAULT_MIN_DURATION_MS = 280
local DEFAULT_STEP_MS = 35

local scheduled_controllers =
    setmetatable(
        {},
        {__mode = "k"}
    )

local scheduler_timer = nil

local function alignment_value(value)
    if value == "center" then
        return "center"
    end

    return "left"
end

local function cancel_schedule(controller)
    controller.pending_task = nil
    scheduled_controllers[controller] = nil
end

local function has_scheduled_tasks()
    for controller in pairs(
        scheduled_controllers
    ) do
        if controller.destroyed or
            not controller.pending_task then
            scheduled_controllers[
                controller
            ] = nil
        else
            return true
        end
    end

    return false
end

local function ensure_scheduler()
    if scheduler_timer then
        return scheduler_timer
    end

    scheduler_timer =
        lvgl.Timer {
            paused = true,
            period = DEFAULT_STEP_MS,
            repeat_count = -1,
            cb = function()
                for controller in pairs(
                    scheduled_controllers
                ) do
                    local task =
                        controller.pending_task

                    if controller.destroyed or
                        not task then
                        scheduled_controllers[
                            controller
                        ] = nil
                    else
                        task.remaining_ms =
                            task.remaining_ms -
                            DEFAULT_STEP_MS

                        if task.remaining_ms <= 0 then
                            controller.pending_task =
                                nil
                            scheduled_controllers[
                                controller
                            ] = nil

                            if controller.generation ==
                                    task.generation and
                                not controller.destroyed then
                                task.callback()
                            end

                            if controller.pending_task and
                                not controller.destroyed then
                                scheduled_controllers[
                                    controller
                                ] = true
                            end
                        end
                    end
                end

                if not has_scheduled_tasks() then
                    scheduler_timer:pause()
                end
            end,
        }

    return scheduler_timer
end

local function schedule(
    controller,
    milliseconds,
    generation,
    callback
)
    cancel_schedule(controller)

    controller.pending_task = {
        remaining_ms = math.max(
            1,
            math.floor(
                tonumber(milliseconds) or 1
            )
        ),
        generation = generation,
        callback = callback,
    }

    scheduled_controllers[controller] =
        true

    ensure_scheduler():resume()
end

function M.create(parent, options)
    options = options or {}

    local controller = {
        width = math.max(
            1,
            math.floor(
                tonumber(options.w) or 1
            )
        ),
        height = math.max(
            16,
            math.floor(
                tonumber(options.h) or 16
            )
        ),
        alignment =
            alignment_value(options.align),
        hold_ms =
            tonumber(options.hold_ms) or
            DEFAULT_HOLD_MS,
        ms_per_pixel =
            tonumber(options.ms_per_pixel) or
            DEFAULT_MS_PER_PIXEL,
        min_duration_ms =
            tonumber(
                options.min_duration_ms
            ) or
            DEFAULT_MIN_DURATION_MS,
        step_ms =
            tonumber(options.step_ms) or
            DEFAULT_STEP_MS,
        generation = 0,
        active =
            options.autostart == true,
        measured = false,
        overflow = 0,
        short_x = 0,
        current_x = 0,
        destroyed = false,
        pending_task = nil,
    }

    controller.view =
        parent:Object {
            x = options.x or 0,
            y = options.y or 0,
            w = controller.width,
            h = controller.height,
            pad_all = 0,
            border_width = 0,
            radius = 0,
            bg_opa = 0,
            scrollbar_mode =
                lvgl.SCROLLBAR_MODE.OFF,
        }

    controller.view:clear_flag(
        lvgl.FLAG.SCROLLABLE
    )
    controller.view:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    controller.label =
        controller.view:Label {
            x = 0,
            y = options.label_y or 2,
            h = controller.height,
            text = "",
            text_color =
                options.text_color or
                "#FFFFFF",
            text_font =
                options.text_font or
                font.fusion_10,
            text_opa = 0,
        }

    controller.label:clear_flag(
        lvgl.FLAG.CLICKABLE
    )

    local function set_x(value)
        controller.current_x =
            math.floor(value)

        controller.label:set {
            x = controller.current_x,
        }
    end

    local function reset_position()
        if controller.destroyed then
            return
        end

        if controller.overflow > 0 then
            set_x(0)
        else
            set_x(controller.short_x)
        end

        controller.label:set {
            text_opa = 255,
        }
    end

    local function animate_to(
        generation,
        target,
        done_callback
    )
        local start =
            controller.current_x

        local distance =
            math.abs(target - start)

        if distance <= 0 then
            done_callback()
            return
        end

        local duration =
            math.max(
                controller.min_duration_ms,
                math.floor(
                    distance *
                    controller.ms_per_pixel
                )
            )

        local steps =
            math.max(
                1,
                math.ceil(
                    duration /
                    controller.step_ms
                )
            )

        local index = 0

        local function advance()
            if controller.generation ~=
                    generation or
                not controller.active or
                controller.destroyed then
                return
            end

            index = index + 1

            local progress =
                math.min(
                    1,
                    index / steps
                )

            set_x(
                start +
                (target - start) *
                progress
            )

            if progress >= 1 then
                done_callback()
                return
            end

            schedule(
                controller,
                controller.step_ms,
                generation,
                advance
            )
        end

        schedule(
            controller,
            controller.step_ms,
            generation,
            advance
        )
    end

    local function begin_cycle()
        if not controller.active or
            not controller.measured or
            controller.overflow <= 0 or
            controller.destroyed then
            return
        end

        controller.generation =
            controller.generation + 1

        local generation =
            controller.generation

        set_x(0)

        local move_forward
        local move_backward

        move_forward =
            function()
                if controller.generation ~=
                        generation or
                    not controller.active or
                    controller.destroyed then
                    return
                end

                animate_to(
                    generation,
                    -controller.overflow,
                    function()
                        schedule(
                            controller,
                            controller.hold_ms,
                            generation,
                            move_backward
                        )
                    end
                )
            end

        move_backward =
            function()
                if controller.generation ~=
                        generation or
                    not controller.active or
                    controller.destroyed then
                    return
                end

                animate_to(
                    generation,
                    0,
                    function()
                        schedule(
                            controller,
                            controller.hold_ms,
                            generation,
                            move_forward
                        )
                    end
                )
            end

        schedule(
            controller,
            controller.hold_ms,
            generation,
            move_forward
        )
    end

    local function measure()
        controller.generation =
            controller.generation + 1

        local generation =
            controller.generation

        controller.measured = false
        controller.overflow = 0
        controller.short_x = 0
        controller.current_x = 0

        controller.label:set {
            x = 0,
            text_opa = 0,
        }

        schedule(
            controller,
            35,
            generation,
            function()
                if controller.destroyed then
                    return
                end

                local coordinates =
                    controller.label
                        :get_coords()

                local text_width =
                    coordinates.x2 -
                    coordinates.x1 + 1

                controller.overflow =
                    math.max(
                        0,
                        text_width -
                        controller.width
                    )

                if controller.overflow <= 0 and
                    controller.alignment ==
                        "center" then
                    controller.short_x =
                        math.max(
                            0,
                            math.floor(
                                (
                                    controller.width -
                                    text_width
                                ) / 2
                            )
                        )
                else
                    controller.short_x = 0
                end

                controller.measured = true
                reset_position()

                if controller.active and
                    controller.overflow > 0 then
                    begin_cycle()
                end
            end
        )
    end

    function controller:set(value)
        if controller.destroyed then
            return
        end

        controller.generation =
            controller.generation + 1
        cancel_schedule(controller)

        controller.label:set {
            text = value or "",
            x = 0,
            text_opa = 0,
        }

        measure()
    end

    function controller:set_width(width)
        if controller.destroyed then
            return
        end

        controller.width =
            math.max(
                1,
                math.floor(
                    tonumber(width) or 1
                )
            )

        controller.view:set {
            w = controller.width,
        }

        cancel_schedule(controller)
        measure()
    end

    function controller:start()
        if controller.destroyed then
            return
        end

        controller.active = true

        if controller.measured and
            controller.overflow > 0 then
            begin_cycle()
        end
    end

    function controller:stop()
        if controller.destroyed then
            return
        end

        controller.active = false
        controller.generation =
            controller.generation + 1
        cancel_schedule(controller)
        reset_position()
    end

    function controller:destroy()
        controller.active = false
        controller.destroyed = true
        controller.generation =
            controller.generation + 1
        cancel_schedule(controller)
    end

    controller:set(options.text or "")

    return controller
end

return M
