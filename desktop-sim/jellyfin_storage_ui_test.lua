package.path =
    "desktop-sim/?.lua;" ..
    "lua/?.lua;" ..
    package.path

local lvgl = require("lvgl")

lvgl.ImgData = function(path)
    return path
end

_G.tangara_sim_enable_encoder_handler = true

local simulator =
    require("mocks").install(lvgl)

package.loaded["backstack"] =
    simulator.backstack

local tracks = {
    {
        id = "曲-一",
        title = "一曲",
        artist = "音楽家",
        local_path = "/Music/一曲.flac",
    },
    {
        id = "曲-二",
        title = "二曲",
        artist = "音楽家",
        local_path = "/Music/二曲.flac",
    },
}
local albums = {
    {
        key = "作品",
        name = "作品",
        artist = "音楽家",
        track_count = 2,
        tracks = tracks,
    },
}
local remove_album_calls = 0
local remove_track_calls = 0
local clear_art_calls = 0
local clear_temp_calls = 0

package.loaded["jellyfin_storage"] = {
    format_bytes = function(value)
        return tostring(value) .. " B"
    end,
    snapshot = function()
        return {
            albums = albums,
            tracks = tracks,
            album_count = 1,
            track_count = 2,
            individual_track_count = 0,
            artwork_count = 1,
            incomplete_count = 1,
            used_bytes = 600,
            available_bytes = 400,
            total_bytes = 1000,
            music_bytes = 250,
            artwork_bytes = 40,
            system_bytes = 310,
        }
    end,
    remove_album = function()
        remove_album_calls =
            remove_album_calls + 1
        return true
    end,
    remove_track = function()
        remove_track_calls =
            remove_track_calls + 1
        return true
    end,
    clear_artwork_cache = function()
        clear_art_calls =
            clear_art_calls + 1
        return true
    end,
    clear_temporary_files = function()
        clear_temp_calls =
            clear_temp_calls + 1
        return true
    end,
    remove_albums = function()
        return true
    end,
    remove_tracks = function()
        return true
    end,
}

for _, name in ipairs({
    "jellyfin_storage_ui",
    "jellyfin_home",
}) do
    package.loaded[name] = nil
end

local storage_ui =
    require("jellyfin_storage_ui")
local root = storage_ui.Root:new()

simulator.backstack.reset(root)

assert(root.header_marquee.text == "Storage")
assert(#root.rows == 2)
assert(
    root.rows[1].selection_id ==
        "storage:albums"
)
assert(
    root.rows[2].selection_id ==
        "storage:tracks"
)
assert(root.scroll_indicator == nil)
assert(root.storage_bar ~= nil)
assert(root.capacity_used ~= nil)
assert(root.capacity_available ~= nil)
assert(
    #root.storage_bar.categories == 4
)
assert(
    root.storage_bar.categories[1]
        .name == "music" and
    root.storage_bar.categories[2]
        .name == "artwork" and
    root.storage_bar.categories[3]
        .name == "system" and
    root.storage_bar.categories[4]
        .name == "free"
)

local album_screen =
    storage_ui.Albums:new()
simulator.backstack.push(album_screen)
assert(
    album_screen.header_marquee.text ==
        "Downloaded albums"
)
assert(
    album_screen.virtual_album_list
        :logical_count() == 1
)
assert(album_screen.sort_row ~= nil)
assert(
    album_screen
        .preserve_leading_controls_on_open ~=
        true
)
assert(
    album_screen.select_row.label.text ==
        "Select multiple"
)

_G.tangara_sim_encoder_event(1)
assert(
    album_screen.focus_group:get_focused() ==
        album_screen.select_row.object,
    "moving above the first album must focus Select multiple"
)
album_screen.select_row.on_click()
assert(
    album_screen.selection_mode == true and
        album_screen.select_row.label.text ==
            "Delete selected (0)",
    "clicking the focused Select multiple row must enable selection"
)
album_screen.go_back()

album_screen.media_rows[1].on_click()
local album_action =
    storage_ui.Action:new {
        title = "作品",
        action_label =
            "Remove album from this Tangara",
        confirm_message = "Confirm",
        on_confirm =
            package.loaded[
                "jellyfin_storage"
            ].remove_album,
    }
album_action:create_ui()
assert(
    album_action.action_row.label.text ==
        "Remove album from this Tangara"
)

local confirm =
    storage_ui.Confirm:new {
        message = "Confirm",
        confirm_label = "Remove",
        on_confirm =
            package.loaded[
                "jellyfin_storage"
            ].remove_track,
    }
confirm:create_ui()
assert(remove_track_calls == 0)
confirm.confirm_row.on_click()
assert(remove_track_calls == 1)

local track_screen =
    storage_ui.Tracks:new()
track_screen:create_ui()
assert(
    track_screen.header_marquee.text ==
        "Downloaded tracks"
)
assert(
    track_screen.virtual_track_list
        :logical_count() == 2
)
assert(track_screen.sort_row ~= nil)
assert(
    track_screen
        .preserve_leading_controls_on_open ~=
        true
)
assert(
    track_screen.select_row.label.text ==
        "Select multiple"
)
track_screen.select_row.on_click()
assert(
    track_screen.select_row.label.text ==
        "Delete selected (0)"
)
track_screen.media_rows[1].on_click()
assert(
    track_screen.select_row.label.text ==
        "Delete selected (1)"
)
track_screen.media_rows[2].on_click()
assert(
    track_screen.select_row.label.text ==
        "Delete selected (2)"
)
track_screen.media_rows[1].on_click()
assert(
    track_screen.select_row.label.text ==
        "Delete selected (1)"
)
track_screen.go_back()
assert(
    track_screen.selection_mode == false and
    track_screen.select_row.label.text ==
        "Select multiple"
)

assert(remove_album_calls == 0)
assert(clear_art_calls == 0)
assert(clear_temp_calls == 0)

print(
    "Storage overview, category bar, collection screens, and confirmation UI passed"
)
os.exit(0)
