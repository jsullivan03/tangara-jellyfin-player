package.path =
    "lua/?.lua;" ..
    package.path

local root =
    "desktop-sim/sd/jellyfin-playback-test"

os.execute(
    "rm -rf " .. root
)
os.execute(
    "mkdir -p " ..
    root ..
    "/Music/Test"
)

local cleared = 0
local played_path = nil
local played_position = nil
local playing = false

package.preload["device"] = function()
    return {
        id = function()
            return "playback-test-device"
        end,
        storage_root = function()
            return root
        end,
    }
end

package.preload["queue"] = function()
    return {
        clear = function()
            cleared = cleared + 1
        end,
        play_from = function(
            path,
            position
        )
            played_path = path
            played_position = position
        end,
        random = {
            set = function()
            end,
        },
    }
end

package.preload["playback"] = function()
    return {
        playing = {
            set = function(_, value)
                playing = value
            end,
        },
    }
end

local json_encode =
    require("json_encode")
local manifest_cache =
    require("sync_manifest_cache")

local audio_path =
    root .. "/Music/Test/song.flac"

local audio =
    assert(io.open(audio_path, "wb"))

audio:write("test")
audio:close()

assert(
    manifest_cache.save(
        json_encode.encode({
            device = {
                id = "playback-test-device",
            },
            items = {
                {
                    id = "track-1",
                    jellyfin_id = "track-1",
                    local_path =
                        "/Music/Test/song.flac",
                    artwork = {
                        cover = "cover",
                        background =
                            "background",
                    },
                },
            },
        })
    )
)

local bridge =
    require("jellyfin_playback")

local played, play_error =
    bridge.play(
        {
            id = "track-1",
            title = "Test Track",
        },
        {
            collection_kind =
                "playlist",
            collection_id =
                "playlist-1",
            entry_id = "entry-1",
        }
    )

assert(played, play_error)
assert(cleared == 1)
assert(
    played_path ==
        "/Music/Test/song.flac"
)
assert(played_position == 0)
assert(playing == true)

local current =
    assert(bridge.current())

assert(current.track.title ==
    "Test Track")
assert(current.context.entry_id ==
    "entry-1")

os.execute(
    "rm -rf " .. root
)

print(
    "Jellyfin playback bridge passed"
)

os.exit(0)

