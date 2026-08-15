dofile("desktop-sim/jellyfin_library.lua")

local backstack = require("backstack")
local index = require("jellyfin_local_index")
local jellyfin_playback = require("jellyfin_playback")
local session = require("jellyfin_playback_session")
local local_library = require("jellyfin_local_library")
local metrics = require("sim_metrics")
local playback = require("playback")
local volume = require("volume")

local library = assert(index.load())
local selected
local following

for _, track in ipairs(library.tracks) do
    if track.id ==
            "ce1c15cfac374bfa95508510ec994096" then
        selected = track
    elseif not following then
        following = track
    end
end

assert(selected and following)

local album_screen =
    local_library.Album:new {
        title = "Brasilian Skies",
        album_key =
            "id:3d698c5103e705965c5965d8ba385a1d",
    }
backstack.push(album_screen)
local album_background =
    album_screen:background_state()
local album_background_geometry =
    metrics.image_geometry(
        album_screen.background_art
    )

assert(album_background.enabled)
assert(album_background.dimmer_opa == 118)
assert(album_background.source:find(
    "%-bg160x128%-v3%.png$"
))
assert(album_background_geometry.decoded_width == 160)
assert(album_background_geometry.decoded_height == 128)
backstack.pop()

local parent = local_library.Tracks:new()
backstack.push(parent)

assert(jellyfin_playback.play(
    selected,
    {
        collection_kind = "local_tracks",
        queue_tracks = {selected, following},
    }
))

local initial = assert(session.current())
local simulator = assert(
    _G.tangara_sim_local_playback_state
)
local initial_open_count = simulator.open_count

assert(initial.track_id == selected.id)
assert(initial.album_id ==
    "3d698c5103e705965c5965d8ba385a1d")
assert(#initial.queue.items == 2)
assert(initial.queue_index == 1)
assert(initial.artwork.foreground_identity.owner_id ==
    initial.album_id)
assert(initial.artwork.background_identity.owner_id ==
    initial.album_id)
assert(initial.artwork.foreground:find(
    "%-sq66%.png$"
))
assert(initial.artwork.background:find(
    "%-bg160x128%-v3%.png$"
))
assert(initial.artwork.foreground_identity.network == false)
assert(initial.artwork.background_identity.network == false)

volume.current_pct:set(37)
playback.playing:set(false)

for cycle = 1, 5 do
    if cycle == 1 then
        assert(parent.mini_player.input_right)
        assert(parent.mini_player.input_right
            .long_press())
    else
        assert(session.open_now_playing())
    end
    local player = backstack.current()
    local current = assert(session.current())
    local artwork = player.view:artwork_state()

    assert(current.id == initial.id)
    assert(#current.queue.items == 2)
    assert(current.queue_index == 1)
    assert(current.paused == true)
    assert(current.volume == 37)
    assert(simulator.open_count == initial_open_count)
    assert(artwork.foreground.source ==
        initial.artwork.foreground)
    assert(artwork.background.source ==
        initial.artwork.background)
    assert(artwork.foreground.decoded_width == 67,
        "foreground width=" ..
            tostring(artwork.foreground.decoded_width))
    assert(artwork.foreground.decoded_height == 66,
        "foreground height=" ..
            tostring(artwork.foreground.decoded_height))
    assert(artwork.foreground.target_width == 72)
    assert(artwork.foreground.target_height == 72)
    assert(artwork.foreground.transform_width == 0)
    assert(artwork.foreground.transform_height == 0)
    assert(artwork.background.decoded_width == 160,
        "background width=" ..
            tostring(artwork.background.decoded_width))
    assert(artwork.background.decoded_height == 128,
        "background height=" ..
            tostring(artwork.background.decoded_height))
    assert(artwork.background.target_width == 160)
    assert(artwork.background.target_height == 128)

    backstack.pop()
    assert(backstack.current() == parent)
    assert(playback.playing:get() == false)
    parent.mini_player:refresh()

    local mini = parent.mini_player:state()
    local mini_geometry =
        metrics.image_geometry(
            parent.mini_player.cover
        )
    assert(mini.visible)
    assert(mini.session_id == initial.id)
    assert(mini.track_id == selected.id)
    assert(mini.paused == true)
    assert(mini.artwork.source ==
        initial.artwork.foreground)
    assert(mini.list_height == 72)
    assert(mini_geometry.decoded_width == 67)
    assert(mini_geometry.decoded_height == 66)
    assert(mini.root_coordinates.y1 >= 0)
    assert(mini.root_coordinates.y2 <= 127)
    assert(mini.cover_frame_coordinates.y2 <=
        mini.root_coordinates.y2)
    assert(mini.title_coordinates.y2 <
        mini.artist_coordinates.y2)
    assert(mini.artist_coordinates.y2 <
        mini.root_coordinates.y2)
    assert(mini.affordance_coordinates.x2 <=
        mini.root_coordinates.x2)
    assert(simulator.open_count == initial_open_count)

    if cycle < 5 then
        assert(parent.mini_player:open())
        backstack.pop()
    end
end

playback.playing:set(true)
jellyfin_playback.next()
parent.mini_player:refresh()

local changed = assert(session.current())
local mini_changed = parent.mini_player:state()

assert(changed.id == initial.id)
assert(changed.queue_index == 2)
assert(changed.track_id == following.id)
assert(#changed.queue.items == 2)
assert(mini_changed.track_id == following.id)
assert(mini_changed.queue_index == 2)
assert(simulator.open_count >= initial_open_count)

print(string.format(
    "Persistent playback session passed: session=%d queue=%d " ..
        "track=%s album=%s foreground=%s background=%s " ..
        "cover=%dx%d zoom=%d background=%dx%d clip=%d,%d-%d,%d",
    initial.id,
    #initial.queue.items,
    initial.track_id,
    initial.album_id,
    initial.artwork.foreground_identity.persistent_path,
    initial.artwork.background_identity.persistent_path,
    67,
    66,
    280,
    160,
    128,
    0,
    0,
    159,
    127
))
os.exit(0)
