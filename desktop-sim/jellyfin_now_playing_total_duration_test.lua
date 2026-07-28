package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

local playback = require("playback")
local queue = require("queue")

queue.size:set(1)
queue.position:set(0)
playback.position:set(0)
playback.playing:set(true)

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return {
            track = {
                id = "track-1",
                title = "Duration Test",
                artist = "Artist",
                artist_key = "id:artist-1",
                duration = 185,
            },
            item = {
                duration = 185,
            },
            context = {
                server_connected = true,
            },
        }
    end,
    sync_position = function()
        return package.loaded[
            "jellyfin_playback"
        ].current()
    end,
}

package.loaded["sync_config"] = {
    status = function()
        return {connected = true}
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {
            favorites = {items = {}},
            playlists = {},
        }
    end,
}

package.loaded["sync_operation_queue"] = {
    enqueue_set_favorite = function()
        return {}
    end,
    enqueue_add_playlist_item = function()
        return {}
    end,
    enqueue_remove_playlist_item = function()
        return {}
    end,
}

package.loaded["sync_runtime"] = {
    last_library_result = function()
        return {ok = true}
    end,
}

local NowPlaying =
    require("jellyfin_now_playing")
local page = NowPlaying:new()

page:create_ui()

local original_update = page.view.update
local last_time_update = nil

page.view.update = function(view, values)
    if values and
        (
            values.elapsed ~= nil or
            values.remaining ~= nil
        ) then
        last_time_update = values
    end

    return original_update(view, values)
end

playback.position:set(62)

lvgl.Timer {
    period = 40,
    repeat_count = 1,
    cb = function()
        local ok, failure = pcall(
            function()
                assert(
                    last_time_update and
                        last_time_update.elapsed ==
                            "1:02",
                    "left Now Playing time did not follow elapsed playback position"
                )
                assert(
                    last_time_update.remaining ==
                        "3:05",
                    "right Now Playing time counted down instead of staying at total duration"
                )
            end
        )

        if not ok then
            io.stderr:write(
                tostring(failure),
                "\n"
            )
            os.exit(1)
        end

        print(
            "Now Playing keeps total duration static while elapsed time advances"
        )
        os.exit(0)
    end,
}
