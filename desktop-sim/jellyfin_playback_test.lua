package.path =
    "lua/?.lua;" ..
    package.path

local root =
    "desktop-sim/sd/jellyfin-playback-test"

os.execute("rm -rf " .. root)
os.execute(
    "mkdir -p " ..
    root ..
    "/Music/Test"
)

local function property(initial)
    local value = initial

    return {
        get = function()
            return value
        end,
        set = function(_, next_value)
            value = next_value
        end,
    }
end

local cleared = 0
local opened_path = nil
local opened_lines = {}
local playing = false

local queue_position = property(0)
local queue_size = property(0)

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
    local queue = {
        position = queue_position,
        size = queue_size,
        random = property(true),
    }

    function queue.clear()
        cleared = cleared + 1
        opened_lines = {}
        queue.position:set(0)
        queue.size:set(0)
    end

    function queue.open_playlist(path)
        queue.clear()
        opened_path = path

        local file = assert(
            io.open(root .. path, "rb")
        )

        opened_lines = {}

        for line in file:lines() do
            local clean_line =
                line:gsub("\r$", "")

            table.insert(
                opened_lines,
                clean_line
            )
        end

        file:close()
        queue.size:set(#opened_lines)
        queue.position:set(0)
    end

    function queue.next()
        queue.position:set(
            math.min(
                math.max(
                    0,
                    queue.size:get() - 1
                ),
                queue.position:get() + 1
            )
        )
    end

    function queue.previous()
        queue.position:set(
            math.max(
                0,
                queue.position:get() - 1
            )
        )
    end

    return queue
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

local tracks = {
    {
        id = "track-1",
        title = "First",
        playlist_entry_id = "entry-1",
    },
    {
        id = "track-2",
        title = "Second",
        playlist_entry_id = "entry-2",
    },
    {
        id = "track-3",
        title = "Third",
        playlist_entry_id = "entry-3",
    },
    {
        id = "track-missing",
        title = "Unavailable",
        playlist_entry_id = "entry-4",
    },
}

local manifest_items = {}

for index = 1, 3 do
    local relative =
        "/Music/Test/song-" ..
        tostring(index) ..
        ".flac"
    local audio = assert(
        io.open(root .. relative, "wb")
    )

    audio:write("test")
    audio:close()

    table.insert(
        manifest_items,
        {
            id = tracks[index].id,
            jellyfin_id =
                tracks[index].id,
            local_path = relative,
            duration = 180 + index,
            artwork = {
                cover =
                    "cover-" .. index,
                background =
                    "background-" .. index,
            },
        }
    )
end

assert(
    manifest_cache.save(
        json_encode.encode({
            device = {
                id =
                    "playback-test-device",
            },
            items = manifest_items,
        })
    )
)

local stale_cache = assert(
    io.open(
        root ..
            "/.tangara-jellyfin-current.playlist.cache",
        "wb"
    )
)
stale_cache:write("stale")
stale_cache:close()

local bridge =
    require("jellyfin_playback")

local played, play_error =
    bridge.play(
        tracks[2],
        {
            collection_kind = "playlist",
            collection_id = "playlist-1",
            entry_id = "entry-2",
            queue_tracks = tracks,
        }
    )

assert(played, play_error)
assert(cleared == 1)
assert(
    opened_path ==
        "/.tangara-jellyfin-current.playlist"
)
assert(#opened_lines == 3)
assert(
    opened_lines[1] ==
        "/Music/Test/song-1.flac" and
        opened_lines[2] ==
        "/Music/Test/song-2.flac" and
        opened_lines[3] ==
        "/Music/Test/song-3.flac",
    "queue playlist did not preserve collection ordering or omit unavailable tracks"
)
assert(queue_position:get() == 1)
assert(queue_size:get() == 3)
assert(playing == true)
assert(
    io.open(
        root ..
            "/.tangara-jellyfin-current.playlist.cache",
        "rb"
    ) == nil,
    "stale playlist offset cache was not removed"
)

local current = assert(bridge.current())
assert(current.track.title == "Second")
assert(current.context.entry_id == "entry-2")
assert(current.context.queue_tracks == nil)

bridge.next()
current = assert(bridge.current())
assert(current.track.title == "Third")
assert(current.context.entry_id == "entry-3")

bridge.previous()
current = assert(bridge.current())
assert(current.track.title == "Second")

local state = assert(bridge.queue_state())
assert(state.position == 2)
assert(state.size == 3)

os.execute("rm -rf " .. root)

print(
    "Jellyfin ordered local playback queue passed"
)

os.exit(0)
