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
        queue.position:set(
            #opened_lines > 0 and 1 or 0
        )
    end

    function queue.next()
        queue.position:set(
            math.min(
                queue.size:get(),
                queue.position:get() + 1
            )
        )
    end

    function queue.previous()
        queue.position:set(
            math.max(
                queue.size:get() > 0 and 1 or 0,
                queue.position:get() - 1
            )
        )
    end

    function queue.playback_order()
        if queue.random:get() then
            return {1, 3, 2}
        end

        local order = {}

        for position =
            math.max(
                1,
                queue.position:get()
            ),
            queue.size:get() do
            table.insert(order, position)
        end

        return order
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
assert(queue_position:get() == 2)
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

local queue_view =
    assert(bridge.queue_view())
assert(
    queue_view.tracks[1] == tracks[2] and
        queue_view.tracks[2] == tracks[3] and
        queue_view.items[1].jellyfin_id ==
            "track-2" and
        queue_view.position == 1 and
        queue_view.source_position == 2 and
        queue_view.size == 2 and
        queue_view.total_size == 3 and
        queue_view.source_positions[1] == 2 and
        queue_view.source_positions[2] == 3 and
        queue_view.generation == 1,
    "queue_view did not expose the current and upcoming native queue order"
)

local shuffled, shuffle_error =
    bridge.play_queue(
        tracks,
        {
            collection_kind =
                "local_tracks",
        },
        {shuffle = true}
    )

assert(shuffled, shuffle_error)
assert(
    require("queue").random:get() ==
        true,
    "Shuffle All did not enable the native queue shuffle state before playback"
)
assert(
    #opened_lines == 3 and
        queue_size:get() == 3,
    "Shuffle All did not retain every downloaded collection item"
)

current = assert(bridge.current())
assert(
    current.track.title == "First" and
        current.queue.shuffle == true,
    "Shuffle All did not retain the native initial queue position and shuffle state"
)

state = assert(bridge.queue_state())
assert(
    state.shuffle == true,
    "queue_state did not expose the current shuffle state"
)

queue_view = assert(bridge.queue_view())
assert(
    queue_view.shuffle == true and
        queue_view.generation == 2 and
        queue_view.position == 1 and
        queue_view.source_positions[1] == 1 and
        queue_view.source_positions[2] == 3 and
        queue_view.source_positions[3] == 2 and
        queue_view.tracks[1] == tracks[1] and
        queue_view.tracks[2] == tracks[3] and
        queue_view.tracks[3] == tracks[2],
    "queue_view did not expose the native shuffled playback order"
)

os.execute("rm -rf " .. root)

print(
    "Jellyfin ordered local playback queue passed"
)

os.exit(0)
