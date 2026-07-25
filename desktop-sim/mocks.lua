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

    ---------------------------------------------------------------------------
    -- Fake desktop music database
    ---------------------------------------------------------------------------

    local fake_tracks = {
        [1] = {
            id = 1,
            title = "Midnight Circuit",
            artist = "Example Artist",
            album = "Demo Album",
            duration = 218,
            filepath = "/Music/Example Artist/Demo Album/01 Midnight Circuit.mp3",
            uri = "/Music/Example Artist/Demo Album/01 Midnight Circuit.mp3",
            saved_position = 0,
            play_count = 0,
            encoding = "MP3",
            sample_rate = 44100,
            num_channels = 2,
            bitrate_kbps = 320,
            tags = {
                title = "Midnight Circuit",
                artist = "Example Artist",
                album = "Demo Album",
                track = 1,
            },
        },
        [2] = {
            id = 2,
            title = "Afterglow",
            artist = "Example Artist",
            album = "Demo Album",
            duration = 194,
            filepath = "/Music/Example Artist/Demo Album/02 Afterglow.mp3",
            uri = "/Music/Example Artist/Demo Album/02 Afterglow.mp3",
            saved_position = 0,
            play_count = 0,
            encoding = "MP3",
            sample_rate = 44100,
            num_channels = 2,
            bitrate_kbps = 320,
            tags = {
                title = "Afterglow",
                artist = "Example Artist",
                album = "Demo Album",
                track = 2,
            },
        },
        [3] = {
            id = 3,
            title = "Homebound",
            artist = "Second Artist",
            album = "Late Hours",
            duration = 241,
            filepath = "/Music/Second Artist/Late Hours/01 Homebound.mp3",
            uri = "/Music/Second Artist/Late Hours/01 Homebound.mp3",
            saved_position = 0,
            play_count = 0,
            encoding = "MP3",
            sample_rate = 48000,
            num_channels = 2,
            bitrate_kbps = 256,
            tags = {
                title = "Homebound",
                artist = "Second Artist",
                album = "Late Hours",
                track = 1,
            },
        },
    }

    local record_methods = {}

    function record_methods:title()
        return self.text
    end

    function record_methods:contents()
        return self.content
    end

    local record_mt = {
        __index = record_methods,
        __tostring = function(record)
            return record.text
        end,
    }

    local function new_record(text_value, content)
        return setmetatable({
            text = text_value,
            content = content,
        }, record_mt)
    end

    local iterator_methods = {}

    function iterator_methods:next()
        self.position = self.position + 1
        return self.items[self.position]
    end

    function iterator_methods:prev()
        self.position = self.position - 1

        if self.position < 1 then
            self.position = 0
            return nil
        end

        return self.items[self.position]
    end

    function iterator_methods:value()
        return self.items[self.position]
    end

    function iterator_methods:clone()
        return setmetatable({
            items = self.items,
            position = self.position,
        }, getmetatable(self))
    end

    local iterator_mt = {
        __index = iterator_methods,
        __call = function(iterator)
            return iterator:next()
        end,
    }

    local function new_iterator(items)
        return setmetatable({
            items = items,
            position = 0,
        }, iterator_mt)
    end

    local database = {
        updating = property(false),
        auto_update = property(true),
        skip_verification = property(false),

        MediaTypes = {
            Unknown = 0,
            Music = 1,
            Podcast = 2,
            Audiobook = 3,
            Any = 4,
        },

        IndexTypes = {
            ALBUMS_BY_ARTIST = 1,
            TRACKS_BY_GENRE = 2,
            ALL_TRACKS = 3,
            ALL_ALBUMS = 4,
            ALL_ARTISTS = 5,
            PODCASTS = 6,
            AUDIOBOOKS = 7,
        },
    }

    function database.track_by_id(id)
        return fake_tracks[id]
    end

    function database.version()
        return "desktop-mock-1"
    end

    function database.size()
        return 0
    end

    function database.recreate()
    end

    function database.update()
        database.updating:set(false)
    end

    local all_track_records = {
        new_record("Midnight Circuit", 1),
        new_record("Afterglow", 2),
        new_record("Homebound", 3),
    }

    local all_tracks_index = setmetatable({
        name_value = "All Tracks",
    }, {
        __tostring = function(index)
            return index.name_value
        end,
        __index = {
            name = function(index)
                return index.name_value
            end,
            id = function()
                return database.IndexTypes.ALL_TRACKS
            end,
            type = function()
                return database.MediaTypes.Music
            end,
            iter = function()
                return new_iterator(all_track_records)
            end,
        },
    })

    function database.indexes()
        return { all_tracks_index }
    end

    ---------------------------------------------------------------------------
    -- Fake playback queue
    ---------------------------------------------------------------------------

    local queue = {
        position = property(0),
        size = property(0),
        repeat_mode = property(0),
        random = property(false),
        loading = property(false),
        ready = property(true),
    }

    local queued_ids = {}

    local function select_queue_position(position)
        local id = queued_ids[position]

        if not id then
            return
        end

        queue.position:set(position)
        playback.position:set(0)
        playback.track:set(database.track_by_id(id))
    end

    function queue.clear()
        queued_ids = {}
        queue.position:set(0)
        queue.size:set(0)
        playback.track:set(nil)
        playback.position:set(0)
    end

    function queue.add(value)
        if type(value) == "number" then
            table.insert(queued_ids, value)
        elseif type(value) == "table" and value.clone then
            local iterator = value:clone()

            while true do
                local item = iterator:next()

                if not item then
                    break
                end

                local id = item:contents()

                if type(id) == "number" then
                    table.insert(queued_ids, id)
                end
            end
        end

        queue.size:set(#queued_ids)

        if #queued_ids > 0 and queue.position:get() == 0 then
            select_queue_position(1)
        end
    end

    function queue.next()
        local next_position = queue.position:get() + 1

        if next_position <= #queued_ids then
            select_queue_position(next_position)
        end
    end

    function queue.previous()
        local previous_position = queue.position:get() - 1

        if previous_position >= 1 then
            select_queue_position(previous_position)
        end
    end

    function queue.play_from(filepath, position)
        for id, track in pairs(fake_tracks) do
            if track.filepath == filepath then
                queued_ids = { id }
                queue.size:set(1)
                select_queue_position(1)
                playback.position:set(position or 0)
                return
            end
        end
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

    local nvs_values = {
        wifi_ssid = nil,
        wifi_password = nil,
        sync_server_url = nil,
    }

    local nvs = {}

    function nvs.write()
        return true
    end

    function nvs.wifi_ssid()
        return nvs_values.wifi_ssid
    end

    function nvs.set_wifi_ssid(value)
        nvs_values.wifi_ssid = value
        return true
    end

    function nvs.wifi_password()
        return nvs_values.wifi_password
    end

    function nvs.set_wifi_password(value)
        nvs_values.wifi_password = value
        return true
    end

    function nvs.sync_server_url()
        return nvs_values.sync_server_url
    end

    function nvs.set_sync_server_url(value)
        nvs_values.sync_server_url = value
        return true
    end

    local wifi = {}

    function wifi.started()
        local ssid = nvs.wifi_ssid()
        return ssid ~= nil and ssid ~= ""
    end

    function wifi.connected()
        return wifi.started()
    end

    function wifi.reload()
        return true
    end

    local http_result = nil
    local http_busy = false
    local http = {}

    function http.get(url)
        if type(url) ~= "string" or not url:match("^https?://") then
            return false, "URL must begin with http:// or https://"
        end

        if http_busy then
            return false, "HTTP request already in progress"
        end

        http_busy = true
        http_result = {
            ok = true,
            status = 200,
            body = "{\"status\":\"ok\",\"source\":\"desktop-simulator\"}",
            error = nil,
        }
        http_busy = false

        return true
    end

    function http.busy()
        return http_busy
    end

    function http.poll()
        local result = http_result
        http_result = nil
        return result
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
    install_module("wifi", wifi)
    install_module("http", http)
    install_module("version", version)

    return {
        property = property,
        backstack = backstack,
    }
end

return M
