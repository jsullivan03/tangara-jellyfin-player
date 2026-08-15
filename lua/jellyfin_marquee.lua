local lvgl = require("lvgl")
local jellyfin_theme =
    require("jellyfin_theme")

local M = {}

local DEFAULT_MS_PER_PIXEL = 18
local DEFAULT_MIN_DURATION_MS = 280
local CIRCULAR_GAP_PX = 24

local function alignment_value(value)
    if value == "center" then
        return "center"
    end

    return "left"
end

local function long_mode_value(name)
    local modes = lvgl.LABEL or {}
    local value = modes[name]
    if value == nil then
        return nil
    end
    return value
end

local function content_width()
    return lvgl.SIZE_CONTENT or nil
end

local function clip_mode()
    return long_mode_value("LONG_CLIP") or
        long_mode_value("LONG_DOT") or
        "LONG_CLIP"
end

local function stop_anim(controller)
    if controller.anim and
        type(controller.anim.delete) ==
            "function" then
        pcall(function()
            controller.anim:delete()
        end)
    end

    controller.anim = nil
end

local function clear_label_scroll_state(
    label
)
    if not label then
        return
    end

    -- Force LVGL to drop LONG_SCROLL*_CIRCULAR offset anims / expand state.
    local clip = clip_mode()
    pcall(function()
        label:set {
            long_mode = clip,
        }
    end)
    pcall(function()
        label:scroll_to {
            x = 0,
            y = 0,
            anim = false,
        }
    end)
    pcall(function()
        label:set {
            translate_x = 0,
            translate_y = 0,
        }
    end)
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
        ms_per_pixel =
            tonumber(options.ms_per_pixel) or
            DEFAULT_MS_PER_PIXEL,
        min_duration_ms =
            tonumber(
                options.min_duration_ms
            ) or
            DEFAULT_MIN_DURATION_MS,
        generation = 0,
        active =
            options.autostart == true,
        measured = false,
        overflow = 0,
        text_width = 0,
        short_x = 0,
        current_x = 0,
        destroyed = false,
        text = nil,
        anim = nil,
        uses_native_circular = false,
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
                jellyfin_theme.color(
                    "foreground"
                ),
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

    local function reset_baseline()
        -- Full clean slate before measuring/binding a new string. Do not reuse
        -- prior overflow, fixed circular width, native scroll offsets, or x.
        stop_anim(controller)
        controller.uses_native_circular =
            false
        controller.measured = false
        controller.overflow = 0
        controller.text_width = 0
        controller.short_x = 0
        controller.current_x = 0

        clear_label_scroll_state(
            controller.label
        )

        controller.label:set {
            w = content_width(),
            long_mode = clip_mode(),
            x = 0,
            text_opa = 255,
            text = controller.text or "",
        }

        pcall(function()
            controller.label:set {
                text_align = 0,
            }
        end)

        controller.label:update_layout()
    end

    local function apply_static_mode()
        stop_anim(controller)
        controller.uses_native_circular =
            false
        clear_label_scroll_state(
            controller.label
        )

        local clip = clip_mode()

        if controller.overflow > 0 then
            controller.label:set {
                w = controller.width,
                long_mode = clip,
                text = controller.text or "",
            }
            set_x(0)
        else
            -- Short labels omit a fixed width so x centering matches the
            -- pre-optimization Now Playing layout contract.
            controller.label:set {
                w = nil,
                long_mode = clip,
                text = controller.text or "",
            }
            set_x(controller.short_x)
        end

        controller.label:set {
            text_opa = 255,
        }

        if controller.overflow <= 0 then
            controller.label:update_layout()
        end
    end

    local function begin_native_circular()
        stop_anim(controller)

        local circular =
            long_mode_value(
                "LONG_SCROLL_CIRCULAR"
            )

        if circular == nil then
            return false
        end

        set_x(0)
        controller.label:set {
            w = controller.width,
            long_mode = circular,
            text = controller.text or "",
            text_opa = 255,
        }
        controller.uses_native_circular =
            true
        controller.current_x = 0
        return true
    end

    local function begin_anim_cycle()
        stop_anim(controller)
        controller.uses_native_circular =
            false
        clear_label_scroll_state(
            controller.label
        )

        local travel =
            controller.overflow +
            CIRCULAR_GAP_PX

        if travel <= 0 then
            apply_static_mode()
            return
        end

        local duration =
            math.max(
                controller.min_duration_ms,
                math.floor(
                    travel *
                    controller.ms_per_pixel
                )
            )

        set_x(0)
        controller.label:set {
            w = content_width(),
            long_mode = clip_mode(),
            text = controller.text or "",
            text_opa = 255,
        }

        local generation =
            controller.generation

        local ok, anim = pcall(function()
            return controller.label:Anim {
                run = true,
                start_value = 0,
                end_value = -travel,
                duration = duration,
                repeat_count =
                    lvgl.ANIM_REPEAT_INFINITE or
                    -1,
                path = "linear",
                exec_cb = function(
                    animated_object,
                    position
                )
                    if controller.destroyed or
                        controller.generation ~=
                            generation or
                        not controller.active then
                        return
                    end

                    controller.current_x =
                        math.floor(position)
                    animated_object:set {
                        x = controller.current_x,
                    }
                end,
            }
        end)

        if ok then
            controller.anim = anim
        else
            apply_static_mode()
        end
    end

    local function begin_scroll()
        if controller.destroyed or
            not controller.active or
            controller.overflow <= 0 then
            apply_static_mode()
            return
        end

        if begin_native_circular() then
            return
        end

        begin_anim_cycle()
    end

    local function finish_measurement(
        generation,
        settle_position
    )
        if controller.destroyed or
            controller.generation ~=
                generation then
            return
        end

        controller.label:update_layout()

        local clip = clip_mode()

        controller.label:set {
            w = content_width(),
            long_mode = clip,
            x = 0,
        }
        controller.label:update_layout()
        controller.view:update_layout()

        local coordinates =
            controller.label:get_coords()

        local text_width =
            coordinates.x2 -
            coordinates.x1 + 1

        controller.text_width = text_width
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

        if settle_position and
            controller.overflow <= 0 then
            apply_static_mode()
            controller.label:update_layout()
            return
        end

        if controller.active and
            controller.overflow > 0 then
            begin_scroll()
        else
            apply_static_mode()
        end
    end

    local function measure(immediate)
        controller.generation =
            controller.generation + 1

        local generation =
            controller.generation

        reset_baseline()

        if immediate then
            finish_measurement(
                generation,
                true
            )
            return
        end

        lvgl.Timer {
            period = 1,
            repeat_count = 1,
            cb = function()
                finish_measurement(
                    generation
                )
            end,
        }
    end

    function controller:reset()
        if controller.destroyed then
            return
        end

        controller.generation =
            controller.generation + 1
        reset_baseline()
    end

    function controller:set(value)
        if controller.destroyed then
            return
        end

        local next_text =
            tostring(value or "")

        if controller.text ==
                next_text then
            return
        end

        controller.text = next_text
        measure()
    end

    function controller:rebind(
        value,
        immediate
    )
        if controller.destroyed then
            return
        end

        -- Always fully reset prior marquee geometry before binding new text,
        -- even when the string is unchanged after a suspend/resume cycle.
        controller.text =
            tostring(value or "")
        measure(immediate ~= false)
    end

    function controller:refresh(
        immediate
    )
        if controller.destroyed then
            return
        end

        measure(immediate == true)
    end

    function controller:set_width(width)
        if controller.destroyed then
            return
        end

        local next_width =
            math.max(
                1,
                math.floor(
                    tonumber(width) or 1
                )
            )

        if controller.width ==
                next_width then
            return
        end

        controller.width = next_width
        controller.view:set {
            w = controller.width,
        }

        measure()
    end

    function controller:start()
        if controller.destroyed then
            return
        end

        controller.active = true

        if not controller.measured then
            measure(true)
            return
        end

        if controller.overflow > 0 then
            begin_scroll()
        else
            -- Fitting titles must re-assert centered static geometry. A prior
            -- long track can leave fixed width / x=0 until this runs.
            apply_static_mode()
        end
    end

    function controller:stop()
        if controller.destroyed then
            return
        end

        controller.active = false
        controller.generation =
            controller.generation + 1
        -- Stop must not keep the previous track's circular/fixed-width layout.
        -- Reset to a neutral baseline; the next set/rebind remasures.
        reset_baseline()
    end

    function controller:destroy()
        controller.active = false
        controller.destroyed = true
        controller.generation =
            controller.generation + 1
        stop_anim(controller)
        clear_label_scroll_state(
            controller.label
        )
    end

    if options.text ~= nil then
        controller:rebind(
            options.text,
            true
        )
    else
        controller.text = ""
        reset_baseline()
    end

    if controller.active then
        controller:start()
    end

    return controller
end

return M
