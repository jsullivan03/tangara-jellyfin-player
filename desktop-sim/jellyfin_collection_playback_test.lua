package.path =
    "lua/?.lua;" ..
    package.path

local captured = {}
local pushed = nil
local control_options = nil

package.loaded["backstack"] = {
    push = function(value)
        pushed = value
    end,
}

package.loaded["jellyfin_list_ui"] = {
    add_play_control =
        function(owner, options)
            control_options = options
            owner.play_control = options
            return options
        end,
}

package.loaded["jellyfin_now_playing"] = {
    new = function()
        return {screen = "now-playing"}
    end,
}

package.loaded["jellyfin_playback"] = {
    play_queue =
        function(tracks, context, options)
            table.insert(
                captured,
                {
                    tracks = tracks,
                    context = context,
                    options = options,
                }
            )
            return true
        end,
}

package.loaded["jellyfin_collection_playback"] = nil
local collection =
    require("jellyfin_collection_playback")

local first = {id = "track-1"}
local second = {id = "track-2"}
local third = {id = "track-3"}

local flattened =
    collection.flatten_albums {
        {tracks = {first, second}},
        {tracks = {}},
        {tracks = {third}},
    }

assert(
    #flattened == 3 and
        flattened[1] == first and
        flattened[2] == second and
        flattened[3] == third,
    "album flattening did not preserve release and track order"
)

local owner = {}
local current_tracks = {first, second}
local context = {
    collection_kind = "local_tracks",
}

collection.attach(
    owner,
    {
        tracks = function()
            return current_tracks
        end,
        context = context,
    }
)

assert(
    control_options and
        type(control_options.on_play) ==
            "function" and
        type(control_options.on_shuffle) ==
            "function",
    "collection playback did not attach reusable Play and Shuffle handlers"
)

control_options.on_play()
assert(
    captured[1].tracks == current_tracks and
        captured[1].context == context and
        captured[1].options.shuffle ==
            false and
        captured[1].options.start_index == 1,
    "short press did not start the current collection from the top"
)
assert(
    pushed and
        pushed.screen == "now-playing",
    "successful Play All did not open Now Playing"
)

current_tracks = {third}
pushed = nil
control_options.on_shuffle()

assert(
    captured[2].tracks == current_tracks and
        captured[2].options.shuffle ==
            true and
        captured[2].options.start_index == 1,
    "long press did not resolve the latest sorted collection and enable shuffle"
)
assert(
    pushed and
        pushed.screen == "now-playing",
    "successful Shuffle All did not open Now Playing"
)

print(
    "Collection Play All and Shuffle All share normalized queue creation"
)
os.exit(0)
