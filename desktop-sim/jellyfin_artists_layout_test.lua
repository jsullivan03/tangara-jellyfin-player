dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local local_library = require("jellyfin_local_library")

_G.tangara_sim_artists_layout = "compact"
local compact = local_library.Artists:new()
backstack.push(compact)

assert(compact.artist_layout_mode == "compact")
assert(compact.virtual_artist_list.row_height == 13)
assert(compact.virtual_artist_list.row_gap == 0)
assert(compact.virtual_artist_list:fixed_visible_count() == 7)
assert(compact.mini_player:state().visible == false)
assert(compact.mini_player:state().list_height == 100)

local initial_id = compact.sorted_artists[1].key
compact.virtual_artist_list:focus_index(5)
assert(compact.virtual_artist_list.selected_index == 5)
assert(compact.sorted_artists[1].key == initial_id)

backstack.pop()
_G.tangara_sim_artists_layout = "preview"
local preview = local_library.Artists:new()
backstack.push(preview)

assert(preview.artist_layout_mode == "preview")
assert(preview.artist_preview)
assert(preview.artist_preview.artist_key ==
    preview.sorted_artists[1].key)
assert(#preview.artist_preview.sources > 0 or
    preview.artist_preview.initials:is_visible())
assert(preview.virtual_artist_list.scroll_indicator.x == 91)
assert(preview.virtual_artist_list.row_height == 13)

local library = assert(index.load())
local track = assert(library.tracks[1])
assert(jellyfin_playback.play(
    track,
    {
        collection_kind = "local_tracks",
        queue_tracks = {track},
    }
))

preview.mini_player:refresh()
assert(preview.mini_player:state().visible)
assert(preview.mini_player:state().list_height == 72)
assert(preview.virtual_artist_list.fixed_viewport_height == 72)
assert(preview.virtual_artist_list:fixed_visible_count() == 5)
assert(preview.artist_preview.object:get_coords().y2 <= 127)

print(
    "Artists Compact/Preview passed: compact=7 rows, " ..
    "mini=5 rows, preview has mosaic-or-initials fallback"
)
os.exit(0)
