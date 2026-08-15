package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")
lvgl.ImgData = function(path)
    return path
end

local simulator = require("mocks").install(lvgl)
local backstack = require("firmware_backstack")
package.loaded["backstack"] = backstack
package.preload["backstack"] = function()
    return backstack
end

package.loaded["jellyfin_navigation"] = {
    set_back = function()
    end,
    clear_back = function()
    end,
}

package.loaded["sync_library_view"] = {
    current = function()
        return {playlists = {}}
    end,
}

package.loaded["jellyfin_local_index"] = {
    load = function()
        return {
            counts = {
                artists = 3,
                albums = 4,
                tracks = 5,
            },
            artists = {},
            albums = {},
            tracks = {},
        }
    end,
}

package.loaded["jellyfin_playback"] = {
    current = function()
        return {
            track = {
                id = "track-1",
                title = "Playing",
                artist = "Artist",
                duration = 100,
            },
            item = {
                duration = 100,
            },
            context = {},
        }
    end,
    play = function()
        return true
    end,
    local_item = function(track)
        return track
    end,
}

package.loaded["jellyfin_playback_session"] = {
    current = function()
        return {
            metadata = {
                title = "Playing",
                artist = "Artist",
                duration = 100,
            },
            artwork = {
                foreground =
                    "//lua/img/cover_placeholder.png",
            },
            position = 10,
        }
    end,
    open_now_playing = function()
        return true
    end,
}

package.loaded["jellyfin_library"] = nil

local function screen_stub(name)
    return {
        name = name,
        create_ui = function()
        end,
        on_show = function()
        end,
        on_hide = function()
        end,
    }
end

package.preload["jellyfin_library"] = function()
    return {
        new = function()
            return screen_stub("playlists")
        end,
    }
end

local local_library =
    require("jellyfin_local_library")
local root = local_library.Root:new()

backstack.reset(root)
backstack.flush(8)

assert(
    root.mini_player and
        root.mini_player.visible == true,
    "mini-player was not visible with an active session"
)

local list_coords = root.list:get_coords()
local list_height =
    list_coords.y2 - list_coords.y1 + 1
assert(
    list_height <= 72,
    "Local root list stayed full-height under the mini-player: " ..
        tostring(list_height)
)

local labels = {}

for _, row in ipairs(root.rows or {}) do
    local text =
        row.label and row.label.text or
        row.marquees and
        row.marquees[1] and
        row.marquees[1].text
    if text then
        table.insert(labels, text)
    end
end

assert(
    #root.rows >= 4,
    "Local root did not expose all four section rows"
)

local tracks_row = root.rows[4]
assert(tracks_row and tracks_row.object)

lvgl.group.focus_obj(tracks_row.object)
backstack.flush(20)

local focused =
    root.focus_group:get_focused()
assert(
    focused == tracks_row.object,
    "Tracks row was not focusable with mini-player visible"
)

local tracks_coords =
    tracks_row.object:get_coords()
assert(
    tracks_coords.y2 <= list_coords.y2 + 1,
    "Tracks row remained covered by the mini-player"
)

-- Rapid retarget: moving selection again must keep Tracks fully above the
-- mini-player without leaving a stuck intermediate scroll.
root.rows[1].object:focus()
backstack.flush(8)
lvgl.group.focus_obj(tracks_row.object)
backstack.flush(20)
tracks_coords =
    tracks_row.object:get_coords()
assert(
    tracks_coords.y2 <= list_coords.y2 + 1,
    "Rapid selection retarget left Tracks covered by the mini-player"
)

root.selected_item_id = "root:albums"
root.rows[3].object:focus()
backstack.flush(2)

local albums_id = root.selected_item_id
root:on_hide()
root:on_show()
backstack.flush(4)

assert(
    root.selected_item_id == albums_id or
        root.selected_item_id ==
            "root:albums",
    "Local root selection was not restored"
)

print(
    "Local root mini-player scrolling passed"
)
os.exit(0)
