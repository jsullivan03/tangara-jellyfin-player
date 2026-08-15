package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

require("mocks").install(lvgl)

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

local pushed = nil
local queue_page = {kind = "queue-page"}

package.loaded["backstack"] = {
    push = function(page)
        pushed = page
    end,
    pop = function()
    end,
}

package.loaded["jellyfin_queue"] = {
    new = function()
        return queue_page
    end,
}

local active = {
    track = {
        id = "track-1",
        title = "Queue Test",
        artist = "Test Artist",
        artist_key = "id:artist-1",
        duration = 180,
    },
    context = {
        server_connected = true,
    },
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return active
    end,
    sync_position = function()
        return active
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

assert(
    page.activate_sheet_action("queue") ==
        true,
    "Now Playing Queue action was unavailable"
)
assert(
    pushed == queue_page,
    "Now Playing Queue action did not open the Queue page"
)

print(
    "Now Playing Queue action opens the Queue page"
)
os.exit(0)
