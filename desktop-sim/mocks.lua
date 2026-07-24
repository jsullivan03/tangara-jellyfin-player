local M = {}

local function property(initial_value)
    local value = initial_value
    local callbacks = {}

    local p = {}

    function p:get()
        return value
    end

    function p:set(new_value)
        value = new_value

        for _, callback in ipairs(callbacks) do
            callback(value)
        end

        return true
    end

    function p:bind(callback)
        table.insert(callbacks, callback)

        -- Tangara properties run their binding once immediately.
        callback(value)

        -- The real firmware returns a binding userdata. A table is sufficient
        -- for the simulator because the UI only keeps a reference to it.
        return {
            property = p,
            callback = callback,
        }
    end

    return p
end

local function empty_iterator()
    return {
        next = function()
            return nil
        end,
    }
end

local function install_module(name, module)
    package.preload[name] = function()
        return module
    end
end

function M.install(lvgl)
    ---------------------------------------------------------------------------
    -- Fonts
    ---------------------------------------------------------------------------

    local builtin = lvgl.BUILTIN_FONT or {}

    local fallback_font =
        builtin.MONTSERRAT_12
        or builtin.MONTSERRAT_14
        or builtin.DEFAULT

    local font = {
        fusion_10 = builtin.MONTSERRAT_10 or fallback_font,
        fusion_12 = builtin.MONTSERRAT_12 or fallback_font,
    }

    _G.font = font
    install_module("font", font)

    ---------------------------------------------------------------------------
    -- Screen inheritance
    ---------------------------------------------------------------------------

    local screen = {}

    function screen:new(object)
        object = object or {}
        self.__index = self
        return setmetatable(object, self)
    end

    function screen:create_ui()
    end

    function screen:on_show()
    end

    function screen:on_hide()
    end

    function screen:can_pop()
        return true
    end

    install_module("screen", screen)

    ---------------------------------------------------------------------------
    -- Property-backed hardware modules
    ---------------------------------------------------------------------------

    local volume = {
        current_pct = property(50),
        current_db = property(-20),
        left_bias = property(0),
        limit_db = property(0),
    }

    local power = {
        battery_pct = property(82),
        battery_millivolts = property(3900),
        plugged_in = property(false),
        charge_state = property("normal"),
        fast_charge = property(false),
    }

    local bluetooth = {
        enabled = property(false),
        connected = property(false),
        connecting = property(false),
        discovering = property(false),
        paired_device = property(nil),
        discovered_devices = property({}),
        known_devices = property({}),
    }

    function bluetooth.enable()
        bluetooth.enabled:set(true)
    end

    function bluetooth.disable()
        bluetooth.enabled:set(false)
        bluetooth.connected:set(false)
    end

    local playback = {
        playing = property(false),
        track = property(nil),
        position = property(0),
    }

    function playback.is_playable()
        return true
    end

    local queue = {
        position = property(0),
        size = property(0),
        repeat_mode = property(0),
        random = property(false),
        loading = property(false),
        ready = property(true),
    }

    function queue.next()
    end

    function queue.previous()
    end

    local database = {
        updating = property(false),
        auto_update = property(true),
        skip_verification = property(false),
    }

    function database.indexes()
        return {}
    end

    local sd_card = {
        mounted = property(true),
    }

    function sd_card.unmount()
        sd_card.mounted:set(false)
    end

    local usb = {
        msc_enabled = property(false),
        msc_busy = property(false),
    }

    local display = {
        brightness = property(75),
        text_to_speech = property(false),
    }

    local controls = {
        wheel_scheme = property("wheel"),
        button_scheme = property("default"),
        locked_scheme = property("default"),
        haptics_mode = property("medium"),
        lock_switch = property(false),
        scroll_sensitivity = property(5),
    }

    local control_hooks = {
        wheel = {
            left = {},
            right = {},
            up = {},
            down = {},
            center = {},
        },
        dpad = {
            left = {},
            right = {},
            up = {},
            down = {},
            center = {},
        },
    }

    function controls.hooks()
        return control_hooks
    end

    local playing_screen_settings = {
        long_text_scheme = property("scroll"),
    }

    ---------------------------------------------------------------------------
    -- Navigation
    ---------------------------------------------------------------------------

    local current_screen = nil
    local screen_stack = {}

    local function hide_screen(value)
        if value and value.on_hide then
            value:on_hide()
        end

        if value and value.root then
            value.root:add_flag(lvgl.FLAG.HIDDEN)
        end
    end

    local function show_screen(value)
        current_screen = value

        if not value.root then
            value:create_ui()
        else
            value.root:clear_flag(lvgl.FLAG.HIDDEN)
        end

        if value.on_show then
            value:on_show()
        end
    end

    local backstack = {}

    function backstack.reset(value)
        if current_screen then
            hide_screen(current_screen)
        end

        screen_stack = {}
        show_screen(value)
    end

    function backstack.push(value)
        if current_screen then
            table.insert(screen_stack, current_screen)
            hide_screen(current_screen)
        end

        show_screen(value)
    end

    function backstack.pop()
        if #screen_stack == 0 then
            return
        end

        hide_screen(current_screen)
        show_screen(table.remove(screen_stack))
    end

    ---------------------------------------------------------------------------
    -- Remaining service modules
    ---------------------------------------------------------------------------

    local filesystem = {}

    function filesystem.iterator()
        return empty_iterator()
    end

    function filesystem.mkdir()
        return true
    end

    function filesystem.remove()
        return true
    end

    local theme = {}

    function theme.theme_filename()
        return "desktop-theme"
    end

    function theme.load_theme()
        -- Skip loading an embedded theme file for the first simulator pass.
        return true
    end

    function theme.set()
    end

    function theme.set_subject()
    end

    local alerts = {}

    function alerts.show(builder)
        if builder then
            builder()
        end
    end

    function alerts.hide()
    end

    local time = {}

    function time.ticks()
        return math.floor(os.clock() * 1000)
    end

    local nvs = {}

    function nvs.get()
        return nil
    end

    function nvs.set()
        return true
    end

    local version = {}

    function version.samd()
        return "desktop"
    end

    function version.update_samd()
        return false
    end

    ---------------------------------------------------------------------------
    -- Register modules
    ---------------------------------------------------------------------------

    install_module("volume", volume)
    install_module("power", power)
    install_module("bluetooth", bluetooth)
    install_module("playback", playback)
    install_module("queue", queue)
    install_module("database", database)
    install_module("sd_card", sd_card)
    install_module("usb", usb)
    install_module("display", display)
    install_module("controls", controls)
    install_module("playing_screen_settings", playing_screen_settings)
    install_module("backstack", backstack)
    install_module("filesystem", filesystem)
    install_module("theme", theme)
    install_module("alerts", alerts)
    install_module("time", time)
    install_module("nvs", nvs)
    install_module("version", version)

    return {
        property = property,
        backstack = backstack,
    }
end

return M
